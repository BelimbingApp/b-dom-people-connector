defmodule Bilimbi.PeopleConnector.Connector.SchemaContractTest.Repo do
  use Ecto.Repo, otp_app: :bilimbi_base_database, adapter: Ecto.Adapters.Postgres
end

defmodule Bilimbi.PeopleConnector.Connector.SchemaContractTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.Database.SchemaVerifier
  alias Bilimbi.PeopleConnector.Connector.{Backup, SchemaContract}
  alias Bilimbi.PeopleConnector.Connector.SchemaContractTest.Repo
  alias Ecto.Adapters.SQL

  for file <- [
        "base/tenancy/priv/repo/migrations/20260811093951_create_base_tenancy_compatibility_baseline.exs",
        "core/company/priv/repo/migrations/20260811093956_create_core_company_compatibility_baseline.exs"
      ] do
    Code.require_file(Path.expand("../../../../#{file}", __DIR__))
  end

  @migrations Path.expand("../priv/repo/migrations/*.exs", __DIR__)
              |> Path.wildcard()
              |> Enum.map(fn file ->
                [{module, _}] = Code.require_file(file)
                {version, _} = Integer.parse(Path.basename(file))
                {version, module}
              end)

  setup do
    options =
      Bilimbi.Base.Repo.config()
      |> Keyword.put(:name, Repo)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    Application.put_env(:bilimbi_base_database, Repo, options)
    start_supervised!(Repo)
    prefix = "connector_contract_#{System.unique_integer([:positive])}"
    SQL.query!(Repo, "CREATE SCHEMA #{prefix}", [])

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Bilimbi.Base.Repo, fn ->
        SQL.query!(Bilimbi.Base.Repo, "DROP SCHEMA #{prefix} CASCADE", [])
      end)

      Application.delete_env(:bilimbi_base_database, Repo)
    end)

    # Run the referenced identity owners' baselines too, without copying DDL.
    for {version, module} <- [
          {20_260_811_093_951, Bilimbi.Base.Tenancy.Migrations.CreateCompatibilityBaseline},
          {20_260_811_093_956, Bilimbi.Core.Company.Migrations.CreateCompatibilityBaseline}
        ] do
      assert Ecto.Migrator.up(Repo, version, module, prefix: prefix, log: false) == :ok
    end

    assert length(
             Ecto.Migrator.run(Repo, @migrations, :up, all: true, prefix: prefix, log: false)
           ) == 7

    %{prefix: prefix}
  end

  test "all ten relations match their contracts after fresh migrations", %{prefix: prefix} do
    tables = SchemaContract.tables() ++ Backup.SchemaContract.tables()
    assert length(tables) == 10
    assert :ok = SchemaVerifier.verify(Repo, tables, prefix: prefix)
    assert :ok = SchemaContract.verify_invariants(Repo, prefix: prefix)
  end

  test "detects mapping uniqueness, replay predicate, foreign key and check drift", %{
    prefix: prefix
  } do
    SQL.query!(
      Repo,
      "DROP INDEX #{prefix}.people_connector_connections_workforce_company_unique",
      []
    )

    SQL.query!(Repo, "DROP INDEX #{prefix}.people_connector_sync_runs_one_running", [])

    SQL.query!(
      Repo,
      "CREATE UNIQUE INDEX people_connector_sync_runs_one_running ON #{prefix}.people_connector_sync_runs (connection_id) WHERE state = 'failed'",
      []
    )

    SQL.query!(
      Repo,
      "ALTER TABLE #{prefix}.people_connector_webhook_nonces DROP CONSTRAINT people_connector_webhook_nonces_connection_id_fkey",
      []
    )

    SQL.query!(
      Repo,
      "ALTER TABLE #{prefix}.people_connector_file_exchanges DROP CONSTRAINT people_connector_file_exchange_values",
      []
    )

    assert {:error, errors} = SchemaVerifier.verify(Repo, SchemaContract.tables(), prefix: prefix)

    assert "people_connector_connections: missing index people_connector_connections_workforce_company_unique" in errors

    assert "people_connector_sync_runs: incompatible index people_connector_sync_runs_one_running" in errors

    assert "people_connector_webhook_nonces: missing foreign key people_connector_webhook_nonces_connection_id_fkey" in errors

    assert "people_connector_file_exchanges: missing check people_connector_file_exchange_values" in errors
  end

  test "detects cross-tenant replay receipts and projections from another mapping", %{
    prefix: prefix
  } do
    SQL.query!(
      Repo,
      "INSERT INTO #{prefix}.people_connector_connections (id, tenant_id, platform_company_id, provider_id, provider_contract_version, workforce_source_id, workforce_company_id, inserted_at, updated_at) VALUES (1, 41, 73, 'provider', '1', 'source', 101, $1, $1)",
      [NaiveDateTime.utc_now()]
    )

    SQL.query!(
      Repo,
      "INSERT INTO #{prefix}.people_connector_webhook_nonces (tenant_id, connection_id, nonce_hash, received_at) VALUES (42, 1, 'nonce', $1)",
      [NaiveDateTime.utc_now()]
    )

    SQL.query!(
      Repo,
      "INSERT INTO #{prefix}.people_connector_workforce_records (tenant_id, connection_id, kind, source_id, stable_id, workforce_company_id, active, name, code, content_hash, observed_at, inserted_at, updated_at) VALUES (41, 1, 'employee', 'other-source', 'employee', 102, true, 'Employee', 'code', 'hash', $1, $1, $1)",
      [NaiveDateTime.utc_now()]
    )

    SQL.query!(Repo, "DROP INDEX #{prefix}.people_connector_webhook_nonces_identity_unique", [])

    SQL.query!(
      Repo,
      "INSERT INTO #{prefix}.people_connector_webhook_nonces (tenant_id, connection_id, nonce_hash, received_at) VALUES (41, 1, 'nonce', $1)",
      [NaiveDateTime.utc_now()]
    )

    assert {:error, errors} = SchemaContract.verify_invariants(Repo, prefix: prefix)
    assert "people_connector_webhook_nonces: connection ownership mismatch" in errors
    assert "people_connector_workforce_records: workforce mapping mismatch" in errors

    assert "people_connector_webhook_nonces: duplicate identity (connection_id, nonce_hash)" in errors
  end
end
