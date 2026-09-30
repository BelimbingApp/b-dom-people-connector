defmodule Bilimbi.PeopleConnector.Connector.SyncRun do
  @moduledoc """
  One synchronisation pass for a company connection, keyed by the caller's
  idempotency key. Asking again with the same key returns this recorded
  outcome instead of reading the provider again.

  `state` is `:running` while in flight, then one of:

    * `:succeeded` - every page was read and applied; the checkpoint moved to
      `checkpoint_version`.
    * `:stale` or `:unavailable` - the provider said its data was not current;
      nothing was applied and the checkpoint did not move.
    * `:refused` - the provider's records were all refused, or the connection
      changed during the pass; the checkpoint did not move.
    * `:failed` - the adapter errored or broke the page contract; nothing was
      applied.
    * `:unknown` - the pass stopped without recording an outcome within the
      company's run timeout. Nothing from it counts as applied and the
      checkpoint did not move; start a new pass with a new key.

  `reason` is a fixed code, never provider text. `platform_company_id` is
  the Core Company axis.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @states ~w(running succeeded stale unavailable refused failed unknown)a

  schema "people_connector_sync_runs" do
    field(:tenant_id, :integer)
    field(:connection_id, :integer)
    field(:platform_company_id, :integer)
    field(:provider_id, :string)
    field(:idempotency_key, :string)
    field(:pass, Ecto.Enum, values: [:bootstrap, :incremental])
    field(:state, Ecto.Enum, values: @states)
    field(:reason, :string)
    field(:checkpoint_version, :integer)
    field(:as_of_at, :utc_datetime_usec)
    field(:applied, :integer, default: 0)
    field(:unchanged, :integer, default: 0)
    field(:superseded, :integer, default: 0)
    field(:deactivated, :integer, default: 0)
    field(:refused, :integer, default: 0)
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    timestamps(type: :naive_datetime)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(run, changes) do
    run
    |> change(changes)
    |> validate_required([
      :tenant_id,
      :connection_id,
      :platform_company_id,
      :provider_id,
      :idempotency_key,
      :pass,
      :state,
      :started_at
    ])
    |> unique_constraint(:idempotency_key, name: :people_connector_sync_runs_idempotency_unique)
    |> unique_constraint(:connection_id, name: :people_connector_sync_runs_one_running)
  end
end
