defmodule Bilimbi.PeopleConnector.Connector.Deactivation do
  @moduledoc """
  A provider change saying a record it supplied earlier is no longer active.

  The projection keeps the record, marked inactive, rather than deleting it.
  An unknown reference is a reconciliation issue, and an older deactivation
  never undoes a newer observation.
  """

  alias Bilimbi.PeopleConnector.Connector.WorkforceRecord

  @enforce_keys [:kind, :source_id, :stable_id, :observed_at]
  defstruct [:kind, :source_id, :stable_id, :observed_at]

  @type t :: %__MODULE__{
          kind: WorkforceRecord.kind(),
          source_id: String.t(),
          stable_id: String.t(),
          observed_at: DateTime.t()
        }

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = change) do
    change.kind in [:company, :employee, :position] and
      WorkforceRecord.identifier?(change.source_id) and
      WorkforceRecord.identifier?(change.stable_id) and match?(%DateTime{}, change.observed_at)
  end

  def valid?(_change), do: false
end
