defmodule Bilimbi.PeopleConnector.Connector.FileExchange.Record do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "people_connector_file_exchanges" do
    field(:tenant_id, :integer)
    field(:platform_company_id, :integer)
    field(:connection_id, :integer)
    field(:workforce_source_id, :string)
    field(:workforce_company_id, :integer)
    field(:direction, Ecto.Enum, values: [:import, :export])
    field(:sha256, :string)
    field(:record_count, :integer)
    field(:state, Ecto.Enum, values: [:pending, :ready, :failed])
    field(:artifact_id, :binary_id)
    field(:expires_at, :utc_datetime_usec)
    field(:failure_reason, :string)
    timestamps(type: :utc_datetime_usec)
  end
end
