defmodule Bilimbi.PeopleConnector.Connector.Sync.Projection do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_connector_workforce_records" do
    field(:tenant_id, :integer)
    field(:connection_id, :integer)
    field(:kind, Ecto.Enum, values: [:company, :employee, :position])
    field(:source_id, :string)
    field(:stable_id, :string)
    field(:workforce_company_id, :integer)
    field(:active, :boolean)
    field(:name, :string)
    field(:code, :string)
    field(:email, :string)
    field(:supervisor_stable_id, :string)
    field(:parent_stable_id, :string)
    field(:version, :integer)
    field(:vacant, :boolean)
    field(:assignments_incomplete, :boolean)
    field(:assignments, {:array, :map}, default: [])
    field(:content_hash, :string)
    field(:observed_at, :utc_datetime_usec)
    field(:deactivated_at, :utc_datetime_usec)
    timestamps(type: :naive_datetime)
  end

  def changeset(projection, changes) do
    projection
    |> change(changes)
    |> validate_required([
      :tenant_id,
      :connection_id,
      :kind,
      :source_id,
      :stable_id,
      :workforce_company_id,
      :active,
      :name,
      :code,
      :content_hash,
      :observed_at
    ])
    |> unique_constraint(:stable_id, name: :people_connector_workforce_records_identity_unique)
  end
end
