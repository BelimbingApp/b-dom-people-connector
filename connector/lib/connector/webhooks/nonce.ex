defmodule Bilimbi.PeopleConnector.Connector.Webhooks.Nonce do
  @moduledoc false
  use Ecto.Schema

  schema "people_connector_webhook_nonces" do
    field(:tenant_id, :integer)
    field(:connection_id, :integer)
    field(:nonce_hash, :string)
    field(:received_at, :utc_datetime_usec)
  end
end
