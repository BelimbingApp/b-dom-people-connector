defmodule Bilimbi.PeopleConnector.Connector.Adapters do
  @moduledoc """
  Read-port adapters that serve installed providers, keyed by provider ID.

  Each value is a module implementing `ReadPort`. No adapter is installed
  yet: the native People adapter is a separate module that depends on this
  one. Until an adapter serves a provider, a sync request for it is refused
  with `:adapter_unavailable`.
  """

  @type t :: %{optional(String.t()) => module()}

  @spec installed() :: t()
  def installed, do: %{}
end
