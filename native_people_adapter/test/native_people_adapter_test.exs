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

    Bilimbi.People.Workforce.register_position_reader(__MODULE__.PositionReader)

    on_exit(fn ->
      Bilimbi.People.Workforce.unregister_position_reader(__MODULE__.PositionReader)
    end)

    %{scope: scope, other_scope: other_scope}
  end

  defmodule PositionReader do
    def positions(_scope, _company, date, options) do
      send(self(), {:positions_read, date, options})
      rows = Process.get(:native_test_positions, [])
      size = Keyword.fetch!(options, :page_size)
      page = Keyword.fetch!(options, :page)
      {:ok, Enum.slice(rows, (page - 1) * size, size)}
    end
  end

  defp position(id, attrs \\ %{}) do
    alias Bilimbi.People.Workforce.{Position, Reference}

    struct!(
      %Position{
        reference: %Reference{
          source_id: "people/native",
          type: :position,
          stable_id: to_string(id)
        },
        company_reference: %Reference{source_id: "people/native", type: :company, stable_id: "73"},
        platform_company_id: 73,
        workforce_company_id: 73,
        code: "P-#{id}",
        title: "Position #{id}",
        version: 1,
        vacant?: true,
        assignments: [],
        assignments_incomplete?: false
      },
      attrs
    )
  end

  test "organisation declarations and bounded position assignments preserve workforce identity",
       %{scope: scope} do
    alias Bilimbi.People.Workforce.Reference

    holder = %{
      reference: %Reference{source_id: "people/native", type: :assignment, stable_id: "1"},
      employee_reference: %Reference{source_id: "people/native", type: :employee, stable_id: "1"},
      kind: "acting"
    }

    Process.put(:native_test_positions, [
      position(1),
      position(2, %{
        assignments: [holder],
        vacant?: true,
        parent_reference: %Reference{source_id: "people/native", type: :position, stable_id: "1"},
        assignments_incomplete?: true
      })
    ])

    auth = authorization(scope, %{capability: "organization_directory"})
    pages = read_all(auth, request(%{limit: 1}))
    assert [first, second] = Enum.flat_map(pages, & &1.entries)
    assert first.kind == :position and first.stable_id == "1"
    assert second.parent_stable_id == "1" and second.version == 1 and second.vacant
    assert second.assignments_incomplete
    assert [%{stable_id: "1", employee_stable_id: "1", kind: "acting"}] = second.assignments
    assert Enum.all?([first, second], &WorkforceRecord.valid?/1)
    assert Enum.all?(pages, &(&1.as_of == hd(pages).as_of and &1.snapshot))
    assert_receive {:positions_read, date, _}
    assert date == DateTime.to_date(hd(pages).as_of)

    {:ok, replay} =
      NativePeopleAdapter.read(auth, request(%{limit: 1, cursor: hd(pages).next_cursor}))

    assert replay == Enum.at(pages, 1)

    assert {:error, :invalid_cursor} =
             NativePeopleAdapter.read(
               auth,
               request(%{limit: 2, cursor: hd(pages).next_cursor})
             )

    assert {:error, :invalid_cursor} =
             NativePeopleAdapter.read(
               authorization(scope, %{
                 capability: "organization_directory",
                 platform_company_id: 74,
                 workforce_company_id: 74
               }),
               request(%{limit: 1, cursor: hd(pages).next_cursor})
             )

    assert {:error, :invalid_cursor} =
             NativePeopleAdapter.read(auth, request(%{cursor: "v1:1:1"}))
  end

  test "organisation reads refuse scope, mapping, forged authority and missing owners", %{
    scope: scope,
    other_scope: other
  } do
    auth = authorization(scope, %{capability: "organization_directory"})
    assert {:error, :not_found} = NativePeopleAdapter.read(%{auth | scope: other}, request())

    assert {:error, :invalid_authorization} =
             NativePeopleAdapter.read(%{auth | scope: nil}, request())

    assert {:error, :invalid_authorization} =
             NativePeopleAdapter.read(%{auth | direction: :write}, request())

    Process.put(:native_test_positions, [position(1, %{workforce_company_id: 74})])
    assert {:error, :mapping_mismatch} = NativePeopleAdapter.read(auth, request())
    Bilimbi.People.Workforce.unregister_position_reader(__MODULE__.PositionReader)

    assert {:ok, %{freshness: {:unavailable, :organisation_unavailable}, entries: []}} =
             NativePeopleAdapter.read(auth, request())
  end

  test "organisation reads stay within the public seam page bound", %{scope: scope} do
    Process.put(:native_test_positions, Enum.map(1..101, &position/1))
    auth = authorization(scope, %{capability: "organization_directory"})
    {:ok, first} = NativePeopleAdapter.read(auth, request(%{limit: 1000}))
    assert length(first.entries) == 100
    assert_receive {:positions_read, _, [page: 1, page_size: 100]}

    {:ok, final} =
      NativePeopleAdapter.read(auth, request(%{limit: 1000, cursor: first.next_cursor}))

    assert [%{stable_id: "101"}] = final.entries
    assert final.next_cursor == nil and final.as_of == first.as_of
  end

  test "organisation DTO refuses unbounded or malformed assignments", %{scope: scope} do
    Process.put(:native_test_positions, [position(1)])

    {:ok, %{entries: [record]}} =
      NativePeopleAdapter.read(
        authorization(scope, %{capability: "organization_directory"}),
        request()
      )

    refute WorkforceRecord.valid?(%{record | assignments: List.duplicate(nil, 501)})
    refute WorkforceRecord.valid?(%{record | vacant: nil})
    refute WorkforceRecord.valid?(%{record | parent_stable_id: String.duplicate("x", 101)})
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

  test "a changes pass returns the same full snapshot", %{scope: scope} do
    employee!(scope, 73, "E-1")

    {:ok, boot} = NativePeopleAdapter.read(authorization(scope), request())

    {:ok, changes} =
      NativePeopleAdapter.read(
        authorization(scope),
        request(%{pass: :changes, since: boot.resume_cursor})
      )

    assert Enum.map(changes.entries, &{&1.kind, &1.stable_id}) ==
             Enum.map(boot.entries, &{&1.kind, &1.stable_id})

    assert boot.snapshot and changes.snapshot

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

    test "organisation projection keeps kind identity, holders and idempotency", context do
      employee = employee!(context.scope, 73, "E-1")
      alias Bilimbi.People.Workforce.Reference

      Process.put(:native_test_positions, [
        position(employee.id, %{
          assignments: [
            %{
              reference: %Reference{
                source_id: "people/native",
                type: :assignment,
                stable_id: "a-1"
              },
              employee_reference: %Reference{
                source_id: "people/native",
                type: :employee,
                stable_id: to_string(employee.id)
              },
              kind: "substantive"
            }
          ],
          vacant?: false
        })
      ])

      assert {:ok, %{state: :succeeded, applied: 3}} = sync(context, "org-boot")
      {:ok, %{value: records}} = Connector.workforce(context.scope, 73)
      projected = Enum.find(records, &(&1.kind == :position))
      assert projected.stable_id == to_string(employee.id)

      assert projected.assignments == [
               %Bilimbi.PeopleConnector.Connector.AssignmentRecord{
                 source_id: "people/native",
                 stable_id: "a-1",
                 employee_stable_id: to_string(employee.id),
                 kind: "substantive"
               }
             ]

      assert {:ok, %{unchanged: 3, applied: 0}} = sync(context, "org-again")
      Process.put(:native_test_positions, [])
      assert {:ok, %{deactivated: 1}} = sync(context, "org-removed")
      {:ok, %{value: remaining}} = Connector.workforce(context.scope, 73)
      refute Enum.any?(remaining, &(&1.kind == :position))
    end

    test "without a position reader the provider declares no organisation stream", context do
      Bilimbi.People.Workforce.unregister_position_reader(__MODULE__.PositionReader)
      {:ok, provider} = Registry.fetch(Providers.installed(), "people.native")
      refute Enum.any?(provider.capabilities, &(&1.key == "organization_directory"))
      employee!(context.scope, 73, "E-1")

      assert {:ok, %{state: :succeeded, applied: 2}} =
               sync(%{context | provider: provider}, "no-reader")

      refute_received {:positions_read, _, _}
      {:ok, %{value: records}} = Connector.workforce(context.scope, 73)
      refute Enum.any?(records, &(&1.kind == :position))
      {:ok, summary} = Connector.sync_summary(context.scope, 73)
      assert summary.open_issues == []
    end

    test "positions kept after the organisation stream is withdrawn open an issue", context do
      Process.put(:native_test_positions, [position(9)])
      assert {:ok, %{state: :succeeded}} = sync(context, "with-reader")
      Bilimbi.People.Workforce.unregister_position_reader(__MODULE__.PositionReader)
      {:ok, provider} = Registry.fetch(Providers.installed(), "people.native")

      assert {:ok, %{state: :succeeded, deactivated: 0}} =
               sync(%{context | provider: provider}, "withdrawn", full: true)

      {:ok, %{value: records}} = Connector.workforce(context.scope, 73)
      assert Enum.any?(records, &(&1.kind == :position and &1.stable_id == "9"))
      {:ok, summary} = Connector.sync_summary(context.scope, 73)

      assert [{"organisation_unavailable", "provider_unavailable"}] =
               Enum.map(summary.open_issues, &{&1.kind, &1.reason})
    end

    test "a malformed position is refused alone and the pass still applies", context do
      employee!(context.scope, 73, "E-1")

      Process.put(:native_test_positions, [
        position(1),
        position(2, %{title: String.duplicate("x", 256)})
      ])

      assert {:ok, %{state: :succeeded, applied: 3, refused: 1}} = sync(context, "bad-position")
      {:ok, %{value: records}} = Connector.workforce(context.scope, 73)
      assert [%{stable_id: "1"}] = Enum.filter(records, &(&1.kind == :position))
      {:ok, summary} = Connector.sync_summary(context.scope, 73)

      assert [{"record_refused", "invalid_record", "position", "2"}] =
               Enum.map(summary.open_issues, &{&1.kind, &1.reason, &1.record_kind, &1.stable_id})
    end

    test "a missing organisation reader keeps the directory in sync and opens an issue",
         context do
      Process.put(:native_test_positions, [position(9)])
      assert {:ok, %{state: :succeeded}} = sync(context, "before-missing")
      Bilimbi.People.Workforce.unregister_position_reader(__MODULE__.PositionReader)
      employee!(context.scope, 73, "E-2")

      assert {:ok, %{state: :succeeded, applied: 1, deactivated: 0}} =
               sync(context, "missing", full: true)

      {:ok, %{value: records}} = Connector.workforce(context.scope, 73)
      assert Enum.map(records, & &1.kind) |> Enum.sort() == [:company, :employee, :position]
      {:ok, summary} = Connector.sync_summary(context.scope, 73)

      assert [{"organisation_unavailable", "provider_unavailable"}] =
               Enum.map(summary.open_issues, &{&1.kind, &1.reason})

      Bilimbi.People.Workforce.register_position_reader(__MODULE__.PositionReader)
      assert {:ok, %{state: :succeeded}} = sync(context, "restored")
      {:ok, summary} = Connector.sync_summary(context.scope, 73)
      assert summary.open_issues == []
    end

    test "a multi-page organisation pass never deactivates absent positions", context do
      {:ok, _} = Sync.put_policy(context.scope, 73, %{page_limit: 2})
      Process.put(:native_test_positions, Enum.map(1..3, &position/1))
      assert {:ok, %{state: :succeeded, applied: 4}} = sync(context, "org-paged")

      Process.put(:native_test_positions, Enum.map(2..3, &position/1))
      assert {:ok, %{state: :succeeded, deactivated: 0}} = sync(context, "org-paged-gap")

      Process.put(:native_test_positions, [position(2)])
      assert {:ok, %{state: :succeeded, deactivated: 2}} = sync(context, "org-single")
      {:ok, %{value: records}} = Connector.workforce(context.scope, 73)
      assert [%{stable_id: "2"}] = Enum.filter(records, &(&1.kind == :position))
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

    test "a default sync deactivates a leaver and paging across small limits works", context do
      %{scope: scope} = context
      keep = employee!(scope, 73, "E-1")
      leaver = employee!(scope, 73, "E-2")
      employee!(scope, 73, "E-3")

      {:ok, _} = Sync.put_policy(scope, 73, %{page_limit: 2})
      assert {:ok, %{state: :succeeded, applied: 4}} = sync(context, "boot")

      {:ok, _} = Employee.update_employee(scope, 73, leaver.id, %{status: "terminated"})
      assert {:ok, incremental} = sync(context, "inc")

      assert {incremental.state, incremental.pass, incremental.deactivated} ==
               {:succeeded, :incremental, 1}

      {:ok, %ReadResult{value: records}} = Connector.workforce(scope, 73)
      ids = records |> Enum.filter(&(&1.kind == :employee)) |> Enum.map(& &1.stable_id)
      assert Integer.to_string(keep.id) in ids
      refute Integer.to_string(leaver.id) in ids
    end
  end
end
