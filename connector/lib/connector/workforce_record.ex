defmodule Bilimbi.PeopleConnector.Connector.WorkforceRecord do
  @moduledoc """
  One provider directory fact: a company, employee or position.

  An adapter returns these on a read port and consumers read them back from
  the Connector's projection. `source_id` and `stable_id` are the provider's
  identity for the record; `workforce_company_id` is the workforce company
  axis, never a platform company ID. Employee facts carry no login actor.
  `observed_at` is when the provider observed the fact; an older observation
  never replaces a newer one. These are directory facts only, so a provider
  cannot write People business history through them. Position assignments are
  bounded to 500 holder facts; `assignments_incomplete` preserves the provider
  warning that more exist. Parent and employee references use the same workforce
  source and company as the record. `observed_at` fixes their effective day.
  """

  alias Bilimbi.PeopleConnector.Connector.AssignmentRecord

  @enforce_keys [:kind, :source_id, :stable_id, :workforce_company_id, :name, :code, :observed_at]
  defstruct [
    :kind,
    :source_id,
    :stable_id,
    :workforce_company_id,
    :name,
    :code,
    :email,
    :supervisor_stable_id,
    :observed_at,
    :parent_stable_id,
    :version,
    :vacant,
    :assignments_incomplete,
    assignments: [],
    active: true
  ]

  @type kind :: :company | :employee | :position

  @type t :: %__MODULE__{
          kind: kind(),
          source_id: String.t(),
          stable_id: String.t(),
          workforce_company_id: pos_integer(),
          name: String.t(),
          code: String.t(),
          email: String.t() | nil,
          supervisor_stable_id: String.t() | nil,
          observed_at: DateTime.t(),
          parent_stable_id: String.t() | nil,
          version: pos_integer() | nil,
          vacant: boolean() | nil,
          assignments_incomplete: boolean() | nil,
          assignments: [AssignmentRecord.t()],
          active: boolean()
        }

  @doc "The read capability a provider must declare to supply this kind."
  @spec capability(kind()) :: String.t()
  def capability(:company), do: "company_directory"
  def capability(:employee), do: "employee_directory"

  def capability(:position), do: "organization_directory"

  @doc "Accepts only a well-formed record; anything else is refused whole."
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = record) do
    record.kind in [:company, :employee, :position] and identifier?(record.source_id) and
      identifier?(record.stable_id) and is_integer(record.workforce_company_id) and
      record.workforce_company_id > 0 and text?(record.name, 255) and text?(record.code, 100) and
      optional_text?(record.email, 255) and optional_identifier?(record.supervisor_stable_id) and
      is_boolean(record.active) and match?(%DateTime{}, record.observed_at) and
      organisation_valid?(record)
  end

  def valid?(_record), do: false

  defp organisation_valid?(%{kind: :position} = record) do
    optional_identifier?(record.parent_stable_id) and
      (is_nil(record.version) or (is_integer(record.version) and record.version > 0)) and
      is_boolean(record.vacant) and is_boolean(record.assignments_incomplete) and
      is_list(record.assignments) and length(record.assignments) <= 500 and
      Enum.all?(record.assignments, &AssignmentRecord.valid?/1) and
      Enum.all?(record.assignments, &(&1.source_id == record.source_id)) and
      length(Enum.uniq_by(record.assignments, & &1.stable_id)) == length(record.assignments)
  end

  defp organisation_valid?(record),
    do:
      is_nil(record.parent_stable_id) and is_nil(record.version) and is_nil(record.vacant) and
        is_nil(record.assignments_incomplete) and record.assignments == []

  @doc false
  def identifier?(value), do: text?(value, 100)

  defp optional_identifier?(nil), do: true
  defp optional_identifier?(value), do: identifier?(value)

  defp optional_text?(nil, _max), do: true
  defp optional_text?(value, max), do: text?(value, max)

  defp text?(value, max) when is_binary(value),
    do: String.valid?(value) and String.trim(value) != "" and String.length(value) <= max

  defp text?(_value, _max), do: false
end
