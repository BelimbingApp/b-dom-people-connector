defmodule Bilimbi.PeopleConnector.Connector.Migrations.CreateRetentionAttempts do
  use Ecto.Migration

  def change do
    create table(:people_connector_retention_attempts) do
      add(:tenant_id, :bigint, null: false)
      # Core platform company axis; attempts contain no workforce or actor IDs.
      add(:platform_company_id, :bigint, null: false)
      add(:kind, :string, size: 10, null: false)
      add(:record_id, :string, size: 36, null: false)
      add(:attempted_at, :utc_datetime_usec, null: false)
    end

    create(
      unique_index(
        :people_connector_retention_attempts,
        [:platform_company_id, :kind, :record_id],
        name: :people_connector_retention_attempts_identity
      )
    )

    create(
      constraint(:people_connector_retention_attempts, :people_connector_retention_attempts_kind,
        check: "kind IN ('sync', 'webhook', 'nonce', 'file')"
      )
    )

    create(
      index(:people_connector_sync_runs, [:connection_id, :finished_at],
        name: :people_connector_sync_runs_retention
      )
    )

    create(
      index(:people_connector_webhook_deliveries, [:connection_id, :received_at],
        name: :people_connector_webhook_deliveries_retention
      )
    )

    create(
      index(:people_connector_webhook_nonces, [:connection_id, :received_at],
        name: :people_connector_webhook_nonces_retention
      )
    )

    create(
      index(:people_connector_file_exchanges, [:tenant_id, :platform_company_id, :inserted_at],
        name: :people_connector_file_exchanges_retention
      )
    )
  end
end
