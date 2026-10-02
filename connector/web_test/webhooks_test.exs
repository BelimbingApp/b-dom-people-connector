defmodule Bilimbi.PeopleConnector.Connector.WebhooksTest do
  use BilimbiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Audit
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Authentication
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.PeopleConnector.Connector
  alias Bilimbi.PeopleConnector.Connector.Providers
  alias Bilimbi.PeopleConnector.Connector.TestFixtures, as: ConnectorFixtures
  alias Bilimbi.PeopleConnector.Connector.Webhooks
  alias Ecto.Adapters.SQL

  @secret String.duplicate("s", 32)
  @body ~s({"event":"directory.changed"})
  @path "/webhooks/people-native"

  setup do
    # The host's limiter tests change cached window policy. Restart only the
    # supervised limiter in this test VM so each intake test gets fresh policy.
    :ok = Supervisor.terminate_child(BilimbiWeb.Supervisor, BilimbiWeb.WebhookRateLimit)
    {:ok, _pid} = Supervisor.restart_child(BilimbiWeb.Supervisor, BilimbiWeb.WebhookRateLimit)
    UserFixtures.create_user_tables!()
    ConnectorFixtures.create_connection_tables!()
    CompanyFixtures.insert_tenant!(%{id: 41})
    CompanyFixtures.insert_tenant!(%{id: 42, is_platform_operator: false})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, name: "Company A"})
    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, name: "Company B", code: "b"})
    CompanyFixtures.insert_company!(%{id: 75, tenant_id: 42, name: "Company C", code: "c"})
    UserFixtures.insert_user!(%{id: 91, company_id: 73, name: "Operator"})

    grant_capabilities!([
      "people-connector.connections.view",
      "people-connector.connections.manage"
    ])

    {:ok, scope} = Tenancy.scope(41)
    operator = Authentication.sign_in(scope, 91, 73)
    registry = Providers.installed()
    {:ok, _} = Connector.configure_connection(operator, 73, registry, Providers.native_id())
    {:ok, _} = Connector.set_enabled(operator, 73, registry, true)
    {:ok, _} = Connector.put_webhook_settings(operator, 73, %{secret: @secret, enabled: true})
    %{operator: operator, scope: scope, registry: registry}
  end

  test "real host accepts signed exact bytes; replay refuses; fresh-nonce retry deduplicates", %{
    scope: scope
  } do
    headers = signed_headers()
    assert deliver(headers).status == 202
    assert deliver(headers).status == 403
    assert deliver(signed_headers(nonce: "nonce-2")).status == 202
    assert count("people_connector_webhook_deliveries") == 1
    assert count("people_connector_webhook_nonces") == 2
    {:ok, actions} = Audit.list_actions(scope)
    received = Enum.filter(actions, &(&1.event == "people-connector.webhook"))
    assert Enum.map(received, & &1.payload["outcome"]) == ["received", "duplicate"]

    assert Enum.all?(
             received,
             &(&1.company_id == 73 and &1.actor_type == "guest" and &1.actor_id == 0)
           )

    refute inspect(received) =~ @secret
    refute inspect(received) =~ @body
  end

  test "wrong signature, altered body, stale/future timestamps and duplicate headers refuse" do
    headers = signed_headers()
    now = System.system_time(:second)

    for {candidate, body} <- [
          {List.keystore(
             headers,
             "x-people-signature",
             0,
             {"x-people-signature", String.duplicate("0", 64)}
           ), @body},
          {headers, @body <> " "},
          {signed_headers(timestamp: now - 3600), @body},
          {signed_headers(timestamp: now + 3600), @body},
          {headers ++ [{"x-people-signature", "ambiguous"}], @body},
          {Enum.reject(headers, &(elem(&1, 0) == "x-people-nonce")), @body}
        ] do
      # Direct callback preserves duplicate header pairs, as the seam does.
      assert {:error, :delivery_refused} = Webhooks.verify(request(candidate, body))
    end

    assert deliver(headers, @body <> " ").status == 403
    assert count("people_connector_webhook_deliveries") == 0
    assert count("people_connector_webhook_nonces") == 0
  end

  test "authenticated nonce cannot be reused with another delivery or payload" do
    assert deliver(signed_headers()).status == 202
    assert deliver(signed_headers(delivery: "delivery-2")).status == 403
    different_bytes = @body <> "\n"

    assert deliver(signed_headers(nonce: "nonce-2", body: different_bytes), different_bytes).status ==
             403

    assert count("people_connector_webhook_deliveries") == 1
    assert count("people_connector_webhook_nonces") == 1
  end

  test "signed malformed and unsupported payloads change nothing" do
    for body <- [
          "not-json",
          ~s({"event":"employee.write"}),
          ~s({"event":"directory.changed","data":{}}),
          <<255>>
        ] do
      assert deliver(signed_headers(body: body), body).status == 403
    end

    assert count("people_connector_webhook_deliveries") == 0
    assert count("people_connector_webhook_nonces") == 0
  end

  test "signature binds both company axes and tenant; no other company inherits a secret" do
    for options <- [[company: 74], [company: 75], [tenant: 42], [tenant: 42, company: 75]] do
      assert deliver(signed_headers(options)).status == 403
    end

    tampered = List.keystore(signed_headers(), "x-people-company", 0, {"x-people-company", "74"})
    assert deliver(tampered).status == 403
    assert count("people_connector_webhook_deliveries") == 0
  end

  test "disabled connection/intake, missing secret and rotation refuse", %{
    operator: operator,
    registry: registry
  } do
    {:ok, _} = Connector.put_webhook_settings(operator, 73, %{enabled: false})
    assert deliver(signed_headers()).status == 403
    {:ok, _} = Connector.put_webhook_settings(operator, 73, %{enabled: true})
    {:ok, _} = Connector.set_enabled(operator, 73, registry, false)
    assert deliver(signed_headers()).status == 403
    {:ok, _} = Connector.set_enabled(operator, 73, registry, true)
    {:ok, _} = Connector.put_webhook_settings(operator, 73, %{secret: String.duplicate("r", 32)})
    assert deliver(signed_headers()).status == 403
    {:ok, _} = Connector.put_webhook_settings(operator, 73, %{secret: "", enabled: false})

    assert {:error, :webhook_secret_missing} =
             Connector.put_webhook_settings(operator, 73, %{enabled: true})

    assert deliver(signed_headers()).status == 403
    assert count("people_connector_webhook_deliveries") == 0
  end

  test "configuration denies sibling company, system work and invalid policy", %{
    operator: operator,
    scope: scope
  } do
    assert {:error, :unauthorized} =
             Connector.put_webhook_settings(operator, 74, %{secret: @secret})

    assert {:error, :unauthorized} = Connector.put_webhook_settings(scope, 73, %{enabled: false})
    assert {:error, :not_found} = Connector.put_webhook_settings(operator, 75, %{enabled: false})

    for values <- [
          %{secret: "short"},
          %{max_skew_seconds: 0},
          %{enabled: "true"},
          %{unknown: true}
        ] do
      assert {:error, :invalid_webhook_settings} =
               Connector.put_webhook_settings(operator, 73, values)
    end

    assert {:ok, %{enabled: true, max_skew_seconds: 300}} =
             Connector.webhook_summary(operator, 73)
  end

  test "secrets are encrypted, never returned, and signing settings deleted on removal", %{
    operator: operator
  } do
    %{rows: [[encrypted?, stored]]} =
      SQL.query!(
        Repo,
        "SELECT is_encrypted, value::text FROM base_settings WHERE key = $1 AND scope_id = 73",
        [Webhooks.secret_key()]
      )

    assert encrypted?
    refute stored =~ @secret
    assert {:ok, summary} = Connector.webhook_summary(operator, 73)
    assert summary.secret_stored?
    refute inspect(summary) =~ @secret
    {:ok, _} = Connector.put_webhook_settings(operator, 73, %{max_skew_seconds: 60})
    assert :ok = Connector.remove_connection(operator, 73)

    assert %{rows: [[0]]} =
             SQL.query!(
               Repo,
               "SELECT count(*) FROM base_settings WHERE key LIKE 'people-connector.webhook.%'",
               []
             )
  end

  test "handler rechecks a secret rotated between verification and handling", %{
    operator: operator
  } do
    request = request(signed_headers(), @body)
    assert {:ok, context} = Webhooks.verify(request)
    {:ok, _} = Connector.put_webhook_settings(operator, 73, %{enabled: false})
    assert {:error, :delivery_refused} = Webhooks.handle(request, context)
    assert count("people_connector_webhook_deliveries") == 0
  end

  test "operator page edits webhook policy with a masked secret",
       %{conn: conn, operator: operator, registry: registry} do
    {:ok, view, html} = conn |> log_in_as() |> live("/integrations/people/connections")
    assert has_element?(view, "#people-connections-webhook-state", "Enabled")
    assert has_element?(view, "#people-connections-webhook-form input[type='password']")
    refute html =~ @secret

    view
    |> form("#people-connections-webhook-form",
      webhook: %{enabled: "false", max_skew_seconds: "60", password: "••••••••"}
    )
    |> render_submit()

    assert has_element?(view, "#people-connections-webhook-state", "Disabled")
    assert {:ok, _} = Connector.set_enabled(operator, 73, registry, false)

    view
    |> form("#people-connections-webhook-form",
      webhook: %{
        enabled: "true",
        max_skew_seconds: "60",
        password: "••••••••"
      }
    )
    |> render_submit()

    assert {:ok, %{enabled: true}} = Connector.webhook_summary(operator, 73)
    assert has_element?(view, "#people-connections-webhook-state", "Disabled")
  end

  test "module audit failure rolls back nonce and receipt; the same attempt can retry" do
    headers = signed_headers()

    SQL.query!(
      Repo,
      "ALTER TABLE base_audit_actions ADD CONSTRAINT webhook_module_audit_unavailable CHECK (event <> 'people-connector.webhook')",
      []
    )

    assert deliver(headers).status == 403
    assert count("people_connector_webhook_deliveries") == 0
    assert count("people_connector_webhook_nonces") == 0

    SQL.query!(
      Repo,
      "ALTER TABLE base_audit_actions DROP CONSTRAINT webhook_module_audit_unavailable",
      []
    )

    assert deliver(headers).status == 202
    assert count("people_connector_webhook_deliveries") == 1
  end

  test "retry deduplicates work committed before host receipt audit failed" do
    SQL.query!(
      Repo,
      "ALTER TABLE base_audit_actions ADD CONSTRAINT webhook_host_audit_unavailable CHECK (event <> 'webhook.delivery')",
      []
    )

    assert deliver(signed_headers()).status == 403
    assert count("people_connector_webhook_deliveries") == 1

    SQL.query!(
      Repo,
      "ALTER TABLE base_audit_actions DROP CONSTRAINT webhook_host_audit_unavailable",
      []
    )

    assert deliver(signed_headers(nonce: "nonce-2")).status == 202
    assert count("people_connector_webhook_deliveries") == 1
    assert count("people_connector_webhook_nonces") == 2
  end

  test "live secret entry is filtered from Phoenix event logs", %{conn: conn} do
    {:ok, view, _html} = conn |> log_in_as() |> live("/integrations/people/connections")
    secret = String.duplicate("log-sensitive", 3)
    previous = Logger.level()
    Logger.configure(level: :debug)

    try do
      params = %{
        "webhook" => %{
          "enabled" => "true",
          "max_skew_seconds" => "300",
          "password" => secret
        }
      }

      # The host logger's real filtering API must mask the same parameters we
      # submit, even if another host test detached LiveView's telemetry logger.
      assert Phoenix.Logger.filter_values(params)["webhook"]["password"] == "[FILTERED]"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          view |> form("#people-connections-webhook-form", params) |> render_submit()
        end)

      assert log =~ "people-connector.webhook.secret"
      refute log =~ secret
      assert has_element?(view, "#people-connections-webhook-secret-state", "Stored")
    after
      Logger.configure(level: previous)
    end
  end

  test "viewer cannot alter webhook policy through a forged LiveView event", %{conn: conn} do
    UserFixtures.insert_user!(%{
      id: 92,
      company_id: 73,
      name: "Viewer",
      email: "viewer@example.com"
    })

    grant_capabilities!("people-connector.connections.view", user_id: 92)

    {:ok, view, _html} =
      conn
      |> log_in_as(session_user(%{"user_id" => 92}))
      |> live("/integrations/people/connections")

    refute has_element?(view, "#people-connections-webhook-form")

    render_hook(view, "save_webhook", %{
      "webhook" => %{"enabled" => "false", "password" => "", "max_skew_seconds" => "1"}
    })

    assert has_element?(view, "#people-connections-webhook-state", "Enabled")
    assert has_element?(view, "#flash-group", "cannot change connections")
  end

  test "changed Workforce mapping refuses and reconfiguration clears signing settings", %{
    operator: operator,
    registry: registry
  } do
    {:ok, _} = Connector.put_webhook_settings(operator, 73, %{max_skew_seconds: 60})
    assert {:ok, context} = Webhooks.verify(request(signed_headers(), @body))
    # Earlier provider mapping is a Connector-owned fixture, not a private People read.
    SQL.query!(
      Repo,
      "UPDATE people_connector_connections SET workforce_company_id = 999 WHERE platform_company_id = 73",
      []
    )

    assert deliver(signed_headers()).status == 403

    assert {:error, :delivery_refused} =
             Webhooks.handle(request(signed_headers(), @body), context)

    assert {:ok, _} =
             Connector.configure_connection(operator, 73, registry, Providers.native_id())

    assert {:ok, %{enabled: false, secret_stored?: false, max_skew_seconds: 300}} =
             Connector.webhook_summary(operator, 73)
  end

  defp count(table),
    do: SQL.query!(Repo, "SELECT count(*) FROM #{table}", []).rows |> hd() |> hd()

  defp signed_headers(options \\ []) do
    fields = [
      "people-native:v1",
      to_string(Keyword.get(options, :tenant, 41)),
      to_string(Keyword.get(options, :company, 73)),
      to_string(Keyword.get(options, :timestamp, System.system_time(:second))),
      Keyword.get(options, :nonce, "nonce-1"),
      Keyword.get(options, :delivery, "delivery-1")
    ]

    bytes = Enum.join(fields, "\n") <> "\n" <> Keyword.get(options, :body, @body)
    signature = :crypto.mac(:hmac, :sha256, @secret, bytes) |> Base.encode16(case: :lower)

    Enum.zip(
      ~w(x-people-tenant x-people-company x-people-timestamp x-people-nonce x-people-delivery x-people-signature),
      tl(fields) ++ [signature]
    )
  end

  defp request(headers, body),
    do: %{method: "POST", headers: headers, body: body, remote_ip: {127, 0, 0, 1}}

  defp deliver(headers, body \\ @body) do
    headers
    |> Enum.reduce(build_conn(), fn {key, value}, conn ->
      Plug.Conn.put_req_header(conn, key, value)
    end)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> post(@path, body)
  end
end
