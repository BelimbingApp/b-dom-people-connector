defmodule Bilimbi.PeopleConnector.Connector.Migrations.CreateBackups do
  use Ecto.Migration

  def change do
    create table(:people_connector_backups, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      # Platform company axis; the bytes hold the separate workforce mapping.
      add(:platform_company_id, :bigint, null: false)
      add(:connection_id, references(:people_connector_connections, on_delete: :nilify_all))
      add(:sha256, :string, size: 64, null: false)
      add(:state, :string, size: 10, null: false)
      add(:artifact_id, :uuid)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:preview_token_hash, :string, size: 64)
      add(:preview_state_hash, :string, size: 64)
      add(:preview_actor_id, :bigint)
      add(:preview_impersonator_id, :bigint)
      add(:preview_expires_at, :utc_datetime_usec)
      add(:recovery_generation, :integer)
      add(:restored_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:people_connector_backups, [:tenant_id, :platform_company_id, :expires_at]))

    create(
      constraint(:people_connector_backups, :people_connector_backups_state,
        check:
          "state IN ('pending','ready','failed') AND (state <> 'ready' OR artifact_id IS NOT NULL)"
      )
    )
  end
end
