defmodule Bilimbi.PeopleConnector.Connector.Sync.Checkpoint do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "people_connector_sync_checkpoints" do
    field(:tenant_id, :integer)
    field(:connection_id, :integer)
    field(:version, :integer)
    field(:resume_cursor, :string)
    field(:as_of_at, :utc_datetime_usec)
    timestamps(type: :naive_datetime)
  end

  def changeset(checkpoint, changes) do
    checkpoint
    |> change(changes)
    |> validate_required([:tenant_id, :connection_id, :version, :as_of_at])
    |> validate_length(:resume_cursor, max: 1000)
    |> unique_constraint(:connection_id,
      name: :people_connector_sync_checkpoints_connection_unique
    )
  end
end
