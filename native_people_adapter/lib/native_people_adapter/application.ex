defmodule Bilimbi.PeopleConnector.NativePeopleAdapter.Application do
  @moduledoc false
  use Application

  alias Bilimbi.PeopleConnector.Connector.Adapters
  alias Bilimbi.PeopleConnector.Connector.Providers
  alias Bilimbi.PeopleConnector.NativePeopleAdapter

  @impl true
  def start(_type, _args) do
    :ok = Adapters.register(Providers.native_id(), NativePeopleAdapter)
    Supervisor.start_link([], strategy: :one_for_one, name: __MODULE__.Supervisor)
  end

  @impl true
  def stop(_state) do
    Adapters.unregister(Providers.native_id(), NativePeopleAdapter)
    :ok
  end
end
