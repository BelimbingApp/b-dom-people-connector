defmodule Bilimbi.PeopleConnector.Connector.Migrations.CreateFileExchanges do
  use Ecto.Migration

  def change do
    create table(:people_connector_file_exchanges, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:tenant_id, references(:tenants, on_delete: :restrict), null: false)
      # Core platform company axis, not a workforce company or login actor.
      add(:platform_company_id, references(:companies, on_delete: :restrict), null: false)
      add(:connection_id, references(:people_connector_connections, on_delete: :nilify_all))
      add(:workforce_source_id, :string, size: 100, null: false)
      add(:workforce_company_id, :bigint, null: false)
      add(:direction, :string, size: 10, null: false)
      add(:sha256, :string, size: 64, null: false)
      add(:record_count, :integer, null: false)
      add(:state, :string, size: 10, null: false)
      # Base exposes an opaque artifact ID; its metadata/storage schema stays private.
      add(:artifact_id, :uuid)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(
        :people_connector_file_exchanges,
        [:connection_id, :direction, :sha256],
        name: :people_connector_file_exchanges_replay_unique
      )
    )

    create(index(:people_connector_file_exchanges, [:tenant_id, :platform_company_id]))

    create(
      constraint(:people_connector_file_exchanges, :people_connector_file_exchange_values,
        check:
          "direction IN ('import', 'export') AND state IN ('pending', 'ready', 'failed') AND record_count >= 0 AND workforce_company_id > 0 AND (state <> 'ready' OR artifact_id IS NOT NULL)"
      )
    )
  end
end
