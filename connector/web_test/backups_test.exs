defmodule Bilimbi.PeopleConnector.Connector.BackupsTest do
  use BilimbiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Bilimbi.Base.{Audit, Repo, Settings, Tenancy}
  alias Bilimbi.Base.Settings.Scope, as: SettingsScope
  alias Bilimbi.Base.Tenancy.Authentication
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.PeopleConnector.Connector
  alias Bilimbi.PeopleConnector.Connector.{Adapters, Backup, Providers}
  alias Bilimbi.PeopleConnector.Connector.TestFixtures, as: Fixtures
  alias Ecto.Adapters.SQL

  Code.require_file(
    Path.expand("../../../../base/artifacts/test/support/test_fixtures.ex", __DIR__)
  )

  setup do
    UserFixtures.create_user_tables!()
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
    root = Path.join(System.tmp_dir!(), "connector-backups-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, _} = Settings.put("artifacts.storage_root", root)
    {:ok, _} = Settings.put("artifacts.retention_days", 90)
    %{operator: operator, system: system, registry: registry, root: root}
  end

  test "private backup restores config, checkpoint and projections, excludes secrets, audits and replays once",
       c do
    sync!(c, "before-backup")
    {:ok, initial} = Connector.sync_summary(c.operator, 73)

    {:ok, _} =
      Connector.put_webhook_settings(c.operator, 73, %{
        enabled: true,
        secret: "private-signing-secret-with-enough-length"
      })

    {:ok, backup} = Backup.create(c.operator, 73)
    bytes = File.read!(Path.join(c.root, backup.artifact_id))
    refute bytes =~ "private-signing-secret"
    refute bytes =~ "credential"
    snapshot = Jason.decode!(bytes)
    assert snapshot["checkpoint"]["version"] == initial.checkpoint_version
    assert length(snapshot["projections"]) > 0
    assert DateTime.diff(backup.expires_at, DateTime.utc_now(), :day) in 29..30
    {:ok, _} = Connector.put_sync_policy(c.operator, 73, %{page_limit: 17})
    sync!(c, "after-backup")

    SQL.query!(
      Repo,
      "UPDATE people_connector_workforce_records SET name = 'Changed', active = false",
      []
    )

    {:ok, preview} = Backup.preview(c.operator, 73, backup.id)
    assert Enum.any?(preview.changes, &(&1.before == 17 and &1.after == 250))

    assert Enum.any?(
             preview.changes,
             &(String.ends_with?(&1.label, "Active") and &1.before == false and &1.after == true)
           )

    assert {:error, :confirmation_required} =
             Backup.restore(c.operator, 73, backup.id, preview.token, false)

    assert {:error, :invalid_confirmation} =
             Backup.restore(c.operator, 73, backup.id, "tampered", true)

    assert {:ok, %{replayed?: false}} =
             Backup.restore(c.operator, 73, backup.id, preview.token, true)

    {:ok, restored} = Connector.sync_summary(c.operator, 73)
    assert restored.checkpoint_version > initial.checkpoint_version
    assert restored.policy.page_limit == 250

    assert SQL.query!(
             Repo,
             "SELECT count(*) FROM people_connector_workforce_records WHERE name = 'Changed'",
             []
           ).rows == [[0]]

    assert Settings.get("people-connector.webhook.secret", SettingsScope.company(73, 41)) == nil

    assert Settings.get("people-connector.webhook.enabled", SettingsScope.company(73, 41)) ==
             false

    assert {:ok, %{state: :succeeded, pass: :incremental} = recovered} =
             Backup.recover(c.operator, 73, backup.id)

    assert {:ok, %{id: id}} = Backup.recover(c.operator, 73, backup.id)
    assert id == recovered.id
    {:ok, latest} = Connector.sync_summary(c.operator, 73)

    assert {:ok, %{replayed?: true}} =
             Backup.restore(c.operator, 73, backup.id, preview.token, true)

    {:ok, after_replay} = Connector.sync_summary(c.operator, 73)
    assert latest.checkpoint_version == after_replay.checkpoint_version
    {:ok, actions} = Audit.list_actions(c.operator)
    action = Enum.find(actions, &(&1.event == "people-connector.backup.restored"))
    assert action.actor_id == 91 and action.company_id == 73
    refute inspect(action.payload) =~ "Changed"
  end

  test "all operations deny same-tenant company crossing, other tenants and system actors", c do
    {:ok, backup} = Backup.create(c.operator, 73)
    {:ok, preview} = Backup.preview(c.operator, 73, backup.id)

    for {scope, company} <- [{c.operator, 74}, {c.operator, 75}, {c.system, 73}] do
      assert {:error, _} = Backup.summary(scope, company)
      assert {:error, _} = Backup.create(scope, company)
      assert {:error, _} = Backup.preview(scope, company, backup.id)
      assert {:error, _} = Backup.restore(scope, company, backup.id, preview.token, true)
      assert {:error, _} = Backup.recover(scope, company, backup.id)
      assert {:error, _} = Backup.configure(scope, company, %{retention_days: 1})
      assert {:error, _} = Backup.purge_expired(scope, company)
    end

    {:ok, :stored} =
      Bilimbi.Base.Authz.put_principal_capability(
        c.system,
        73,
        :user,
        91,
        Connector.manage_capability(),
        false
      )

    assert {:error, _} = Backup.restore(c.operator, 73, backup.id, preview.token, true)
  end

  test "tamper, missing bytes and an expired backup refuse before state mutation", c do
    {:ok, backup} = Backup.create(c.operator, 73)
    {:ok, preview} = Backup.preview(c.operator, 73, backup.id)
    path = Path.join(c.root, backup.artifact_id)
    File.write!(path, "tampered")
    assert {:error, :integrity_failure} = Backup.preview(c.operator, 73, backup.id)

    assert {:error, :integrity_failure} =
             Backup.restore(c.operator, 73, backup.id, preview.token, true)

    File.rm!(path)
    assert {:error, _} = Backup.preview(c.operator, 73, backup.id)

    Fixtures.utc_query!(
      Repo,
      "UPDATE people_connector_backups SET expires_at = now() - interval '1 second'",
      []
    )

    assert {:error, _} = Backup.preview(c.operator, 73, backup.id)
    assert {:ok, %{deleted: [_], errors: []}} = Backup.purge_expired(c.operator, 73)
  end

  test "cleanup advances past purged receipts in batches", c do
    {:ok, _} = Settings.put("artifacts.purge_batch_size", 2)
    backups = expired_backups!(c, 5)

    assert {:ok, %{deleted: first, errors: []}} = Backup.purge_expired(c.operator, 73)
    assert {:ok, %{deleted: second, errors: []}} = Backup.purge_expired(c.operator, 73)
    assert {:ok, %{deleted: third, errors: []}} = Backup.purge_expired(c.operator, 73)
    assert {:ok, %{deleted: [], errors: []}} = Backup.purge_expired(c.operator, 73)
    assert first ++ second ++ third == Enum.map(backups, & &1.id)

    for backup <- backups,
        do: refute(File.exists?(Path.join(c.root, backup.artifact_id)))

    {:ok, %{records: records, holds: []}} = Backup.summary(c.operator, 73)

    assert Enum.sort(Enum.map(records, &{&1.id, &1.artifact_id, &1.state})) ==
             Enum.sort(Enum.map(backups, &{&1.id, &1.artifact_id, :purged}))

    assert {:error, :invalid_backup} = Backup.preview(c.operator, 73, hd(backups).id)
  end

  test "persistently failing oldest backups are deferred, then held, and do not block newer ones",
       c do
    {:ok, _} = Settings.put("artifacts.purge_batch_size", 2)
    {:ok, _} = Settings.put("artifacts.purge_max_attempts", 2)
    [old1, old2 | newer] = backups = expired_backups!(c, 5)

    for backup <- [old1, old2] do
      path = Path.join(c.root, backup.artifact_id)
      File.rm!(path)
      File.mkdir_p!(Path.join(path, "blocked"))
    end

    failing = Enum.sort([old1.id, old2.id])
    assert {:ok, %{deleted: [], errors: errors}} = Backup.purge_expired(c.operator, 73)
    assert Enum.sort(Enum.map(errors, &elem(&1, 0))) == failing
    assert {:ok, %{deleted: second, errors: []}} = Backup.purge_expired(c.operator, 73)
    assert {:ok, %{deleted: third, errors: []}} = Backup.purge_expired(c.operator, 73)
    assert second ++ third == Enum.map(newer, & &1.id)
    assert {:ok, %{deleted: [], errors: []}} = Backup.purge_expired(c.operator, 73)

    elapse_retry_interval!()
    assert {:ok, %{deleted: [], errors: [_, _]}} = Backup.purge_expired(c.operator, 73)
    elapse_retry_interval!()
    assert {:ok, %{deleted: [], errors: []}} = Backup.purge_expired(c.operator, 73)

    {:ok, %{holds: holds}} = Backup.summary(c.operator, 73)
    assert Enum.sort(Enum.map(holds, & &1.id)) == failing

    assert Enum.all?(
             holds,
             &(&1.purge_attempts == 2 and &1.purge_last_error == "cleanup_pending")
           )

    {:ok, actions} = Audit.list_actions(c.operator)
    events = Enum.frequencies(Enum.map(actions, & &1.event))
    assert events["people-connector.backup.purge_failed"] == 4
    assert events["people-connector.backup.purge_held"] == 2

    File.rm_rf!(Path.join(c.root, old1.artifact_id))
    elapse_retry_interval!()
    assert {:ok, %{deleted: [], errors: []}} = Backup.purge_expired(c.operator, 73)

    {:ok, view, _} = c.conn |> log_in_as() |> live("/integrations/people/backups")
    assert has_element?(view, "#people-backups-holds")
    view |> element("#retry-purge-#{old1.id}") |> render_click()
    refute has_element?(view, "#retry-purge-#{old1.id}")
    assert has_element?(view, "[role=status]", "Held backup removed")
    assert has_element?(view, "#retry-purge-#{old2.id}")
    assert {:error, :not_found} = Backup.retry_purge(c.operator, 73, old1.id)
    assert {:error, _} = Backup.retry_purge(c.operator, 74, old2.id)
    view |> element("#retry-purge-#{old2.id}") |> render_click()
    assert has_element?(view, "[role=alert]")
    refute has_element?(view, "[role=status]", "Held backup removed")
    assert {:ok, %{holds: []}} = Backup.summary(c.operator, 73)

    {:ok, actions} = Audit.list_actions(c.operator)
    assert Enum.count(actions, &(&1.event == "people-connector.backup.purge_released")) == 2

    {:ok, %{records: records}} = Backup.summary(c.operator, 73)
    states = Map.new(records, &{&1.id, &1.state})
    assert states[old1.id] == :purged and states[old2.id] == :expired
    assert length(backups) == map_size(states)
  end

  test "preview binds state, expires, and cannot be used on a replacement connection", c do
    {:ok, backup} = Backup.create(c.operator, 73)
    {:ok, preview} = Backup.preview(c.operator, 73, backup.id)
    sync!(c, "moves-state")

    assert {:error, :preview_changed} =
             Backup.restore(c.operator, 73, backup.id, preview.token, true)

    {:ok, preview} = Backup.preview(c.operator, 73, backup.id)

    Fixtures.utc_query!(
      Repo,
      "UPDATE people_connector_backups SET preview_expires_at = now() - interval '1 second'",
      []
    )

    assert {:error, :preview_expired} =
             Backup.restore(c.operator, 73, backup.id, preview.token, true)

    assert :ok = Connector.remove_connection(c.operator, 73)
    {:ok, _} = Connector.configure_connection(c.operator, 73, c.registry, Providers.native_id())
    assert {:error, :connection_changed} = Backup.preview(c.operator, 73, backup.id)
  end

  test "restore refuses a running sync and recovery refuses a moved checkpoint", c do
    sync!(c, "start")
    {:ok, backup} = Backup.create(c.operator, 73)
    {:ok, preview} = Backup.preview(c.operator, 73, backup.id)

    SQL.query!(
      Repo,
      "UPDATE people_connector_sync_runs SET state = 'running', finished_at = NULL",
      []
    )

    assert {:error, :sync_in_progress} = Backup.create(c.operator, 73)

    assert {:error, :sync_in_progress} =
             Backup.restore(c.operator, 73, backup.id, preview.token, true)

    Fixtures.utc_query!(
      Repo,
      "UPDATE people_connector_sync_runs SET state = 'succeeded', finished_at = now()",
      []
    )

    assert {:ok, _} = Backup.restore(c.operator, 73, backup.id, preview.token, true)
    sync!(c, "moves-restored-checkpoint")
    assert {:error, :checkpoint_moved} = Backup.recover(c.operator, 73, backup.id)
  end

  test "storage/audit failures roll back restore and invalid settings are atomic", c do
    assert {:error, :invalid_backup_policy} =
             Backup.configure(c.operator, 73, %{"retention_days" => 1})

    assert {:error, :invalid_backup_policy} =
             Backup.configure(c.operator, 73, %{retention_days: 0, preview_minutes: 5})

    :ok = Settings.delete("artifacts.retention_days")
    assert {:error, :retention_not_configured} = Backup.create(c.operator, 73)
    {:ok, _} = Settings.put("artifacts.retention_days", 30)
    {:ok, backup} = Backup.create(c.operator, 73)
    {:ok, preview} = Backup.preview(c.operator, 73, backup.id)

    SQL.query!(
      Repo,
      "ALTER TABLE base_audit_actions ADD CONSTRAINT backup_audit_unavailable CHECK (event <> 'people-connector.backup.restored')",
      []
    )

    assert {:error, _} = Backup.restore(c.operator, 73, backup.id, preview.token, true)

    assert SQL.query!(Repo, "SELECT restored_at FROM people_connector_backups WHERE id = $1", [
             Ecto.UUID.dump!(backup.id)
           ]).rows == [[nil]]

    SQL.query!(
      Repo,
      "ALTER TABLE base_audit_actions DROP CONSTRAINT backup_audit_unavailable",
      []
    )

    assert {:ok, _} = Backup.restore(c.operator, 73, backup.id, preview.token, true)
  end

  test "preview tokens are actor-bound, superseded and bound to one backup", c do
    {:ok, first} = Backup.create(c.operator, 73)
    {:ok, second} = Backup.create(c.operator, 73)
    {:ok, old_preview} = Backup.preview(c.operator, 73, first.id)
    {:ok, preview} = Backup.preview(c.operator, 73, first.id)

    assert {:error, :invalid_confirmation} =
             Backup.restore(c.operator, 73, first.id, old_preview.token, true)

    assert {:error, :invalid_confirmation} =
             Backup.restore(c.operator, 73, second.id, preview.token, true)

    UserFixtures.insert_user!(%{
      id: 92,
      company_id: 73,
      name: "Another operator",
      email: "another@example.com"
    })

    {:ok, :stored} =
      Bilimbi.Base.Authz.put_principal_capability(
        c.system,
        73,
        :user,
        92,
        Connector.manage_capability(),
        true
      )

    other = Authentication.sign_in(c.system, 92, 73)

    assert {:error, :invalid_confirmation} =
             Backup.restore(other, 73, first.id, preview.token, true)

    assert {:ok, _} = Backup.restore(c.operator, 73, first.id, preview.token, true)
  end

  test "backup digest refuses tampered bytes even if artifact metadata is corrupted", c do
    {:ok, backup} = Backup.create(c.operator, 73)
    path = Path.join(c.root, backup.artifact_id)
    original = File.read!(path)
    tampered = original |> Jason.decode!() |> Map.put("format", "unsupported") |> Jason.encode!()
    File.write!(path, tampered)
    sha = :crypto.hash(:sha256, tampered) |> Base.encode16(case: :lower)

    SQL.query!(Repo, "UPDATE base_artifacts SET sha256 = $1, byte_size = $2 WHERE id = $3", [
      sha,
      byte_size(tampered),
      Ecto.UUID.dump!(backup.artifact_id)
    ])

    assert {:error, :invalid_backup} = Backup.preview(c.operator, 73, backup.id)
  end

  test "fresh receipt structures match the owned post-migration contract" do
    [[schema]] =
      SQL.query!(Repo, "SELECT nspname FROM pg_namespace WHERE oid = pg_my_temp_schema()", []).rows

    assert :ok =
             Bilimbi.Base.Database.SchemaVerifier.verify(Repo, Backup.SchemaContract.tables(),
               prefix: schema
             )
  end

  test "operator page previews, confirms, restores and runs recovery through host authorization",
       c do
    sync!(c, "ui-sync")
    {:ok, view, _} = c.conn |> log_in_as() |> live("/integrations/people/backups")
    assert has_element?(view, "#people-backups-policy")
    assert has_element?(view, "#people-backups-history-empty")
    view |> element("#people-backups-create") |> render_click()
    refute has_element?(view, "#people-backups-history-empty")
    {:ok, %{records: [backup]}} = Backup.summary(c.operator, 73)
    view |> element("#preview-#{backup.id}") |> render_click()
    assert has_element?(view, "#people-backups-preview")
    view |> element("#people-backups-request-restore") |> render_click()
    assert has_element?(view, "#people-backups-confirm")
    view |> render_click("restore")
    refute has_element?(view, "#people-backups-confirm")
    assert has_element?(view, "#recover-#{backup.id}")
    view |> element("#recover-#{backup.id}") |> render_click()
    assert has_element?(view, "[role=status]", "Recovery synchronisation completed")

    assert {:ok, denied, _} =
             c.conn |> log_in_as() |> live("/integrations/people/backups?company_id=74")

    assert has_element?(denied, "#people-backups-unavailable")
    refute has_element?(denied, "#people-backups-create")
  end

  defp expired_backups!(c, count) do
    backups = for _ <- 1..count, do: elem(Backup.create(c.operator, 73), 1)

    for {backup, age} <- Enum.zip(backups, count..1//-1) do
      Fixtures.utc_query!(
        Repo,
        "UPDATE people_connector_backups SET expires_at = now() - make_interval(secs => $1) WHERE id = $2",
        [age, Ecto.UUID.dump!(backup.id)]
      )
    end

    backups
  end

  defp elapse_retry_interval! do
    SQL.query!(
      Repo,
      "UPDATE people_connector_backups SET purge_attempted_at = purge_attempted_at - interval '1 day'",
      []
    )
  end

  defp sync!(c, key) do
    {:ok, run} = Connector.synchronise(c.operator, 73, c.registry, Adapters.installed(), key)
    assert run.state == :succeeded
    run
  end
end
