defmodule Bilimbi.PeopleConnector.Connector.Webhooks.Delivery do
  @moduledoc false
  use Ecto.Schema

  schema "people_connector_webhook_deliveries" do
    field(:tenant_id, :integer)
    field(:connection_id, :integer)
    field(:delivery_hash, :string)
    field(:body_hash, :string)
    field(:received_at, :utc_datetime_usec)
  end
end
