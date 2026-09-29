defmodule Bilimbi.PeopleConnector.Connector.Registry do
  @moduledoc """
  Immutable registry of provider capability declarations. Registration alone
  never activates a connection or exposes an adapter port.
  """

  alias Bilimbi.PeopleConnector.Connector.Provider

  defstruct providers: %{}
  @type t :: %__MODULE__{providers: %{optional(String.t()) => Provider.t()}}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec register(t(), Provider.t()) ::
          {:ok, t()} | {:error, :invalid_provider | :duplicate_provider}
  def register(%__MODULE__{} = registry, %Provider{} = provider) do
    with {:ok, provider} <-
           Provider.new(
             provider.id,
             provider.name,
             provider.contract_version,
             provider.capabilities
           ),
         false <- Map.has_key?(registry.providers, provider.id) do
      {:ok, %__MODULE__{registry | providers: Map.put(registry.providers, provider.id, provider)}}
    else
      true -> {:error, :duplicate_provider}
      error -> error
    end
  end

  def register(%__MODULE__{}, _), do: {:error, :invalid_provider}

  @spec permit(t(), String.t(), String.t(), :read | :write) :: :ok | {:error, :unsupported}
  def permit(%__MODULE__{providers: providers}, provider_id, capability, direction) do
    case Map.get(providers, provider_id) do
      %Provider{capabilities: declarations} ->
        if Enum.any?(declarations, &(&1.key == capability and &1.direction == direction)),
          do: :ok,
          else: {:error, :unsupported}

      nil ->
        {:error, :unsupported}
    end
  end
end
