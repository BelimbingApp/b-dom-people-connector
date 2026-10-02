defmodule Bilimbi.PeopleConnector.Connector.Migrations.CreateWebhooks do
  use Ecto.Migration

  def change do
    for {table_name, identity} <- [
          {:people_connector_webhook_deliveries, :delivery_hash},
          {:people_connector_webhook_nonces, :nonce_hash}
        ] do
      create table(table_name, primary_key: false) do
        add(:id, :bigserial, primary_key: true)
        add(:tenant_id, :bigint, null: false)

        add(:connection_id, references(:people_connector_connections, on_delete: :delete_all),
          null: false
        )

        add(identity, :string, size: 64, null: false)
        if identity == :delivery_hash, do: add(:body_hash, :string, size: 64, null: false)
        add(:received_at, :utc_datetime_usec, null: false)
      end

      create(
        unique_index(table_name, [:connection_id, identity],
          name: :"#{table_name}_identity_unique"
        )
      )
    end
  end
end
