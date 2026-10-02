defmodule Bilimbi.PeopleConnector.Connector.Migrations.CreateSyncTables do
  use Ecto.Migration

  # Every table hangs off one company connection. Removing the connection
  # removes what was synchronised through it; People records are never here.
  def up do
    create table(:people_connector_sync_checkpoints, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)

      add(:connection_id, references(:people_connector_connections, on_delete: :delete_all),
        null: false
      )

      add(:version, :bigint, null: false)
      add(:resume_cursor, :string, size: 1000)
      # The oldest provider watermark a completed pass read; freshness is judged on it.
      add(:as_of_at, :utc_datetime_usec, null: false)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_connector_sync_checkpoints, [:connection_id],
        name: :people_connector_sync_checkpoints_connection_unique
      )
    )

    create(
      constraint(:people_connector_sync_checkpoints, :people_connector_sync_checkpoints_version,
        check: "version > 0"
      )
    )

    create table(:people_connector_sync_runs, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)

      add(:connection_id, references(:people_connector_connections, on_delete: :delete_all),
        null: false
      )

      # Platform company axis: the Core Company the run was requested for.
      add(:platform_company_id, :bigint, null: false)
      add(:provider_id, :string, size: 100, null: false)
      add(:idempotency_key, :string, size: 100, null: false)
      add(:pass, :string, size: 20, null: false)
      add(:state, :string, size: 20, null: false)
      add(:reason, :string, size: 60)
      add(:checkpoint_version, :bigint)
      add(:as_of_at, :utc_datetime_usec)
      add(:applied, :integer, null: false, default: 0)
      add(:unchanged, :integer, null: false, default: 0)
      add(:superseded, :integer, null: false, default: 0)
      add(:deactivated, :integer, null: false, default: 0)
      add(:refused, :integer, null: false, default: 0)
      add(:started_at, :utc_datetime_usec, null: false)
      add(:finished_at, :utc_datetime_usec)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_connector_sync_runs, [:connection_id, :idempotency_key],
        name: :people_connector_sync_runs_idempotency_unique
      )
    )

    # At most one pass per connection is in flight.
    create(
      unique_index(:people_connector_sync_runs, [:connection_id],
        name: :people_connector_sync_runs_one_running,
        where: "state = 'running'"
      )
    )

    create(
      constraint(:people_connector_sync_runs, :people_connector_sync_runs_pass,
        check: "pass IN ('bootstrap', 'incremental')"
      )
    )

    create(
      constraint(:people_connector_sync_runs, :people_connector_sync_runs_state,
        check:
          "state IN ('running', 'succeeded', 'stale', 'unavailable', 'refused', 'failed', 'unknown')"
      )
    )

    create table(:people_connector_workforce_records, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)

      add(:connection_id, references(:people_connector_connections, on_delete: :delete_all),
        null: false
      )

      add(:kind, :string, size: 20, null: false)
      # Provider identity: the provider's source and its immutable record ID.
      add(:source_id, :string, size: 100, null: false)
      add(:stable_id, :string, size: 100, null: false)
      # Workforce company axis, never a platform company ID.
      add(:workforce_company_id, :bigint, null: false)
      add(:active, :boolean, null: false)
      add(:name, :string, size: 255, null: false)
      add(:code, :string, size: 100, null: false)
      add(:email, :string, size: 255)
      add(:supervisor_stable_id, :string, size: 100)
      add(:content_hash, :string, size: 64, null: false)
      add(:observed_at, :utc_datetime_usec, null: false)
      add(:deactivated_at, :utc_datetime_usec)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(
        :people_connector_workforce_records,
        [:connection_id, :kind, :source_id, :stable_id],
        name: :people_connector_workforce_records_identity_unique
      )
    )

    create(
      constraint(:people_connector_workforce_records, :people_connector_workforce_records_kind,
        check: "kind IN ('company', 'employee')"
      )
    )

    create table(:people_connector_reconciliation_issues, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)

      add(:connection_id, references(:people_connector_connections, on_delete: :delete_all),
        null: false
      )

      add(:issue_key, :string, size: 200, null: false)
      add(:kind, :string, size: 40, null: false)
      add(:reason, :string, size: 60, null: false)
      add(:severity, :string, size: 10, null: false)
      add(:record_kind, :string, size: 20)
      add(:stable_id, :string, size: 100)
      add(:status, :string, size: 10, null: false)
      add(:occurrences, :integer, null: false, default: 1)
      add(:first_seen_at, :utc_datetime_usec, null: false)
      add(:last_seen_at, :utc_datetime_usec, null: false)
      add(:resolved_at, :utc_datetime_usec)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_connector_reconciliation_issues, [:connection_id, :issue_key],
        name: :people_connector_reconciliation_issues_key_unique
      )
    )

    create(
      constraint(
        :people_connector_reconciliation_issues,
        :people_connector_reconciliation_issues_status,
        check: "status IN ('open', 'resolved') AND severity IN ('warning', 'error')"
      )
    )
  end

  def down do
    drop(table(:people_connector_reconciliation_issues))
    drop(table(:people_connector_workforce_records))
    drop(table(:people_connector_sync_runs))
    drop(table(:people_connector_sync_checkpoints))
  end
end
