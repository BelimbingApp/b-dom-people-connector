defmodule Bilimbi.PeopleConnector.Connector.Capability do
  @moduledoc """
  One provider declaration. Direction is explicit so reads cannot imply
  writes; a `:read` declaration maps to the neutral `ReadPort` behaviour and
  a `:write` declaration to `WritePort`, never to an adapter implementation.
  These keys are protocol vocabulary, not operator settings.
  """

  @keys ~w(company_directory employee_directory organization_directory manager_hierarchy user_directory payroll attendance leave claims training documents single_sign_on)

  @enforce_keys [:key, :direction]
  defstruct [:key, :direction]

  @type t :: %__MODULE__{key: String.t(), direction: :read | :write}

  @spec keys() :: [String.t()]
  def keys, do: @keys

  @spec new(String.t(), :read | :write) :: {:ok, t()} | {:error, :invalid_capability}
  def new(key, direction) when key in @keys and direction in [:read, :write],
    do: {:ok, %__MODULE__{key: key, direction: direction}}

  def new(_, _), do: {:error, :invalid_capability}
end
