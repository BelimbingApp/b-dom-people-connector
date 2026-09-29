defmodule Bilimbi.PeopleConnector.ConnectorTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.PeopleConnector.Connector
  alias Bilimbi.PeopleConnector.Connector.Capability
  alias Bilimbi.PeopleConnector.Connector.Provider
  alias Bilimbi.PeopleConnector.Connector.ReadPort
  alias Bilimbi.PeopleConnector.Connector.Registry
  alias Bilimbi.PeopleConnector.Connector.WritePort

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    CompanyFixtures.create_company_identity_tables!()
    CompanyFixtures.insert_tenant!(%{id: 41})
    CompanyFixtures.insert_tenant!(%{id: 42})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, code: "one"})
    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, code: "two"})
    CompanyFixtures.insert_company!(%{id: 75, tenant_id: 42, code: "three"})
    CompanyFixtures.insert_company!(%{id: 76, tenant_id: 41, code: "four", status: "suspended"})

    {:ok, scope} = Tenancy.scope(41)
    {:ok, other_scope} = Tenancy.scope(42)
    %{scope: scope, other_scope: other_scope}
  end

  test "a disconnected status preserves both company axes and refuses other companies", %{
    scope: scope,
    other_scope: other_scope
  } do
    assert {:ok, status} = Connector.status(scope, 73)
    assert status.state == :disconnected
    assert status.platform_company_id == 73
    assert status.workforce_company_id == 73
    assert status.provider_id == nil

    for id <- [0, 75, 76, 999] do
      assert {:error, :not_found} = Connector.status(scope, id)
    end

    assert {:error, :not_found} = Connector.status(other_scope, 73)
  end

  test "registered declarations refuse writes, other ports, unknown capabilities and all use while disconnected",
       %{
         scope: scope
       } do
    {:ok, read} = Capability.new("employee_directory", :read, ReadPort)
    {:ok, provider} = Provider.new("people.native", "Native People", "1.0.0", [read])
    assert {:ok, registry} = Registry.register(Registry.new(), provider)

    assert {:error, :disconnected} =
             Connector.request_port(
               scope,
               73,
               registry,
               "people.native",
               "employee_directory",
               :read,
               ReadPort
             )

    for {capability, direction, port} <- [
          {"employee_directory", :write, WritePort},
          {"employee_directory", :read, WritePort},
          {"payroll", :read, ReadPort}
        ] do
      assert {:error, :unsupported} =
               Connector.request_port(
                 scope,
                 73,
                 registry,
                 "people.native",
                 capability,
                 direction,
                 port
               )
    end

    assert {:error, :unsupported} =
             Connector.request_port(
               scope,
               73,
               registry,
               "missing",
               "employee_directory",
               :read,
               ReadPort
             )

    assert {:error, :not_found} =
             Connector.request_port(
               scope,
               74_000,
               registry,
               "people.native",
               "employee_directory",
               :read,
               ReadPort
             )
  end

  test "provider declarations reject duplicates, unknown keys and incompatible contracts" do
    {:ok, read} = Capability.new("company_directory", :read, ReadPort)
    assert {:error, :invalid_capability} = Capability.new("company_directory", :write, ReadPort)
    assert {:error, :invalid_capability} = Capability.new("unknown", :read, ReadPort)
    assert {:error, :invalid_provider} = Provider.new("people.native", "Native", "2.0.0", [read])

    assert {:error, :invalid_provider} =
             Provider.new("people.native", "Native", "1.0.0", [read, read])

    {:ok, provider} = Provider.new("people.native", "Native", "1.0.0", [read])
    {:ok, registry} = Registry.register(Registry.new(), provider)
    assert {:error, :duplicate_provider} = Registry.register(registry, provider)
  end
end
