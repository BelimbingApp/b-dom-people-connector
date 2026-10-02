defmodule Bilimbi.PeopleConnector.Connector.AssignmentRecord do
  @moduledoc """
  A bounded position holder fact as of the enclosing position's observation day.

  `source_id` and `stable_id` identify the assignment; `employee_stable_id`
  identifies an employee in that same workforce source and company, never a
  login actor. Dates and business history remain owned by the provider.
  """

  alias Bilimbi.PeopleConnector.Connector.WorkforceRecord

  @enforce_keys [:source_id, :stable_id, :employee_stable_id, :kind]
  @derive Jason.Encoder
  defstruct [:source_id, :stable_id, :employee_stable_id, :kind]

  @type t :: %__MODULE__{
          source_id: String.t(),
          stable_id: String.t(),
          employee_stable_id: String.t(),
          kind: String.t()
        }

  def valid?(%__MODULE__{} = assignment) do
    Enum.all?(
      [assignment.source_id, assignment.stable_id, assignment.employee_stable_id],
      &WorkforceRecord.identifier?/1
    ) and WorkforceRecord.identifier?(assignment.kind)
  end

  def valid?(_), do: false

  @doc false
  def from_map(map) do
    %__MODULE__{
      source_id: map["source_id"],
      stable_id: map["stable_id"],
      employee_stable_id: map["employee_stable_id"],
      kind: map["kind"]
    }
  end
end
