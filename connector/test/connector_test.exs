defmodule Bilimbi.PeopleConnector.ConnectorTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Settings.ContributionValidator
  alias Bilimbi.Base.Settings.TestFixtures, as: SettingsFixtures
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.People.Workforce
  alias Bilimbi.People.Workforce.ReadResult
  alias Bilimbi.PeopleConnector.Connector
  alias Bilimbi.PeopleConnector.Connector.Capability
  alias Bilimbi.PeopleConnector.Connector.Contributions
  alias Bilimbi.PeopleConnector.Connector.Providers
  alias Bilimbi.PeopleConnector.Connector.TestFixtures, as: ConnectorFixtures
  alias Bilimbi.PeopleConnector.Connector.Provider
  alias Bilimbi.PeopleConnector.Connector.Registry
  alias Bilimbi.PeopleConnector.Connector.Status

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    settings =
      ContributionValidator.validate_contributions!([
        %{
          descriptor: %{id: "people_connector/connector"},
          payload: Contributions.contributions().settings
        }
      ])

    ContributionRegistry.put_snapshot_for_test!(%{
      graph_fingerprint: "people-connector-test",
      consumers: %{settings: settings}
    })

    on_exit(&ContributionRegistry.clear_for_test!/0)

    CompanyFixtures.create_company_identity_tables!()
    SettingsFixtures.create_settings_table!()
    ConnectorFixtures.create_connection_tables!()
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
    assert status.workforce_source_id == Workforce.source_id()
    assert status.provider_id == nil
    refute status.credential_stored?

    for id <- [0, 75, 76, 999] do
      assert {:error, :not_found} = Connector.status(scope, id)
    end

    assert {:error, :not_found} = Connector.status(other_scope, 73)
  end

  test "stale and unavailable workforce identity never become a usable company mapping", %{
    scope: scope
  } do
    assert {:ok, %ReadResult{value: company}} = Workforce.company(scope, 73)
    last_confirmed_at = DateTime.utc_now()

    assert {:error, {:not_current, {:stale, ^last_confirmed_at}}} =
             Status.from_workforce_result(ReadResult.stale(company, last_confirmed_at))

    assert {:error, {:not_current, {:unavailable, :provider_offline}}} =
             Status.from_workforce_result(ReadResult.unavailable(:provider_offline))

    assert {:error, :not_found} = Status.from_workforce_result(ReadResult.current(nil))
  end

  test "registered declarations refuse writes, unknown capabilities and all use while disconnected",
       %{
         scope: scope
       } do
    {:ok, read} = Capability.new("employee_directory", :read)
    {:ok, provider} = Provider.new("people.native", "Native People", "1.0.0", [read])
    assert {:ok, registry} = Registry.register(Registry.new(), provider)

    assert {:error, :disconnected} =
             Connector.request_port(
               scope,
               73,
               registry,
               "people.native",
               "employee_directory",
               :read
             )

    for {capability, direction} <- [
          {"employee_directory", :write},
          {"payroll", :read}
        ] do
      assert {:error, :unsupported} =
               Connector.request_port(
                 scope,
                 73,
                 registry,
                 "people.native",
                 capability,
                 direction
               )
    end

    assert {:error, :unsupported} =
             Connector.request_port(
               scope,
               73,
               registry,
               "missing",
               "employee_directory",
               :read
             )

    assert {:error, :not_found} =
             Connector.request_port(
               scope,
               74_000,
               registry,
               "people.native",
               "employee_directory",
               :read
             )
  end

  test "provider declarations reject duplicates, unknown keys and incompatible contracts" do
    {:ok, read} = Capability.new("company_directory", :read)
    assert {:error, :invalid_capability} = Capability.new("company_directory", :sync)
    assert {:error, :invalid_capability} = Capability.new("unknown", :read)
    assert {:error, :invalid_provider} = Provider.new("people.native", "Native", "2.0.0", [read])

    assert {:error, :invalid_provider} =
             Provider.new("people.native", "Native", "1.0.0", [read], :token)

    assert {:ok, %Provider{credential: :secret}} =
             Provider.new("remote.test", "Remote", "1.0.0", [read], :secret)

    assert {:error, :invalid_provider} =
             Provider.new("people.native", "Native", "1.0.0", [read, read])

    {:ok, provider} = Provider.new("people.native", "Native", "1.0.0", [read])
    {:ok, registry} = Registry.register(Registry.new(), provider)
    assert {:error, :duplicate_provider} = Registry.register(registry, provider)
  end

  test "a stored connection reports its state only while its company mapping is current", %{
    scope: scope,
    other_scope: other_scope
  } do
    ConnectorFixtures.insert_connection!(%{
      tenant_id: 41,
      platform_company_id: 73,
      workforce_company_id: 73,
      enabled: true
    })

    assert {:ok, status} = Connector.status(scope, 73)
    assert status.state == :enabled
    assert status.provider_id == Providers.native_id()
    assert {:error, :not_found} = Connector.status(other_scope, 73)

    ConnectorFixtures.insert_connection!(%{
      tenant_id: 41,
      platform_company_id: 74,
      workforce_company_id: 999
    })

    assert {:error, :mapping_changed} = Connector.status(scope, 74)

    registry = Providers.installed()

    assert {:error, :mapping_changed} =
             Connector.request_port(
               scope,
               74,
               registry,
               Providers.native_id(),
               "employee_directory",
               :read
             )
  end

  test "an enabled connection still serves no port before an adapter exists", %{scope: scope} do
    ConnectorFixtures.insert_connection!(%{
      tenant_id: 41,
      platform_company_id: 73,
      workforce_company_id: 73,
      enabled: true
    })

    registry = Providers.installed()
    native = Providers.native_id()

    assert {:error, :adapter_unavailable} =
             Connector.request_port(scope, 73, registry, native, "employee_directory", :read)

    assert {:error, :unsupported} =
             Connector.request_port(scope, 73, registry, native, "employee_directory", :write)
  end

  test "system work without a signed-in actor cannot change a connection", %{scope: scope} do
    registry = Providers.installed()
    native = Providers.native_id()

    assert {:error, :unauthorized} = Connector.configure_connection(scope, 73, registry, native)
    assert {:error, :unauthorized} = Connector.put_credential(scope, 73, registry, "secret")
    assert {:error, :unauthorized} = Connector.clear_credential(scope, 73, registry)
    assert {:error, :unauthorized} = Connector.set_enabled(scope, 73, registry, true)
    assert {:error, :unauthorized} = Connector.remove_connection(scope, 73)
    assert {:ok, %Status{state: :disconnected}} = Connector.status(scope, 73)
  end

  test "the installed catalog offers only the credential-free native provider" do
    assert [provider] = Registry.providers(Providers.installed())
    assert provider.id == Providers.native_id()
    assert provider.credential == :none
    assert Enum.all?(provider.capabilities, &(&1.direction == :read))
  end
end
