defmodule Bilimbi.PeopleConnector.Connector.Providers do
  @moduledoc """
  The providers an operator may choose in this installation.

  Only the co-located native People provider is offered. It reads through the
  mounted People Workforce public API, so it needs no credential and no
  transport. Remote and third-party providers are not offered until their
  transport and authority are separately evidenced.
  """

  alias Bilimbi.PeopleConnector.Connector.Capability
  alias Bilimbi.PeopleConnector.Connector.Provider
  alias Bilimbi.PeopleConnector.Connector.Registry

  @native_id "people.native"

  @spec native_id() :: String.t()
  def native_id, do: @native_id

  @spec installed() :: Registry.t()
  def installed do
    {:ok, company} = Capability.new("company_directory", :read)
    {:ok, employees} = Capability.new("employee_directory", :read)

    {:ok, native} =
      Provider.new(@native_id, "People (this installation)", "1.0.0", [company, employees])

    {:ok, registry} = Registry.register(Registry.new(), native)
    registry
  end
end
