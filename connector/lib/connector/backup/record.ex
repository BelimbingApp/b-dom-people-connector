defmodule Bilimbi.PeopleConnector.Connector.Backup.Record do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "people_connector_backups" do
    field(:tenant_id, :integer)
    # Core platform company, distinct from the snapshot's workforce company.
    field(:platform_company_id, :integer)
    field(:connection_id, :integer)
    field(:sha256, :string)
    field(:state, Ecto.Enum, values: [:pending, :ready, :failed], default: :pending)
    field(:artifact_id, :binary_id)
    field(:expires_at, :utc_datetime_usec)
    field(:preview_token_hash, :string)
    field(:preview_state_hash, :string)
    field(:preview_actor_id, :integer)
    field(:preview_impersonator_id, :integer)
    field(:preview_expires_at, :utc_datetime_usec)
    field(:recovery_generation, :integer)
    field(:restored_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end
