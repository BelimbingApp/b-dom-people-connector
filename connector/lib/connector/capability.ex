defmodule Bilimbi.PeopleConnector.Connector.Capability do
  @moduledoc """
  One provider declaration. `port` is a provider-neutral behaviour module,
  never an adapter implementation. Direction is explicit so reads cannot
  imply writes. These keys are protocol vocabulary, not operator settings.
  """

  @keys ~w(company_directory employee_directory organization_directory manager_hierarchy user_directory payroll attendance leave claims training documents single_sign_on)

  @enforce_keys [:key, :direction, :port]
  defstruct [:key, :direction, :port]

  @type t :: %__MODULE__{key: String.t(), direction: :read | :write, port: module()}

  @spec keys() :: [String.t()]
  def keys, do: @keys

  @spec new(String.t(), :read | :write, module()) :: {:ok, t()} | {:error, :invalid_capability}
  def new(key, direction, port)
      when key in @keys and direction in [:read, :write] and is_atom(port) do
    expected =
      if direction == :read,
        do: Bilimbi.PeopleConnector.Connector.ReadPort,
        else: Bilimbi.PeopleConnector.Connector.WritePort

    if port == expected,
      do: {:ok, %__MODULE__{key: key, direction: direction, port: port}},
      else: {:error, :invalid_capability}
  end

  def new(_, _, _), do: {:error, :invalid_capability}
end
