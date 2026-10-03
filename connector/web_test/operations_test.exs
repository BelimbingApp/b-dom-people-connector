defmodule Bilimbi.PeopleConnector.Connector.OperationsTest do
  use BilimbiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Bilimbi.Base.{Audit, Repo, Settings, Tenancy}
  alias Bilimbi.Base.Settings.Scope, as: SettingsScope
  alias Bilimbi.Base.Tenancy.Authentication
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.PeopleConnector.Connector
  alias Bilimbi.PeopleConnector.Connector.{Adapters, Doctor, FileExchange, Providers, Retention}
  alias Bilimbi.PeopleConnector.Connector.TestFixtures, as: Fixtures
  alias Ecto.Adapters.SQL

  Code.require_file(
    Path.expand("../../../../base/artifacts/test/support/test_fixtures.ex", __DIR__)
  )

  setup do
    UserFixtures.create_user_tables!()
    Bilimbi.People.Organisation.TestFixtures.create_position_tables!()
    Fixtures.create_connection_tables!()
    Bilimbi.Base.Artifacts.TestFixtures.create_artifacts_table!()
    CompanyFixtures.insert_tenant!(%{id: 41})
    CompanyFixtures.insert_tenant!(%{id: 42, is_platform_operator: false})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, name: "Company A"})
    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, name: "Company B", code: "b"})
    CompanyFixtures.insert_company!(%{id: 75, tenant_id: 42, name: "Company C", code: "c"})
    UserFixtures.insert_user!(%{id: 91, company_id: 73, name: "Operator"})
    grant_capabilities!(["people-connector.connections.view", Connector.manage_capability()])
    {:ok, system} = Tenancy.scope(41)
    operator = Authentication.sign_in(system, 91, 73)
    registry = Providers.installed()
    {:ok, _} = Connector.configure_connection(operator, 73, registry, Providers.native_id())
    {:ok, _} = Connector.set_enabled(operator, 73, registry, true)
    %{operator: operator, system: system, registry: registry}
  end

  test "doctor reports fresh, stale, failed and remapped state without changing sync", c do
    assert {:ok, first} = Doctor.run(c.operator, 73)
    assert check(first, :projection).state == :error
    assert check(first, :credential).state == :ok
    assert check(first, :webhook).state == :ok
    sync!(c, "doctor")
    assert {:ok, fresh} = Doctor.run(c.operator, 73)
    assert check(fresh, :projection).state == :ok
    assert check(fresh, :last_sync).state == :ok
    Fixtures.age_checkpoint!(1500)
    assert {:ok, stale} = Doctor.run(c.operator, 73)
    assert check(stale, :projection).state == :warning
    SQL.query!(Repo, "UPDATE people_connector_sync_runs SET state = 'failed'", [])
    assert {:ok, failed} = Doctor.run(c.operator, 73)
    assert check(failed, :failed_syncs).count == 1

    Fixtures.utc_query!(
      Repo,
      "UPDATE people_connector_sync_runs SET state = 'running', started_at = now() - interval '2 hours', finished_at = NULL",
      []
    )

    assert {:ok, stalled} = Doctor.run(c.operator, 73)
    assert check(stalled, :stalled_syncs).count == 1
    assert count("people_connector_sync_runs") == 1
    SQL.query!(Repo, "UPDATE people_connector_connections SET workforce_company_id = 999", [])
    assert {:ok, changed} = Doctor.run(c.operator, 73)
    assert check(changed, :configuration).state == :error
    {:ok, actions} = Audit.list_actions(c.operator)

    assert Enum.any?(
             actions,
             &(&1.event == "people-connector.doctor" and &1.actor_id == 91 and &1.company_id == 73)
           )
  end

  test "missing adapter and webhook signing secret are actionable without revealing secret", c do
    adapter = Map.fetch!(Adapters.installed(), Providers.native_id())
    :ok = Adapters.unregister(Providers.native_id(), adapter)

    try do
      assert {:ok, report} = Doctor.run(c.operator, 73)
      assert check(report, :adapter).state == :error
    after
      Adapters.register(Providers.native_id(), adapter)
    end

    settings = SettingsScope.company(73, 41)
    {:ok, _} = Settings.put("people-connector.webhook.enabled", true, settings)
    assert {:ok, missing} = Doctor.run(c.operator, 73)
    assert check(missing, :webhook).state == :error
    secret = String.duplicate("private-signing-value", 3)
    {:ok, _} = Settings.put("people-connector.webhook.secret", secret, settings)
    assert {:ok, report} = Doctor.run(c.operator, 73)
    assert check(report, :webhook).state == :ok
    refute inspect(report) =~ secret
    {:ok, actions} = Audit.list_actions(c.operator)
    refute inspect(Enum.filter(actions, &(&1.event == "people-connector.doctor"))) =~ secret
  end

  test "denies sibling companies, foreign tenants, system actors, revoked capabilities and route",
       c do
    for {scope, company} <- [{c.operator, 74}, {c.operator, 75}, {c.system, 73}] do
      assert {:error, _} = Doctor.run(scope, company)
      assert {:error, _} = Retention.policy(scope, company)
      assert {:error, _} = Retention.configure(scope, company, %{sync_days: 1})
      assert {:error, _} = Retention.purge(scope, company)
    end

    {:ok, view, _} =
      c.conn |> log_in_as() |> live("/integrations/people/operations?company_id=74")

    assert has_element?(view, "#people-operations-unavailable")
    refute has_element?(view, "#people-doctor-run")
    revoke!(c)
    assert {:error, _} = Doctor.run(c.operator, 73)
    assert {:error, _} = Retention.configure(c.operator, 73, %{sync_days: 1})
    assert {:error, _} = Retention.purge(c.operator, 73)
    assert {:error, _} = c.conn |> log_in_as() |> live("/integrations/people/operations")
    assert count("people_connector_retention_attempts") == 0
  end

  test "settings are atomic, bounded and unset periods preserve records", c do
    sync!(c, "kept")
    age_runs!()

    assert {:ok, %{sync_days: nil, webhook_days: nil, file_days: nil}} =
             Retention.policy(c.operator, 73)

    assert {:ok, %{deleted: [], errors: []}} = Retention.purge(c.operator, 73)

    for invalid <- [
          %{sync_days: 0},
          %{file_days: -1},
          %{webhook_days: 3651},
          %{batch_size: 1001},
          %{retry_minutes: nil},
          %{unknown: 1},
          %{"sync_days" => 1},
          %{sync_days: 1, batch_size: 0}
        ] do
      assert {:error, :invalid_retention_policy} = Retention.configure(c.operator, 73, invalid)
    end

    assert {:ok, %{sync_days: nil}} = Retention.policy(c.operator, 73)
    assert count("people_connector_sync_runs") == 1
  end

  test "purges old completed runs independently, audits failures, skips retry holds and preserves active work",
       c do
    first = sync!(c, "old-first")
    sync!(c, "old-second")
    sync!(c, "old-third")
    running = sync!(c, "running")
    age_runs!()

    SQL.query!(
      Repo,
      "UPDATE people_connector_sync_runs SET state = 'running', finished_at = NULL WHERE id = $1",
      [running.id]
    )

    {:ok, _} = Retention.configure(c.operator, 73, %{sync_days: 1, batch_size: 2})

    SQL.query!(
      Repo,
      "ALTER TABLE base_audit_actions ADD CONSTRAINT refuse_first_purge CHECK (event <> 'people-connector.retention.purged' OR payload->>'record_id' <> '#{first.id}')",
      []
    )

    assert {:ok, %{deleted: [_], errors: [%{id: id}]}} = Retention.purge(c.operator, 73)
    assert id == first.id
    assert count("people_connector_sync_runs") == 3
    assert count("people_connector_retention_attempts") == 1
    assert {:ok, %{deleted: [], errors: []}} = Retention.purge(c.operator, 73)
    SQL.query!(Repo, "ALTER TABLE base_audit_actions DROP CONSTRAINT refuse_first_purge", [])

    Fixtures.utc_query!(
      Repo,
      "UPDATE people_connector_retention_attempts SET attempted_at = now() - interval '2 hours'",
      []
    )

    assert {:ok, %{deleted: [%{id: ^id}], errors: []}} = Retention.purge(c.operator, 73)
    assert count("people_connector_retention_attempts") == 0
    assert count("people_connector_sync_runs") == 2
    assert count("people_connector_sync_checkpoints") == 1
    assert count("people_connector_workforce_records") > 0
    {:ok, actions} = Audit.list_actions(c.operator)
    assert Enum.any?(actions, &(&1.event == "people-connector.retention.failed"))
    purges = Enum.filter(actions, &(&1.event == "people-connector.retention.purged"))
    assert length(purges) == 2
    assert Enum.all?(purges, &(&1.actor_id == 91 and &1.company_id == 73))
  end

  test "latest and latest successful sync runs survive purge so doctor keeps last sync", c do
    sync!(c, "old-success")
    age_runs!()
    {:ok, _} = Retention.configure(c.operator, 73, %{sync_days: 1})
    assert {:ok, %{deleted: [], errors: []}} = Retention.purge(c.operator, 73)
    assert count("people_connector_sync_runs") == 1
    assert {:ok, report} = Doctor.run(c.operator, 73)
    assert check(report, :last_sync).state == :ok

    SQL.query!(
      Repo,
      "UPDATE people_connector_sync_runs SET started_at = finished_at - interval '1 minute'",
      []
    )

    Fixtures.utc_query!(
      Repo,
      "INSERT INTO people_connector_sync_runs (tenant_id, connection_id, platform_company_id, provider_id, idempotency_key, pass, state, reason, applied, unchanged, superseded, deactivated, refused, started_at, finished_at, inserted_at, updated_at) SELECT tenant_id, connection_id, platform_company_id, provider_id, 'old-failed', pass, 'failed', 'adapter_error', 0, 0, 0, 0, 0, now() - interval '36 hours', now() - interval '36 hours', now(), now() FROM people_connector_sync_runs",
      []
    )

    assert {:ok, %{deleted: [], errors: []}} = Retention.purge(c.operator, 73)
    assert count("people_connector_sync_runs") == 2
  end

  test "webhook receipts and replay guards retain at least twice the skew; sibling rows survive",
       c do
    Fixtures.insert_connection!(%{
      tenant_id: 41,
      platform_company_id: 74,
      workforce_company_id: 74
    })

    for table <- ["people_connector_webhook_deliveries", "people_connector_webhook_nonces"] do
      hash = if table =~ "deliveries", do: "delivery_hash, body_hash", else: "nonce_hash"
      values = if table =~ "deliveries", do: "'delivery', 'body'", else: "'nonce'"

      for {company, age} <- [{73, 25}, {74, 100}] do
        Fixtures.utc_query!(
          Repo,
          "INSERT INTO #{table} (tenant_id, connection_id, #{hash}, received_at) SELECT 41, id, #{values}, now() - make_interval(hours => $2) FROM people_connector_connections WHERE platform_company_id = $1",
          [company, age]
        )
      end
    end

    {:ok, _} =
      Settings.put(
        "people-connector.webhook.max_skew_seconds",
        86_400,
        SettingsScope.company(73, 41)
      )

    {:ok, _} = Retention.configure(c.operator, 73, %{webhook_days: 1})
    assert {:ok, %{deleted: []}} = Retention.purge(c.operator, 73)

    Fixtures.utc_query!(
      Repo,
      "UPDATE people_connector_webhook_deliveries SET received_at = now() - interval '49 hours'",
      []
    )

    Fixtures.utc_query!(
      Repo,
      "UPDATE people_connector_webhook_nonces SET received_at = now() - interval '49 hours'",
      []
    )

    assert {:ok, %{deleted: [_, _], errors: []}} = Retention.purge(c.operator, 73)
    assert count("people_connector_webhook_deliveries") == 1
    assert count("people_connector_webhook_nonces") == 1
  end

  test "file receipts require expired bytes and successful cleanup; failed storage does not stop other rows",
       c do
    root = Path.join(System.tmp_dir!(), "connector-retention-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, _} = Settings.put("artifacts.storage_root", root)
    {:ok, _} = Settings.put("artifacts.retention_days", 30)
    {:ok, _} = FileExchange.configure(c.operator, 73, %{enabled: true})
    {:ok, first} = FileExchange.import_file(c.operator, 73, file(0))
    {:ok, second} = FileExchange.import_file(c.operator, 73, file(1))
    {:ok, _} = Retention.configure(c.operator, 73, %{file_days: 1})

    Fixtures.utc_query!(
      Repo,
      "UPDATE people_connector_file_exchanges SET inserted_at = now() - interval '2 days'",
      []
    )

    assert {:ok, %{deleted: []}} = Retention.purge(c.operator, 73)

    Fixtures.utc_query!(
      Repo,
      "UPDATE people_connector_file_exchanges SET expires_at = now() - interval '1 second'",
      []
    )

    Fixtures.utc_query!(
      Repo,
      "UPDATE base_artifacts SET expires_at = now() - interval '1 second'",
      []
    )

    # A directory where Base expects a regular file makes one cleanup fail.
    File.rm!(Path.join(root, first.artifact_id))
    File.mkdir!(Path.join(root, first.artifact_id))

    assert {:ok,
            %{
              deleted: [%{id: second_id}],
              errors: [%{id: first_id, reason: :artifact_cleanup_failed}]
            }} = Retention.purge(c.operator, 73)

    assert second_id == second.id and first_id == first.id
    assert count("people_connector_file_exchanges") == 1
    refute File.exists?(Path.join(root, second.artifact_id))
    assert :ok = Connector.remove_connection(c.operator, 73)
    File.rmdir!(Path.join(root, first.artifact_id))

    Fixtures.utc_query!(
      Repo,
      "UPDATE people_connector_retention_attempts SET attempted_at = now() - interval '2 hours'",
      []
    )

    assert {:ok, %{deleted: [_], errors: []}} = Retention.purge(c.operator, 73)
    assert count("people_connector_file_exchanges") == 0
  end

  test "operator runs doctor, edits retention inline, confirms purge, and revoked events refuse",
       c do
    run = sync!(c, "page-old")
    latest = sync!(c, "page-latest")
    age_runs!()
    {:ok, view, _} = c.conn |> log_in_as() |> live("/integrations/people/operations")
    assert has_element?(view, "#people-doctor-empty")
    view |> element("#people-doctor-run") |> render_click()
    assert has_element?(view, "#people-doctor-checks", "Directory current")
    render_hook(view, "save_policy", %{"sync_days" => "1"})
    assert {:ok, %{sync_days: 1}} = Retention.policy(c.operator, 73)
    render_hook(view, "save_policy", %{"sync_days" => "0"})
    assert {:ok, %{sync_days: 1}} = Retention.policy(c.operator, 73)
    view |> element("#people-retention-request") |> render_click()
    assert has_element?(view, "#people-retention-confirm")
    assert count("people_connector_sync_runs") == 2
    view |> element("#people-retention-confirm button", "Purge") |> render_click()
    refute has_element?(view, "#people-retention-confirm")
    assert has_element?(view, "#people-retention-result", "Removed")
    # The connection's latest run survives; only the older run is removed.
    assert SQL.query!(Repo, "SELECT id FROM people_connector_sync_runs", []).rows == [[latest.id]]
    # Once retention removes the run, its old key starts a new pass.
    replay = sync!(c, "page-old")
    refute replay.id == run.id
    revoke!(c)
    render_hook(view, "run_doctor", %{})
    refute has_element?(view, "#people-doctor-checks")
    render_hook(view, "save_policy", %{"sync_days" => "2"})
    render_hook(view, "request_purge", %{})
    render_hook(view, "purge", %{})
    assert count("people_connector_sync_runs") == 2
  end

  defp check(report, code), do: Enum.find(report.checks, &(&1.code == code))

  defp sync!(c, key) do
    {:ok, run} = Connector.synchronise(c.operator, 73, c.registry, Adapters.installed(), key)
    assert run.state == :succeeded
    run
  end

  defp age_runs!,
    do:
      Fixtures.utc_query!(
        Repo,
        "UPDATE people_connector_sync_runs SET finished_at = now() - interval '2 days'",
        []
      )

  defp count(table),
    do: SQL.query!(Repo, "SELECT count(*) FROM #{table}", []).rows |> hd() |> hd()

  defp revoke!(c),
    do:
      Bilimbi.Base.Authz.put_principal_capability(
        c.system,
        73,
        :user,
        91,
        Connector.manage_capability(),
        false
      )

  defp file(space),
    do:
      Jason.encode!(
        %{
          format: "people-directory-v1",
          tenant_id: 41,
          platform_company_id: 73,
          workforce_source_id: "people/native",
          workforce_company_id: 73,
          records: []
        },
        pretty: space == 1
      )
end
