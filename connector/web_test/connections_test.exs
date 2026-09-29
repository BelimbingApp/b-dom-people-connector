defmodule Bilimbi.PeopleConnector.Connector.ConnectionsTest do
  @moduledoc """
  Connection writes through the facade with a signed-in actor. These run in
  the Web host so Authz grants, Settings encryption and Audit are real.
  """

  use BilimbiWeb.ConnCase, async: false

  alias Bilimbi.Base.Audit
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Authentication
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.PeopleConnector.Connector
  alias Bilimbi.PeopleConnector.Connector.Capability
  alias Bilimbi.PeopleConnector.Connector.Provider
  alias Bilimbi.PeopleConnector.Connector.Providers
  alias Bilimbi.PeopleConnector.Connector.Registry
  alias Bilimbi.PeopleConnector.Connector.TestFixtures, as: ConnectorFixtures
  alias Ecto.Adapters.SQL

  @manage "people-connector.connections.manage"
  @secret_provider "remote.test"

  setup do
    UserFixtures.create_user_tables!()
    ConnectorFixtures.create_connection_tables!()
    CompanyFixtures.insert_tenant!(%{id: 41})
    CompanyFixtures.insert_tenant!(%{id: 42})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, code: "one", name: "Company A"})
    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, code: "two", name: "Company B"})
    CompanyFixtures.insert_company!(%{id: 75, tenant_id: 42, code: "three", name: "Company C"})
    UserFixtures.insert_user!(%{id: 91, company_id: 73, name: "Operator"})
    UserFixtures.insert_user!(%{id: 92, company_id: 73, name: "Viewer", email: "viewer@example.com"})

    {:ok, system} = Tenancy.scope(41)
    operator = Authentication.sign_in(system, 91, 73)
    viewer = Authentication.sign_in(system, 92, 73)

    {:ok, read} = Capability.new("employee_directory", :read)
    {:ok, remote} = Provider.new(@secret_provider, "Remote test", "1.0.0", [read], :secret)
    {:ok, registry} = Registry.register(Providers.installed(), remote)

    %{operator: operator, viewer: viewer, registry: registry}
  end

  test "configuring the native provider records both company axes, disabled, and audits it",
       %{operator: operator, registry: registry} do
    grant_capabilities!(@manage)

    assert {:ok, status} =
             Connector.configure_connection(operator, 73, registry, Providers.native_id())

    assert status.state == :disabled
    assert status.provider_id == Providers.native_id()
    assert status.platform_company_id == 73
    assert status.workforce_company_id == 73
    assert status.workforce_source_id == "people/native"

    assert {:error, :credential_not_required} =
             Connector.put_credential(operator, 73, registry, "unused")

    assert {:ok, %{state: :enabled}} = Connector.set_enabled(operator, 73, registry, true)

    {:ok, mutations} = Audit.list_mutations(operator)

    connection_events =
      mutations
      |> Enum.filter(&String.ends_with?(&1.auditable_type, "Connector.Connection"))
      |> Enum.map(& &1.event)

    assert connection_events == ["created", "updated"]
  end

  test "a same-tenant sibling company needs tenant-wide company reach", %{
    operator: operator,
    registry: registry
  } do
    grant_capabilities!(@manage)
    native = Providers.native_id()

    assert {:error, :unauthorized} = Connector.configure_connection(operator, 74, registry, native)
    assert {:error, :unauthorized} = Connector.set_enabled(operator, 74, registry, true)
    assert {:error, :unauthorized} = Connector.remove_connection(operator, 74)
    assert {:ok, %{state: :disconnected}} = Connector.status(operator, 74)

    grant_capabilities!("admin.company.tenant-wide.manage")

    assert {:ok, %{platform_company_id: 74, workforce_company_id: 74}} =
             Connector.configure_connection(operator, 74, registry, native)

    assert {:error, :not_found} = Connector.configure_connection(operator, 75, registry, native)
  end

  test "an actor without the manage capability changes nothing", %{
    viewer: viewer,
    registry: registry
  } do
    grant_capabilities!(["people-connector.connections.view"], user_id: 92)

    assert {:error, :unauthorized} =
             Connector.configure_connection(viewer, 73, registry, Providers.native_id())

    assert {:ok, %{state: :disconnected}} = Connector.status(viewer, 73)
  end

  test "one workforce company cannot back two platform companies", %{
    operator: operator,
    registry: registry
  } do
    grant_capabilities!(@manage)

    ConnectorFixtures.insert_connection!(%{
      tenant_id: 41,
      platform_company_id: 74,
      workforce_company_id: 73
    })

    assert {:error, :workforce_company_taken} =
             Connector.configure_connection(operator, 73, registry, Providers.native_id())
  end

  test "reconfiguring a stale mapping records the current one and disables the connection", %{
    operator: operator,
    registry: registry
  } do
    grant_capabilities!(@manage)

    ConnectorFixtures.insert_connection!(%{
      tenant_id: 41,
      platform_company_id: 73,
      workforce_company_id: 999,
      enabled: true
    })

    assert {:error, :mapping_changed} = Connector.status(operator, 73)
    assert {:error, :mapping_changed} = Connector.set_enabled(operator, 73, registry, true)

    assert {:ok, %{state: :disabled, workforce_company_id: 73}} =
             Connector.configure_connection(operator, 73, registry, Providers.native_id())
  end

  test "a provider credential is stored encrypted, required to enable, and never read back", %{
    operator: operator,
    registry: registry
  } do
    grant_capabilities!(@manage)
    secret = "credential-#{System.unique_integer([:positive])}"

    assert {:error, :disconnected} = Connector.put_credential(operator, 73, registry, secret)
    assert {:ok, _status} = Connector.configure_connection(operator, 73, registry, @secret_provider)
    assert {:error, :credential_missing} = Connector.set_enabled(operator, 73, registry, true)

    for invalid <- ["", "   ", String.duplicate("x", 4097), 42] do
      assert {:error, :invalid_credential} =
               Connector.put_credential(operator, 73, registry, invalid)
    end

    assert :ok = Connector.put_credential(operator, 73, registry, secret)
    assert {:ok, status} = Connector.set_enabled(operator, 73, registry, true)
    assert status.credential_stored?
    refute inspect(status) =~ secret

    %{rows: [[encrypted?, stored]]} =
      SQL.query!(
        Repo,
        "SELECT is_encrypted, value::text FROM base_settings WHERE key = $1 AND scope_id = 73",
        [Connector.credential_key()]
      )

    assert encrypted?
    refute stored =~ secret

    assert {:error, :adapter_unavailable} =
             Connector.request_port(operator, 73, registry, @secret_provider, "employee_directory", :read)

    assert :ok = Connector.clear_credential(operator, 73, registry)
    assert {:ok, %{state: :disabled, credential_stored?: false}} = Connector.status(operator, 73)
  end

  test "changing provider discards the previous credential; removing deletes both", %{
    operator: operator,
    registry: registry
  } do
    grant_capabilities!(@manage)

    assert {:ok, _status} = Connector.configure_connection(operator, 73, registry, @secret_provider)
    assert :ok = Connector.put_credential(operator, 73, registry, "first-secret")

    assert {:ok, %{provider_id: "people.native", credential_stored?: false}} =
             Connector.configure_connection(operator, 73, registry, Providers.native_id())

    assert {:ok, _status} = Connector.configure_connection(operator, 73, registry, @secret_provider)
    assert :ok = Connector.put_credential(operator, 73, registry, "second-secret")
    assert :ok = Connector.remove_connection(operator, 73)
    assert {:ok, %{state: :disconnected, credential_stored?: false}} = Connector.status(operator, 73)
    assert {:error, :disconnected} = Connector.remove_connection(operator, 73)

    assert %{rows: [[0]]} =
             SQL.query!(Repo, "SELECT count(*) FROM base_settings WHERE key = $1", [
               Connector.credential_key()
             ])
  end
end
