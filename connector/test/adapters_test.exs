defmodule Bilimbi.PeopleConnector.Connector.AdaptersTest do
  use ExUnit.Case, async: false

  alias Bilimbi.PeopleConnector.Connector.Adapters
  alias Bilimbi.PeopleConnector.Connector.TestAdapter

  setup do
    installed = Adapters.installed()
    for {provider_id, module} <- installed, do: Adapters.unregister(provider_id, module)

    on_exit(fn ->
      for {provider_id, module} <- Adapters.installed(),
          do: Adapters.unregister(provider_id, module)

      for {provider_id, module} <- installed, do: Adapters.register(provider_id, module)
    end)

    :ok
  end

  test "registration serves a provider and withdrawal removes only the same module" do
    assert Adapters.installed() == %{}

    assert :ok = Adapters.register("people.native", TestAdapter)
    assert Adapters.installed() == %{"people.native" => TestAdapter}

    # A later adapter replaces the earlier one; a stale withdrawal changes nothing.
    assert :ok = Adapters.register("people.native", __MODULE__)
    assert :ok = Adapters.unregister("people.native", TestAdapter)
    assert Adapters.installed() == %{"people.native" => __MODULE__}

    assert :ok = Adapters.unregister("people.native", __MODULE__)
    assert Adapters.installed() == %{}
    assert :ok = Adapters.unregister("people.native", __MODULE__)
  end
end
