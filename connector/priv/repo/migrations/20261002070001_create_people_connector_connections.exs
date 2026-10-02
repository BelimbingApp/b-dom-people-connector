defmodule Bilimbi.PeopleConnector.Connector.Migrations.CreateConnections do
  use Ecto.Migration

  def up do
    create table(:people_connector_connections, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:tenant_id, :bigint, null: false)
      # Platform company axis: a Core Company ID in `tenant_id`.
      add(:platform_company_id, :bigint, null: false)
      add(:provider_id, :string, size: 100, null: false)
      add(:provider_contract_version, :string, size: 20, null: false)
      # Workforce company axis: the People Workforce identity mapped at setup.
      add(:workforce_source_id, :string, size: 100, null: false)
      add(:workforce_company_id, :bigint, null: false)
      add(:enabled, :boolean, null: false, default: false)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:people_connector_connections, [:platform_company_id],
        name: :people_connector_connections_platform_company_unique
      )
    )

    create(
      unique_index(
        :people_connector_connections,
        [:tenant_id, :workforce_source_id, :workforce_company_id],
        name: :people_connector_connections_workforce_company_unique
      )
    )
  end

  def down do
    drop(table(:people_connector_connections))
  end
end
