defmodule Bilimbi.PeopleConnector.Connector.Provider do
  @moduledoc """
  A provider descriptor with an immutable declaration set.

  `credential` says whether a company connection to this provider needs an
  operator-supplied secret (`:secret`) or none (`:none`). The secret itself is
  never part of the descriptor.
  """

  alias Bilimbi.PeopleConnector.Connector.Capability

  @enforce_keys [:id, :name, :contract_version, :capabilities, :credential]
  defstruct [:id, :name, :contract_version, :capabilities, :credential]

  @type credential :: :none | :secret

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          contract_version: String.t(),
          capabilities: [Capability.t()],
          credential: credential()
        }

  @spec new(String.t(), String.t(), String.t(), [Capability.t()], credential()) ::
          {:ok, t()} | {:error, :invalid_provider}
  def new(id, name, version, capabilities, credential \\ :none)

  def new(id, name, version, capabilities, credential)
      when is_binary(id) and is_binary(name) and is_binary(version) and is_list(capabilities) and
             credential in [:none, :secret] do
    declarations =
      Enum.map(capabilities, fn
        %Capability{key: key, direction: direction} ->
          Capability.new(key, direction)

        _ ->
          {:error, :invalid_capability}
      end)

    keys =
      Enum.map(capabilities, fn
        %Capability{key: key, direction: direction} -> {key, direction}
        _ -> nil
      end)

    if Regex.match?(~r/^[a-z0-9]+(?:[.-][a-z0-9]+)*$/, id) and byte_size(id) <= 100 and
         String.trim(name) != "" and Regex.match?(~r/^1\.\d+\.\d+$/, version) and
         byte_size(version) <= 20 and
         Enum.all?(declarations, &match?({:ok, _}, &1)) and
         length(keys) == length(Enum.uniq(keys)) do
      {:ok,
       %__MODULE__{
         id: id,
         name: name,
         contract_version: version,
         capabilities: capabilities,
         credential: credential
       }}
    else
      {:error, :invalid_provider}
    end
  end

  def new(_, _, _, _, _), do: {:error, :invalid_provider}
end
