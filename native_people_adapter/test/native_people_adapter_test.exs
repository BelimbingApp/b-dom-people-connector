defmodule Bilimbi.PeopleConnector.NativePeopleAdapterTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Settings.ContributionValidator
  alias Bilimbi.Base.Settings.TestFixtures, as: SettingsFixtures
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.Employee
  alias Bilimbi.Core.Employee.TestFixtures, as: EmployeeFixtures
  alias Bilimbi.People.Workforce.Contributions, as: WorkforceContributions
  alias Bilimbi.People.Workforce.ReadResult
  alias Bilimbi.PeopleConnector.Connector
  alias Bilimbi.PeopleConnector.Connector.Adapters
  alias Bilimbi.PeopleConnector.Connector.Contributions, as: ConnectorContributions
  alias Bilimbi.PeopleConnector.Connector.Page
  alias Bilimbi.PeopleConnector.Connector.PortAuthorization
  alias Bilimbi.PeopleConnector.Connector.PortRequest
  alias Bilimbi.PeopleConnector.Connector.Providers
  alias Bilimbi.PeopleConnector.Connector.Registry
  alias Bilimbi.PeopleConnector.Connector.Sync
  alias Bilimbi.PeopleConnector.Connector.TestFixtures, as: ConnectorFixtures
  alias Bilimbi.PeopleConnector.Connector.WorkforceRecord
  alias Bilimbi.PeopleConnector.NativePeopleAdapter

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    settings =
      ContributionValidator.validate_contributions!([
        %{
          descriptor: %{id: "people/workforce"},
          payload: WorkforceContributions.contributions().settings
        },
        %{
          descriptor: %{id: "people_connector/connector"},
          payload: ConnectorContributions.contributions().settings
        }
      ])

    ContributionRegistry.put_snapshot_for_test!(%{
      graph_fingerprint: "native-people-adapter-test",
      consumers: %{settings: settings}
    })

    on_exit(&ContributionRegistry.clear_for_test!/0)

    EmployeeFixtures.create_employee_tables!()
    SettingsFixtures.create_settings_table!()
    ConnectorFixtures.create_connection_tables!()

    CompanyFixtures.insert_tenant!(%{id: 41, name: "Tenant A"})
    CompanyFixtures.insert_tenant!(%{id: 42, name: "Tenant B", is_platform_operator: false})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, name: "Company A", code: "a"})
    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, name: "Company B", code: "b"})
    CompanyFixtures.insert_company!(%{id: 75, tenant_id: 42, name: "Company C", code: "c"})

    CompanyFixtures.insert_company!(%{
      id: 76,
      tenant_id: 41,
      name: "Company D",
      code: "d",
      status: "suspended"
    })

    :ok = Employee.ensure_system_types()
    {:ok, scope} = Tenancy.scope(41)
    {:ok, other_scope} = Tenancy.scope(42)

    %{scope: scope, other_scope: other_scope}
  end

  defp employee!(scope, company_id, number, attrs \\ %{}) do
    {:ok, employee} =
      Employee.create_employee(
        scope,
        company_id,
        Map.merge(%{employee_number: number, full_name: "Employee #{number}"}, attrs)
      )

    employee
  end

  defp authorization(scope, attrs \\ %{}) do
    struct!(
      %PortAuthorization{
        scope: scope,
        platform_company_id: 73,
        workforce_source_id: "people/native",
        workforce_company_id: 73,
        provider_id: "people.native",
        capability: "employee_directory"
      },
      attrs
    )
  end

  defp request(attrs \\ %{}),
    do: struct!(%PortRequest{pass: :bootstrap, limit: 100}, attrs)

  defp read_all(authorization, request) do
    Stream.unfold(request, fn
      nil ->
        nil

      request ->
        {:ok, %Page{} = page} = NativePeopleAdapter.read(authorization, request)
        next = page.next_cursor && %{request | cursor: page.next_cursor}
        {page, next}
    end)
    |> Enum.to_list()
  end

  test "the adapter registers itself for the native provider only" do
    assert %{"people.native" => NativePeopleAdapter} = Adapters.installed()
    assert Map.keys(Adapters.installed()) == [Providers.native_id()]
  end

  test "a page carries the company then its employees with People identity", %{scope: scope} do
    boss = employee!(scope, 73, "E-1")
    staff = employee!(scope, 73, "E-2", %{supervisor_id: boss.id, email: "e2@example.com"})
    employee!(scope, 74, "E-3")
    employee!(scope, 73, "A-1", %{employee_type: "agent"})

    assert {:ok, %Page{} = page} = NativePeopleAdapter.read(authorization(scope), request())
    assert page.freshness == :current
    assert page.next_cursor == nil
    assert page.resume_cursor == DateTime.to_iso8601(page.as_of)

    assert [company, first, second] = page.entries
    assert Enum.all?([company, first, second], &WorkforceRecord.valid?/1)

    assert {company.kind, company.source_id, company.stable_id, company.workforce_company_id} ==
             {:company, "people/native", "73", 73}

    assert {company.name, company.code} == {"Company A", "a"}

    assert {first.kind, first.stable_id, first.code} ==
             {:employee, Integer.to_string(boss.id), "E-1"}

    assert second.stable_id == Integer.to_string(staff.id)
    assert second.supervisor_stable_id == Integer.to_string(boss.id)
    assert second.email == "e2@example.com"
    assert first.supervisor_stable_id == nil

    # One watermark for the whole pass; nothing else is written or claimed.
    assert Enum.all?(page.entries, &(&1.observed_at == page.as_of))
    assert Enum.all?(page.entries, & &1.active)
  end

  test "paging is keyed, shares one watermark and misses nothing when the workforce changes",
       %{scope: scope} do
    ids = for n <- 1..5, do: employee!(scope, 73, "E-#{n}").id

    auth = authorization(scope)
    {:ok, first} = NativePeopleAdapter.read(auth, request(%{limit: 2}))
    assert length(first.entries) == 2
    assert first.next_cursor

    # A leaver and a newcomer arrive between pages.
    {:ok, _} = Employee.update_employee(scope, 73, hd(ids), %{status: "terminated"})
    late = employee!(scope, 73, "E-6")

    pages = read_all(auth, request(%{limit: 2, cursor: first.next_cursor}))
    rest = Enum.flat_map(pages, & &1.entries)
    assert Enum.all?(rest, &(&1.observed_at == first.as_of))
    assert Enum.all?(pages, &(&1.as_of == first.as_of))
    assert length(Enum.filter(pages, & &1.next_cursor)) == length(pages) - 1

    stable = Enum.map(first.entries ++ rest, & &1.stable_id)
    assert stable == Enum.uniq(stable)
    assert Integer.to_string(late.id) in stable
    assert Enum.all?(pages, &(length(&1.entries) <= 2))
  end

  test "a changes pass returns the same snapshot; leavers wait for a full read", %{scope: scope} do
    employee!(scope, 73, "E-1")

    {:ok, boot} = NativePeopleAdapter.read(authorization(scope), request())

    {:ok, changes} =
      NativePeopleAdapter.read(
        authorization(scope),
        request(%{pass: :changes, since: boot.resume_cursor})
      )

    assert Enum.map(changes.entries, &{&1.kind, &1.stable_id}) ==
             Enum.map(boot.entries, &{&1.kind, &1.stable_id})

    refute Enum.any?(
             changes.entries,
             &match?(%Bilimbi.PeopleConnector.Connector.Deactivation{}, &1)
           )
  end

  test "it refuses an authorization the Connector could not have issued", %{scope: scope} do
    for {attrs, _label} <- [
          {%{provider_id: "remote.provider"}, "another provider"},
          {%{capability: "company_directory"}, "another capability"},
          {%{capability: "payroll"}, "an undeclared capability"},
          {%{workforce_source_id: "elsewhere"}, "a foreign source"},
          {%{workforce_company_id: 74}, "a company mapped elsewhere"},
          {%{platform_company_id: 0, workforce_company_id: 0}, "no company"}
        ] do
      assert {:error, :invalid_authorization} =
               NativePeopleAdapter.read(authorization(scope, attrs), request())
    end

    assert {:error, :invalid_authorization} = NativePeopleAdapter.read(%{}, request())
    assert {:error, :invalid_authorization} = NativePeopleAdapter.read(nil, nil)
  end

  test "it refuses malformed requests and cursors without reading", %{scope: scope} do
    auth = authorization(scope)

    for bad <- [
          %PortRequest{pass: :write, limit: 1},
          %PortRequest{pass: :bootstrap, limit: 0},
          %PortRequest{pass: :bootstrap, limit: "5"},
          %PortRequest{pass: :changes, limit: 1, since: 5},
          nil
        ] do
      assert {:error, :invalid_request} = NativePeopleAdapter.read(auth, bad)
    end

    for cursor <- ["", "v2:1:1", "v1:x:1", "v1:1:-1", "v1:1", "v1:1:1:1", 42] do
      assert {:error, :invalid_cursor} =
               NativePeopleAdapter.read(auth, request(%{cursor: cursor}))
    end
  end

  test "a company the scope cannot see, or that is not live, is not found", %{
    scope: scope,
    other_scope: other_scope
  } do
    assert {:error, :not_found} =
             NativePeopleAdapter.read(authorization(other_scope), request())

    for id <- [75, 76, 999] do
      assert {:error, :not_found} =
               NativePeopleAdapter.read(
                 authorization(scope, %{platform_company_id: id, workforce_company_id: id}),
                 request()
               )
    end
  end

  describe "through the Connector's synchronisation engine" do
    setup %{scope: scope} do
      ConnectorFixtures.insert_connection!(%{
        tenant_id: 41,
        platform_company_id: 73,
        workforce_company_id: 73,
        enabled: true
      })

      registry = Providers.installed()
      {:ok, status} = Connector.status(scope, 73)
      {:ok, provider} = Registry.fetch(registry, "people.native")
      %{status: status, provider: provider}
    end

    defp sync(context, key, opts \\ []) do
      Sync.run(context.scope, context.status, context.provider, NativePeopleAdapter, key, opts)
    end

    test "bootstraps, projects and stays idempotent", context do
      %{scope: scope} = context
      boss = employee!(scope, 73, "E-1")
      employee!(scope, 73, "E-2", %{supervisor_id: boss.id})
      employee!(scope, 74, "E-3")

      assert {:ok, run} = sync(context, "boot", [])
      assert {run.state, run.pass, run.applied, run.refused} == {:succeeded, :bootstrap, 3, 0}

      assert {:ok, %ReadResult{freshness: :current, value: records}} =
               Connector.workforce(scope, 73)

      assert Enum.map(records, & &1.kind) |> Enum.sort() == [:company, :employee, :employee]

      assert {:ok, again} = sync(context, "again")

      assert {again.state, again.pass, again.applied, again.unchanged} ==
               {:succeeded, :incremental, 0, 3}

      assert {:ok, ^run} = sync(context, "boot")
    end

    test "a full read deactivates a leaver and paging across small limits works", context do
      %{scope: scope} = context
      keep = employee!(scope, 73, "E-1")
      leaver = employee!(scope, 73, "E-2")
      employee!(scope, 73, "E-3")

      {:ok, _} = Sync.put_policy(scope, 73, %{page_limit: 2})
      assert {:ok, %{state: :succeeded, applied: 4}} = sync(context, "boot")

      {:ok, _} = Employee.update_employee(scope, 73, leaver.id, %{status: "terminated"})
      assert {:ok, incremental} = sync(context, "inc")
      assert incremental.deactivated == 0

      assert {:ok, full} = sync(context, "full", full: true)
      assert {full.state, full.deactivated} == {:succeeded, 1}

      {:ok, %ReadResult{value: records}} = Connector.workforce(scope, 73)
      ids = records |> Enum.filter(&(&1.kind == :employee)) |> Enum.map(& &1.stable_id)
      assert Integer.to_string(keep.id) in ids
      refute Integer.to_string(leaver.id) in ids
    end
  end
end
