defmodule Bilimbi.PeopleConnector.Connector.Retention.Attempt do
  @moduledoc false
  use Ecto.Schema

  schema "people_connector_retention_attempts" do
    field(:tenant_id, :integer)
    # Core platform company axis. No workforce identity or login actor ID.
    field(:platform_company_id, :integer)
    field(:kind, :string)
    field(:record_id, :string)
    field(:attempted_at, :utc_datetime_usec)
  end
end
