defmodule Bilimbi.PeopleConnector.Connector.FilesTest do
  use BilimbiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Bilimbi.Base.{Audit, Repo, Settings, Tenancy}
  alias Bilimbi.Base.Tenancy.Authentication
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.PeopleConnector.Connector
  alias Bilimbi.PeopleConnector.Connector.{Adapters, FileExchange, Providers}
  alias Bilimbi.PeopleConnector.Connector.TestFixtures, as: ConnectorFixtures
  alias Ecto.Adapters.SQL

  Code.require_file(
    Path.expand("../../../../base/artifacts/test/support/test_fixtures.ex", __DIR__)
  )

  setup do
    UserFixtures.create_user_tables!()
    Bilimbi.People.Organisation.TestFixtures.create_position_tables!()
    ConnectorFixtures.create_connection_tables!()
    Bilimbi.Base.Artifacts.TestFixtures.create_artifacts_table!()
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
    {:ok, _} = FileExchange.configure(operator, 73, %{enabled: true})
    root = Path.join(System.tmp_dir!(), "connector-files-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, _} = Settings.put("artifacts.storage_root", root)
    {:ok, _} = Settings.put("artifacts.retention_days", 30)
    %{operator: operator, scope: scope, registry: registry, root: root}
  end

  test "native export round trips as a private review import; byte replay deduplicates", c do
    {:ok, position} = Bilimbi.People.Organisation.create_position(c.scope, 73, %{code: "P-1"})

    {:ok, _} =
      Bilimbi.People.Organisation.record_version(c.scope, 73, position.id, %{
        version: 1,
        title: "Position One",
        effective_from: Date.utc_today()
      })

    {:ok, run} =
      Connector.synchronise(c.operator, 73, c.registry, Adapters.installed(), "file-export")

    assert run.state == :succeeded
    {:ok, exported} = FileExchange.export_file(c.operator, 73)
    assert exported.direction == :export

    {:ok, %{bytes: bytes, metadata: metadata}} =
      FileExchange.download(c.operator, 73, exported.id)

    document = Jason.decode!(bytes)
    projected = Enum.find(document["records"], &(&1["kind"] == "position"))
    assert projected["stable_id"] == to_string(position.id)
    assert projected["vacant"] and projected["version"] == 1
    assert projected["assignments"] == []

    holder = %{
      "source_id" => "people/native",
      "stable_id" => "a-1",
      "employee_stable_id" => "e-1",
      "kind" => "acting"
    }

    for assignments <- [
          nil,
          false,
          [%{}],
          [holder, holder],
          List.duplicate(holder, 501),
          [Map.put(holder, "extra", "unsupported")],
          [Map.put(holder, "source_id", "elsewhere")]
        ] do
      invalid = Map.put(projected, "assignments", assignments)

      assert {:error, :invalid_file} =
               FileExchange.import_file(
                 c.operator,
                 73,
                 Jason.encode!(Map.put(document, "records", [invalid]))
               )
    end

    assert metadata.content_type == "application/json"
    assert DateTime.diff(metadata.expires_at, DateTime.utc_now(), :day) in 29..30
    {:ok, before} = Connector.sync_summary(c.operator, 73)
    assert {:ok, imported} = FileExchange.import_file(c.operator, 73, bytes)
    assert imported.direction == :import
    assert {:ok, %{id: id, replayed?: true}} = FileExchange.import_file(c.operator, 73, bytes)
    assert id == imported.id
    assert {:ok, %{id: exported_id, replayed?: true}} = FileExchange.export_file(c.operator, 73)
    assert exported_id == exported.id
    {:ok, after_import} = Connector.sync_summary(c.operator, 73)
    assert after_import.checkpoint_version == before.checkpoint_version
    assert count("people_connector_file_exchanges") == 2
    assert count("base_artifacts") == 2
    {:ok, actions} = Audit.list_actions(c.operator)
    action = Enum.find(actions, &(&1.event == "people-connector.files.import"))
    assert action.actor_type == "user" and action.actor_id == 91 and action.company_id == 73
    refute inspect(action.payload) =~ "Company A"
    refute inspect(metadata) =~ c.root
  end

  test "denies company and tenant crossing, system actors and revoked management", c do
    {:ok, imported} = FileExchange.import_file(c.operator, 73, file())

    for {scope, company} <- [{c.operator, 74}, {c.operator, 75}, {c.scope, 73}] do
      assert {:error, _} = FileExchange.import_file(scope, company, file())
      assert {:error, _} = FileExchange.export_file(scope, company)
      assert {:error, _} = FileExchange.download(scope, company, imported.id)
      assert {:error, _} = FileExchange.configure(scope, company, %{enabled: false})
      assert {:error, _} = FileExchange.purge_expired(scope, company)
    end

    {:ok, :stored} =
      Bilimbi.Base.Authz.put_principal_capability(
        c.scope,
        73,
        :user,
        91,
        Connector.manage_capability(),
        false
      )

    assert {:error, _} = FileExchange.download(c.operator, 73, imported.id)
    assert count("people_connector_file_exchanges") == 1
  end

  test "operator policy rejects invalid values atomically", c do
    for values <- [
          %{enabled: false, max_bytes: 0},
          %{max_bytes: 10_485_761},
          %{max_records: 100_001},
          %{stale_minutes: 0},
          %{stale_minutes: 1441},
          %{json_enabled: "true"},
          %{unknown: true},
          %{"enabled" => true}
        ] do
      assert {:error, :invalid_file_policy} = FileExchange.configure(c.operator, 73, values)
    end

    assert {:ok, %{policy: %{enabled: true, max_bytes: 1_048_576, max_records: 1000}}} =
             FileExchange.summary(c.operator, 73)
  end

  test "format, identity, record and byte limits reject before storing", c do
    record = %{
      "kind" => "employee",
      "source_id" => "people/native",
      "stable_id" => "employee:1",
      "workforce_company_id" => 73,
      "name" => "Employee",
      "code" => "employee-1",
      "email" => nil,
      "supervisor_stable_id" => nil,
      "observed_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "active" => true
    }

    base = Jason.decode!(file())

    for invalid <- [
          "garbage",
          "[]",
          String.replace(file(), ~s("format":), ~s("format":"people-directory-v1","format":)),
          Jason.encode!(Map.put(base, "format", "vendor")),
          Jason.encode!(Map.put(base, "platform_company_id", 74)),
          Jason.encode!(Map.put(base, "tenant_id", 42)),
          Jason.encode!(Map.put(base, "tenant_id", 41.0)),
          Jason.encode!(Map.put(base, "platform_company_id", 73.0)),
          Jason.encode!(Map.put(base, "workforce_company_id", 73.0)),
          Jason.encode!(Map.put(base, "workforce_company_id", 74)),
          Jason.encode!(Map.put(base, "workforce_source_id", "remote")),
          Jason.encode!(Map.put(base, "records", [%{}])),
          Jason.encode!(Map.put(base, "records", [record, record])),
          Jason.encode!(Map.put(base, "extra", "unsupported"))
        ] do
      assert {:error, :invalid_file} = FileExchange.import_file(c.operator, 73, invalid)
    end

    {:ok, _} = FileExchange.configure(c.operator, 73, %{max_records: 1})
    second = Map.put(record, "stable_id", "employee:2")

    assert {:error, :invalid_file} =
             FileExchange.import_file(
               c.operator,
               73,
               Jason.encode!(Map.put(base, "records", [record, second]))
             )

    {:ok, _} = FileExchange.configure(c.operator, 73, %{max_bytes: 1})
    assert {:error, :file_too_large} = FileExchange.import_file(c.operator, 73, file())
    assert count("base_artifacts") == 0
    assert count("people_connector_file_exchanges") == 0
  end

  test "disabled format/connection and changed mapping refuse, expiry blocks bytes and purges",
       c do
    {:ok, imported} = FileExchange.import_file(c.operator, 73, file())
    {:ok, _} = FileExchange.configure(c.operator, 73, %{json_enabled: false})
    assert {:error, _} = FileExchange.import_file(c.operator, 73, file())
    assert {:error, _} = FileExchange.download(c.operator, 73, imported.id)
    {:ok, _} = FileExchange.configure(c.operator, 73, %{json_enabled: true})
    {:ok, _} = Connector.set_enabled(c.operator, 73, c.registry, false)
    assert {:error, _} = FileExchange.export_file(c.operator, 73)
    {:ok, _} = Connector.set_enabled(c.operator, 73, c.registry, true)
    SQL.query!(Repo, "UPDATE people_connector_connections SET workforce_company_id = 999", [])
    assert {:error, _} = FileExchange.download(c.operator, 73, imported.id)
    SQL.query!(Repo, "UPDATE people_connector_connections SET workforce_company_id = 73", [])
    SQL.query!(Repo, "UPDATE base_artifacts SET expires_at = now() - interval '1 second'", [])
    assert {:error, :not_found} = FileExchange.download(c.operator, 73, imported.id)
    assert {:ok, %{deleted: [_], errors: []}} = FileExchange.purge_expired(c.operator, 73)
    refute File.exists?(Path.join(c.root, imported.artifact_id))
    assert count("people_connector_file_exchanges") == 1
  end

  test "disconnect preserves receipts and permits company-owned expired byte cleanup", c do
    {:ok, imported} = FileExchange.import_file(c.operator, 73, file())
    assert :ok = Connector.remove_connection(c.operator, 73)
    assert {:error, _} = FileExchange.download(c.operator, 73, imported.id)
    assert count("people_connector_file_exchanges") == 1
    {:ok, _} = Connector.configure_connection(c.operator, 73, c.registry, Providers.native_id())
    {:ok, _} = Connector.set_enabled(c.operator, 73, c.registry, true)
    assert {:error, _} = FileExchange.download(c.operator, 73, imported.id)
    SQL.query!(Repo, "UPDATE base_artifacts SET expires_at = now() - interval '1 second'", [])
    assert {:ok, %{deleted: [_], errors: []}} = FileExchange.purge_expired(c.operator, 73)
    refute File.exists?(Path.join(c.root, imported.artifact_id))
  end

  test "private download uses host authentication and never returns sibling bytes", c do
    {:ok, imported} = FileExchange.import_file(c.operator, 73, file())
    path = "/integrations/people/files/73/#{imported.id}"
    conn = c.conn |> log_in_as() |> get(path)
    assert conn.status == 200
    assert conn.resp_body == file()
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert Plug.Conn.get_resp_header(conn, "x-content-type-options") == ["nosniff"]

    assert (c.conn |> log_in_as() |> get("/integrations/people/files/74/#{imported.id}")).status ==
             404
  end

  test "operator uploads a file and edits settings on the real page", c do
    {:ok, view, _} = c.conn |> log_in_as() |> live("/integrations/people/files")
    assert has_element?(view, "#people-files-policy")
    assert render(view) =~ "No files exchanged."

    upload =
      file_input(view, "#people-files-import", :directory, [
        %{name: "directory.json", content: file(), type: "application/json"}
      ])

    assert render_upload(upload, "directory.json") =~ "100"
    view |> form("#people-files-import") |> render_submit()
    assert has_element?(view, "#people-files-history", "Import for review")
    refute render(view) =~ "No files exchanged."

    view
    |> form("#people-files-policy",
      policy: %{enabled: "false", json_enabled: "true", max_bytes: "1024", max_records: "5"}
    )
    |> render_submit()

    assert {:ok, %{policy: %{enabled: false, max_bytes: 1024, max_records: 5}}} =
             FileExchange.summary(c.operator, 73)
  end

  test "storage and audit failures retain no successful receipt and can retry", c do
    :ok = Settings.delete("artifacts.retention_days")
    assert {:error, :retention_not_configured} = FileExchange.import_file(c.operator, 73, file())
    {:ok, _} = Settings.put("artifacts.retention_days", 30)

    SQL.query!(
      Repo,
      "ALTER TABLE base_audit_actions ADD CONSTRAINT files_audit_unavailable CHECK (event <> 'people-connector.files.import')",
      []
    )

    assert {:error, :audit_unavailable} = FileExchange.import_file(c.operator, 73, file())
    assert {:ok, %{records: [%{state: :failed}]}} = FileExchange.summary(c.operator, 73)
    SQL.query!(Repo, "ALTER TABLE base_audit_actions DROP CONSTRAINT files_audit_unavailable", [])
    assert {:ok, %{replayed?: false}} = FileExchange.import_file(c.operator, 73, file())
    assert count("people_connector_file_exchanges") == 1
  end

  test "an expired export is re-exported with fresh retention; history marks it expired", c do
    {:ok, run} =
      Connector.synchronise(c.operator, 73, c.registry, Adapters.installed(), "file-expiry")

    assert run.state == :succeeded
    {:ok, first} = FileExchange.export_file(c.operator, 73)
    expire!()

    assert {:ok, %{id: second_id, replayed?: false, state: :ready}} =
             FileExchange.export_file(c.operator, 73)

    refute second_id == first.id
    assert {:ok, %{bytes: _}} = FileExchange.download(c.operator, 73, second_id)
    assert {:error, _} = FileExchange.download(c.operator, 73, first.id)

    assert {:ok, %{id: ^second_id, replayed?: true}} = FileExchange.export_file(c.operator, 73)
    assert count("people_connector_file_exchanges") == 2
    assert count("base_artifacts") == 2

    assert {:ok, %{records: records}} = FileExchange.summary(c.operator, 73)
    assert Enum.find(records, &(&1.id == first.id)).state == :expired

    {:ok, view, _} = c.conn |> log_in_as() |> live("/integrations/people/files")
    assert has_element?(view, "#people-files-history", "Expired")
    assert has_element?(view, ~s(a[href="/integrations/people/files/73/#{second_id}"]))
    refute has_element?(view, ~s(a[href="/integrations/people/files/73/#{first.id}"]))
  end

  test "a stale pending receipt is abandoned, audited and stops blocking its bytes", c do
    :ok = Settings.delete("artifacts.retention_days")
    assert {:error, _} = FileExchange.import_file(c.operator, 73, file())
    {:ok, _} = Settings.put("artifacts.retention_days", 30)
    SQL.query!(Repo, "UPDATE people_connector_file_exchanges SET state = 'pending'", [])

    assert {:error, :file_exchange_in_progress} =
             FileExchange.import_file(c.operator, 73, file())

    {:ok, view, _} = c.conn |> log_in_as() |> live("/integrations/people/files")
    assert has_element?(view, "#people-files-history", "In progress")

    {:ok, _} = FileExchange.configure(c.operator, 73, %{stale_minutes: 5})

    SQL.query!(
      Repo,
      "UPDATE people_connector_file_exchanges SET updated_at = now() - interval '6 minutes'",
      []
    )

    assert {:ok, %{records: [%{id: stale_id, state: :stale}]}} =
             FileExchange.summary(c.operator, 73)

    {:ok, view, _} = c.conn |> log_in_as() |> live("/integrations/people/files")
    assert has_element?(view, "#people-files-history", "Abandoned")

    assert {:ok, %{id: new_id, replayed?: false, state: :ready}} =
             FileExchange.import_file(c.operator, 73, file())

    refute new_id == stale_id

    assert %{rows: [["failed", "stale"]]} =
             SQL.query!(
               Repo,
               "SELECT state, failure_reason FROM people_connector_file_exchanges WHERE id = $1",
               [Ecto.UUID.dump!(stale_id)]
             )

    {:ok, actions} = Audit.list_actions(c.operator)
    assert Enum.any?(actions, &(&1.event == "people-connector.files.stale"))
    assert count("people_connector_file_exchanges") == 2
  end

  defp expire! do
    for table <- ["base_artifacts", "people_connector_file_exchanges"] do
      SQL.query!(Repo, "UPDATE #{table} SET expires_at = now() - interval '1 second'", [])
    end
  end

  defp file do
    Jason.encode!(%{
      format: "people-directory-v1",
      tenant_id: 41,
      platform_company_id: 73,
      workforce_source_id: "people/native",
      workforce_company_id: 73,
      records: []
    })
  end

  defp count(table),
    do: SQL.query!(Repo, "SELECT count(*) FROM #{table}", []).rows |> hd() |> hd()
end
