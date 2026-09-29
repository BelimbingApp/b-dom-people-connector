defmodule Bilimbi.PeopleConnector.Connector.Connection do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_connector_connections" do
    field(:tenant_id, :integer)
    field(:platform_company_id, :integer)
    field(:provider_id, :string)
    field(:provider_contract_version, :string)
    field(:workforce_source_id, :string)
    field(:workforce_company_id, :integer)
    field(:enabled, :boolean, default: false)
    timestamps(type: :naive_datetime)
  end

  # Every field is assigned by the facade from validated values; nothing is
  # cast from operator input.
  def changeset(connection, changes) do
    connection
    |> change(changes)
    |> validate_required([
      :tenant_id,
      :platform_company_id,
      :provider_id,
      :provider_contract_version,
      :workforce_source_id,
      :workforce_company_id,
      :enabled
    ])
    |> unique_constraint(:platform_company_id,
      name: :people_connector_connections_platform_company_unique
    )
    |> unique_constraint(:workforce_company_id,
      name: :people_connector_connections_workforce_company_unique
    )
  end
end
