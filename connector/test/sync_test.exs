defmodule Bilimbi.PeopleConnector.Connector.SyncTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Settings.ContributionValidator
  alias Bilimbi.Base.Settings.TestFixtures, as: SettingsFixtures
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.People.Workforce.ReadResult
  alias Bilimbi.PeopleConnector.Connector
  alias Bilimbi.PeopleConnector.Connector.Capability
  alias Bilimbi.PeopleConnector.Connector.Contributions
  alias Bilimbi.PeopleConnector.Connector.Deactivation
  alias Bilimbi.PeopleConnector.Connector.Page
  alias Bilimbi.PeopleConnector.Connector.PortAuthorization
  alias Bilimbi.PeopleConnector.Connector.PortRequest
  alias Bilimbi.PeopleConnector.Connector.Provider
  alias Bilimbi.PeopleConnector.Connector.Providers
  alias Bilimbi.PeopleConnector.Connector.Sync
  alias Bilimbi.PeopleConnector.Connector.SyncRun
  alias Bilimbi.PeopleConnector.Connector.TestAdapter
  alias Bilimbi.PeopleConnector.Connector.TestFixtures, as: ConnectorFixtures
  alias Bilimbi.PeopleConnector.Connector.WorkforceRecord
  alias Ecto.Adapters.SQL

  @source "people/native"
  @t0 ~U[2026-09-30 08:00:00Z]

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
      graph_fingerprint: "people-connector-sync-test",
      consumers: %{settings: settings}
    })

    on_exit(&ContributionRegistry.clear_for_test!/0)

    CompanyFixtures.create_company_identity_tables!()
    SettingsFixtures.create_settings_table!()
    ConnectorFixtures.create_connection_tables!()
    CompanyFixtures.insert_tenant!(%{id: 41})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, code: "one", name: "Company A"})

    ConnectorFixtures.insert_connection!(%{
      tenant_id: 41,
      platform_company_id: 73,
      workforce_company_id: 73,
      enabled: true
    })

    {:ok, scope} = Tenancy.scope(41)
    {:ok, status} = Connector.status(scope, 73)
    [provider] = Bilimbi.PeopleConnector.Connector.Registry.providers(Providers.installed())
    %{scope: scope, status: status, provider: provider}
  end

  defp employee(id, attrs \\ %{}) do
    struct!(
      %WorkforceRecord{
        kind: :employee,
        source_id: @source,
        stable_id: Integer.to_string(id),
        workforce_company_id: 73,
        name: "Employee #{id}",
        code: "E#{id}",
        observed_at: @t0
      },
      attrs
    )
  end

  defp company(attrs \\ %{}) do
    struct!(
      %WorkforceRecord{
        kind: :company,
        source_id: @source,
        stable_id: "73",
        workforce_company_id: 73,
        name: "Company A",
        code: "one",
        observed_at: @t0
      },
      attrs
    )
  end

  defp page(entries, attrs \\ %{}),
    do: struct!(%Page{entries: entries, as_of: @t0, resume_cursor: "r1"}, attrs)

  defp serve_pages(pages_by_cursor) do
    TestAdapter.serve(fn %PortRequest{cursor: cursor} ->
      {:ok, Map.fetch!(pages_by_cursor, cursor)}
    end)
  end

  defp sync(context, key, opts \\ []),
    do: Sync.run(context.scope, context.status, context.provider, TestAdapter, key, opts)

  defp records(scope) do
    {:ok, %ReadResult{value: records}} = Connector.workforce(scope, 73)
    records
  end

  defp issues(scope) do
    {:ok, summary} = Connector.sync_summary(scope, 73)
    Enum.map(summary.open_issues, &{&1.kind, &1.reason})
  end

  test "a bootstrap reads every page, projects both kinds and moves the checkpoint once",
       context do
    serve_pages(%{
      nil =>
        page([company(), employee(1)], %{next_cursor: "p2", as_of: ~U[2026-09-30 08:05:00Z]}),
      "p2" => page([employee(2, %{supervisor_stable_id: "1"})], %{resume_cursor: "r-boot"})
    })

    assert {:ok, %SyncRun{} = run} = sync(context, "first")
    assert run.state == :succeeded
    assert run.pass == :bootstrap
    assert run.applied == 3
    assert run.checkpoint_version == 1
    # The oldest page watermark is the one freshness is judged on.
    assert run.as_of_at == ~U[2026-09-30 08:00:00.000000Z]

    assert_received {:port_read, %PortAuthorization{} = auth, %PortRequest{pass: :bootstrap}}
    assert auth.platform_company_id == 73
    assert auth.workforce_company_id == 73
    assert auth.capability == "employee_directory"
    assert_received {:port_read, _auth, %PortRequest{pass: :bootstrap, cursor: "p2"}}

    assert [%{kind: :company}, %{stable_id: "1"}, %{stable_id: "2", supervisor_stable_id: "1"}] =
             records(context.scope)

    # A repeated key returns the recorded run and does not read the provider.
    assert {:ok, %SyncRun{id: id, state: :succeeded}} = sync(context, "first")
    assert id == run.id
    refute_received {:port_read, _, _}

    serve_pages(%{nil => page([employee(1)], %{resume_cursor: "r2"})})
    assert {:ok, next} = sync(context, "second")
    assert next.pass == :incremental
    assert next.unchanged == 1
    assert next.checkpoint_version == 2
    assert_received {:port_read, _, %PortRequest{pass: :changes, since: "r-boot"}}
  end

  test "older observations and deactivations never erase newer facts or history", context do
    serve_pages(%{
      nil => page([employee(1, %{observed_at: ~U[2026-09-30 09:00:00Z]}), employee(2)])
    })

    assert {:ok, %{state: :succeeded}} = sync(context, "boot")

    serve_pages(%{
      nil =>
        page([
          employee(1, %{name: "Older name", observed_at: @t0}),
          %Deactivation{kind: :employee, source_id: @source, stable_id: "2", observed_at: @t0},
          %Deactivation{kind: :employee, source_id: @source, stable_id: "9", observed_at: @t0}
        ])
    })

    assert {:ok, run} = sync(context, "changes")
    assert {run.superseded, run.deactivated, run.refused} == {1, 1, 1}
    assert [%{stable_id: "1", name: "Employee 1"}] = records(context.scope)
    assert {"record_refused", "unknown_reference"} in issues(context.scope)

    # The deactivated row is kept, not deleted.
    assert %{rows: [[2]]} =
             SQL.query!(Repo, "SELECT count(*) FROM people_connector_workforce_records", [])

    serve_pages(%{nil => page([employee(2, %{observed_at: ~U[2026-09-30 10:00:00Z]})])})
    assert {:ok, %{applied: 1}} = sync(context, "rehire")
    assert Enum.map(records(context.scope), & &1.stable_id) == ["1", "2"]

    # Core Company, the People side, is untouched by what the provider sent.
    assert %{rows: [["Company A"]]} =
             SQL.query!(Repo, "SELECT name FROM companies WHERE id = 73", [])
  end

  test "records from another source, company or undeclared capability become issues",
       context do
    {:ok, read} = Capability.new("employee_directory", :read)
    {:ok, employees_only} = Provider.new("people.native", "Native", "1.0.0", [read])
    context = %{context | provider: employees_only}

    serve_pages(%{
      nil =>
        page([
          employee(1, %{source_id: "elsewhere"}),
          employee(2, %{workforce_company_id: 74}),
          company(),
          employee(3, %{name: "  "}),
          :not_a_record
        ])
    })

    assert {:ok, run} = sync(context, "refused")
    assert run.state == :refused
    assert run.reason == "every_record_refused"
    assert run.refused == 5
    assert run.checkpoint_version == nil

    assert Enum.sort(issues(context.scope)) == [
             {"feed_refused", "every_record_refused"},
             {"record_refused", "foreign_source"},
             {"record_refused", "invalid_record"},
             {"record_refused", "invalid_record"},
             {"record_refused", "other_company"},
             {"record_refused", "undeclared_capability"}
           ]

    assert {:ok, %ReadResult{freshness: {:unavailable, :never_synchronised}}} =
             Connector.workforce(context.scope, 73)

    # A later pass that applies the record clears its issue and the feed issue.
    serve_pages(%{nil => page([employee(2)])})
    assert {:ok, %{state: :succeeded, checkpoint_version: 1}} = sync(context, "fixed")

    assert Enum.sort(issues(context.scope)) == [
             {"record_refused", "foreign_source"},
             {"record_refused", "invalid_record"},
             {"record_refused", "invalid_record"},
             {"record_refused", "undeclared_capability"}
           ]
  end

  test "stale, unavailable and broken provider pages apply nothing", context do
    cases = [
      {fn _ -> {:ok, page([employee(1)], %{freshness: {:stale, @t0}})} end, :stale,
       "provider_stale"},
      {fn _ -> {:ok, page([employee(1)], %{freshness: {:unavailable, :offline}})} end,
       :unavailable, "provider_unavailable"},
      {fn _ -> {:error, "provider said something secret"} end, :failed, "adapter_error"},
      {fn _ -> raise "boom" end, :failed, "adapter_error"},
      {fn _ -> {:ok, page([employee(1)], %{next_cursor: "again"})} end, :failed,
       "cursor_repeated"},
      {fn _ -> {:ok, page(Enum.map(1..3, &employee/1))} end, :failed, "invalid_page"},
      {fn _ ->
         {:ok,
          page([
            %Deactivation{kind: :employee, source_id: @source, stable_id: "1", observed_at: @t0}
          ])}
       end, :failed, "invalid_page"}
    ]

    {:ok, _policy} = Sync.put_policy(context.scope, 73, %{page_limit: 2})

    for {{fun, state, reason}, index} <- Enum.with_index(cases) do
      TestAdapter.serve(fn
        %PortRequest{cursor: "again"} -> {:ok, page([], %{next_cursor: "again"})}
        request -> fun.(request)
      end)

      assert {:ok, run} = sync(context, "case-#{index}")
      assert {run.state, run.reason} == {state, reason}
      refute inspect(run) =~ "secret"
    end

    assert %{rows: [[0]]} =
             SQL.query!(Repo, "SELECT count(*) FROM people_connector_workforce_records", [])

    assert %{rows: [[0]]} =
             SQL.query!(Repo, "SELECT count(*) FROM people_connector_sync_checkpoints", [])
  end

  test "a pass without an outcome becomes unknown and its late result is discarded", context do
    parent = self()

    serve_pages(%{nil => page([employee(1)])})

    slow =
      Task.async(fn ->
        TestAdapter.serve(fn _request ->
          send(parent, :reading)

          receive do
            :continue -> {:ok, page([employee(2)])}
          end
        end)

        sync(context, "slow")
      end)

    assert_receive :reading
    assert {:error, :sync_in_progress} = sync(context, "impatient")

    ConnectorFixtures.age_run!("slow", 31)
    assert {:ok, %{state: :succeeded}} = sync(context, "after")
    assert {"unknown_outcome", "no_outcome_recorded"} in issues(context.scope)

    send(slow.pid, :continue)
    assert {:ok, %SyncRun{state: :unknown, reason: "no_outcome_recorded"}} = Task.await(slow)
    assert Enum.map(records(context.scope), & &1.stable_id) == ["1"]
  end

  test "a full read deactivates records the provider no longer lists", context do
    serve_pages(%{nil => page([employee(1), employee(2)])})
    assert {:ok, %{checkpoint_version: 1}} = sync(context, "boot")

    serve_pages(%{nil => page([employee(1)], %{as_of: ~U[2026-09-30 09:00:00Z]})})
    assert {:ok, run} = sync(context, "full", full: true)

    assert {run.pass, run.unchanged, run.deactivated, run.checkpoint_version} ==
             {:bootstrap, 1, 1, 2}

    assert Enum.map(records(context.scope), & &1.stable_id) == ["1"]

    serve_pages(%{nil => page([])})
    assert {:ok, %{state: :succeeded, deactivated: 1}} = sync(context, "empty", full: true)
    assert {"empty_bootstrap", "no_records"} in issues(context.scope)
  end

  test "a full read whose records are all refused deactivates nothing", context do
    serve_pages(%{nil => page([employee(1), employee(2)])})
    assert {:ok, %{checkpoint_version: 1}} = sync(context, "boot")

    serve_pages(%{
      nil =>
        page([employee(1, %{source_id: "elsewhere"}), employee(2, %{name: " "})], %{
          as_of: ~U[2026-09-30 09:00:00Z]
        })
    })

    assert {:ok, run} = sync(context, "refused", full: true)
    assert {run.state, run.reason, run.deactivated} == {:refused, "every_record_refused", 0}
    assert run.checkpoint_version == nil
    assert Enum.map(records(context.scope), & &1.stable_id) == ["1", "2"]
    assert {"feed_refused", "every_record_refused"} in issues(context.scope)
    assert {:ok, %{checkpoint_version: 1}} = Connector.sync_summary(context.scope, 73)
  end

  test "a listed record refused as invalid is not deactivated as absent", context do
    serve_pages(%{nil => page([employee(1), employee(2)])})
    assert {:ok, %{checkpoint_version: 1}} = sync(context, "boot")

    serve_pages(%{
      nil => page([employee(1), employee(2, %{name: " "})], %{as_of: ~U[2026-09-30 09:00:00Z]})
    })

    assert {:ok, run} = sync(context, "full", full: true)
    assert {run.state, run.unchanged, run.refused, run.deactivated} == {:succeeded, 1, 1, 0}
    assert Enum.map(records(context.scope), & &1.stable_id) == ["1", "2"]

    {:ok, summary} = Connector.sync_summary(context.scope, 73)

    assert [%{reason: "invalid_record", record_kind: "employee", stable_id: "2"}] =
             summary.open_issues
  end

  test "a record a full read omitted comes back when it is listed again", context do
    serve_pages(%{nil => page([employee(1), employee(2)])})
    assert {:ok, %{checkpoint_version: 1}} = sync(context, "boot")

    serve_pages(%{nil => page([employee(1)], %{as_of: ~U[2026-09-30 09:00:00Z]})})
    assert {:ok, %{deactivated: 1}} = sync(context, "omit", full: true)
    assert Enum.map(records(context.scope), & &1.stable_id) == ["1"]

    serve_pages(%{nil => page([employee(1), employee(2)], %{as_of: ~U[2026-09-30 10:00:00Z]})})
    assert {:ok, run} = sync(context, "relist", full: true)
    assert {run.state, run.applied, run.unchanged, run.superseded} == {:succeeded, 1, 1, 0}
    assert Enum.map(records(context.scope), & &1.stable_id) == ["1", "2"]
  end

  test "freshness follows the company's maximum age and policy bounds are enforced", context do
    assert {:ok, %ReadResult{freshness: {:unavailable, :never_synchronised}}} =
             Connector.workforce(context.scope, 73)

    serve_pages(%{nil => page([employee(1)], %{as_of: DateTime.utc_now()})})
    assert {:ok, %{state: :succeeded}} = sync(context, "boot")
    assert {:ok, %ReadResult{freshness: :current}} = Connector.workforce(context.scope, 73)

    ConnectorFixtures.age_checkpoint!(1441)

    assert {:ok, %ReadResult{freshness: {:stale, _as_of}, value: [_record]}} =
             Connector.workforce(context.scope, 73)

    assert {:ok, %{max_age_minutes: 2880}} =
             Sync.put_policy(context.scope, 73, %{max_age_minutes: 2880})

    assert {:ok, %ReadResult{freshness: :current}} = Connector.workforce(context.scope, 73)

    for invalid <- [%{page_limit: 0}, %{max_age_minutes: 1}, %{run_timeout_minutes: "5"}] do
      assert {:error, {:invalid_policy, _field}} = Sync.put_policy(context.scope, 73, invalid)
    end

    assert %{page_limit: 250, run_timeout_minutes: 30} = Sync.policy(context.scope, 73)
  end

  test "reads and synchronisation refuse system work and a disabled connection", context do
    assert {:error, :unauthorized} =
             Connector.synchronise(
               context.scope,
               73,
               Providers.installed(),
               %{"people.native" => TestAdapter},
               "key"
             )

    assert {:error, :unauthorized} = Connector.resolve_issue(context.scope, 73, 1)
    assert {:error, :unauthorized} = Connector.put_sync_policy(context.scope, 73, %{})

    assert {:ok, %{freshness: {:unavailable, :never_synchronised}}} =
             Connector.sync_summary(context.scope, 73)
  end

  test "synchronised records are refused where People Workforce refuses the company",
       context do
    serve_pages(%{nil => page([employee(1)])})
    assert {:ok, %{state: :succeeded}} = sync(context, "boot")

    CompanyFixtures.insert_tenant!(%{id: 42, is_platform_operator: false})
    {:ok, other_scope} = Tenancy.scope(42)

    assert {:error, :not_found} = Connector.workforce(other_scope, 73)
    assert {:error, :not_found} = Connector.sync_summary(other_scope, 73)

    SQL.query!(Repo, "UPDATE companies SET status = 'suspended' WHERE id = 73", [])

    assert {:error, :not_found} = Connector.workforce(context.scope, 73)
    assert {:error, :not_found} = Connector.sync_summary(context.scope, 73)
  end
end
