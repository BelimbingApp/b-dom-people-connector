defmodule Bilimbi.PeopleConnector.Connector.Adapters do
  @moduledoc """
  Read-port adapters that serve installed providers, keyed by provider ID.

  Each value is a module implementing `ReadPort`. An adapter module cannot be
  a dependency of the Connector (it depends on the Connector), so a mounted
  adapter registers itself at application startup, as People's position owner
  registers with Workforce, and withdraws when it stops. Until an adapter
  serves a provider, a sync request for it is refused with
  `:adapter_unavailable`. Registration never activates a connection or adds a
  capability: the provider's declaration and the enabled connection still
  gate every port call.
  """

  @key {__MODULE__, :installed}

  @type t :: %{optional(String.t()) => module()}

  @spec installed() :: t()
  def installed, do: :persistent_term.get(@key, %{})

  @doc "Registers the adapter that serves `provider_id`, replacing any earlier one."
  @spec register(String.t(), module()) :: :ok
  def register(provider_id, module) when is_binary(provider_id) and is_atom(module) do
    :persistent_term.put(@key, Map.put(installed(), provider_id, module))
    :ok
  end

  @doc "Withdraws `module` if it is still the adapter for `provider_id`."
  @spec unregister(String.t(), module()) :: :ok
  def unregister(provider_id, module) when is_binary(provider_id) and is_atom(module) do
    case installed() do
      %{^provider_id => ^module} = current ->
        :persistent_term.put(@key, Map.delete(current, provider_id))

      _ ->
        :ok
    end
  end
end
