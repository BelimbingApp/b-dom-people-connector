defmodule Bilimbi.PeopleConnector.Connector.Web.SyncTest do
  @moduledoc """
  Synchronisation through the facade and the connections page with a signed-in
  actor, so Authz grants, Settings and Audit are real.
  """

  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Audit
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Authentication
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.People.Workforce.ReadResult
  alias Bilimbi.PeopleConnector.Connector
  alias Bilimbi.PeopleConnector.Connector.Capability
  alias Bilimbi.PeopleConnector.Connector.Page
  alias Bilimbi.PeopleConnector.Connector.Provider
  alias Bilimbi.PeopleConnector.Connector.Providers
  alias Bilimbi.PeopleConnector.Connector.Registry
  alias Bilimbi.PeopleConnector.Connector.TestAdapter
  alias Bilimbi.PeopleConnector.Connector.TestFixtures, as: ConnectorFixtures
  alias Bilimbi.PeopleConnector.Connector.WorkforceRecord
  alias Ecto.Adapters.SQL

  @path "/integrations/people/connections"
  @view "people-connector.connections.view"
  @manage "people-connector.connections.manage"

  setup do
    UserFixtures.create_user_tables!()
    ConnectorFixtures.create_connection_tables!()
    CompanyFixtures.insert_tenant!(%{id: 41})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, code: "one", name: "Company A"})
    UserFixtures.insert_user!(%{id: 91, company_id: 73, name: "Operator"})

    UserFixtures.insert_user!(%{
      id: 92,
      company_id: 73,
      name: "Viewer",
      email: "viewer@example.com"
    })

    {:ok, system} = Tenancy.scope(41)

    TestAdapter.serve(fn _request ->
      {:ok,
       %Page{
         entries: [
           %WorkforceRecord{
             kind: :employee,
             source_id: "people/native",
             stable_id: "1",
             workforce_company_id: 73,
             name: "Employee 1",
             code: "E1",
             observed_at: DateTime.utc_now()
           },
           %WorkforceRecord{
             kind: :employee,
             source_id: "elsewhere",
             stable_id: "2",
             workforce_company_id: 73,
             name: "Employee 2",
             code: "E2",
             observed_at: DateTime.utc_now()
           }
         ],
         as_of: DateTime.utc_now()
       }}
    end)

    %{
      operator: Authentication.sign_in(system, 91, 73),
      viewer: Authentication.sign_in(system, 92, 73),
      adapters: %{Providers.native_id() => TestAdapter}
    }
  end

  defp connect_native!(operator) do
    registry = Providers.installed()
    {:ok, _status} = Connector.configure_connection(operator, 73, registry, Providers.native_id())
    {:ok, _status} = Connector.set_enabled(operator, 73, registry, true)
    registry
  end

  defp count(table),
    do: SQL.query!(Repo, "SELECT count(*) FROM #{table}", []).rows |> hd() |> hd()

  test "a manager synchronises through an adapter; each write is audited", %{
    operator: operator,
    viewer: viewer,
    adapters: adapters
  } do
    grant_capabilities!(@manage)
    grant_capabilities!([@view], user_id: 92)
    registry = connect_native!(operator)

    assert {:error, :adapter_unavailable} =
             Connector.synchronise(operator, 73, registry, %{}, "no-adapter")

    assert {:error, :invalid_idempotency_key} =
             Connector.synchronise(operator, 73, registry, adapters, " bad key")

    assert {:error, :unauthorized} =
             Connector.synchronise(viewer, 73, registry, adapters, "viewer")

    assert {:ok, run} = Connector.synchronise(operator, 73, registry, adapters, "k1")
    assert {run.state, run.applied, run.refused} == {:succeeded, 1, 1}

    assert {:ok, %ReadResult{freshness: :current, value: [%{stable_id: "1"}]}} =
             Connector.workforce(viewer, 73)

    {:ok, %{open_issues: [issue]}} = Connector.sync_summary(viewer, 73)
    assert {issue.kind, issue.reason} == {"record_refused", "foreign_source"}
    assert {:error, :unauthorized} = Connector.resolve_issue(viewer, 73, issue.id)
    assert :ok = Connector.resolve_issue(operator, 73, issue.id)
    assert {:error, :not_found} = Connector.resolve_issue(operator, 73, issue.id)

    assert {:error, :unauthorized} =
             Connector.put_sync_policy(viewer, 73, %{max_age_minutes: 60})

    assert {:ok, %{max_age_minutes: 60}} =
             Connector.put_sync_policy(operator, 73, %{max_age_minutes: 60})

    {:ok, mutations} = Audit.list_mutations(operator)
    types = mutations |> Enum.map(&(&1.auditable_type |> String.split(".") |> List.last()))

    for type <- ["SyncRun", "Projection", "Checkpoint", "ReconciliationIssue"] do
      assert type in types
    end
  end

  test "changing provider forgets synchronised data; removal deletes it", %{
    operator: operator,
    adapters: adapters
  } do
    grant_capabilities!(@manage)
    registry = connect_native!(operator)
    assert {:ok, %{state: :succeeded}} = Connector.synchronise(operator, 73, registry, adapters, "k1")
    assert count("people_connector_workforce_records") == 1

    {:ok, read} = Capability.new("employee_directory", :read)
    {:ok, other} = Provider.new("other.test", "Other", "1.0.0", [read])
    {:ok, registry} = Registry.register(registry, other)

    assert {:ok, %{state: :disabled}} =
             Connector.configure_connection(operator, 73, registry, "other.test")

    assert count("people_connector_workforce_records") == 0
    assert count("people_connector_sync_checkpoints") == 0
    assert count("people_connector_sync_runs") == 1

    assert :ok = Connector.remove_connection(operator, 73)

    for table <- ~w(people_connector_sync_runs people_connector_reconciliation_issues) do
      assert count(table) == 0
    end
  end

  test "the page shows synchronisation state and refuses a provider without an adapter", %{
    conn: conn,
    operator: operator,
    adapters: adapters
  } do
    grant_capabilities!([@view, @manage])
    registry = connect_native!(operator)

    {:ok, view, _html} = conn |> log_in_as() |> live(@path)
    assert has_element?(view, "#people-connections-freshness", "Never synchronised")
    assert has_element?(view, "#people-connections-last-run", "None yet")

    view |> element("#people-connections-synchronise") |> render_click()
    assert has_element?(view, "#flash-group", "No adapter serves this provider yet")

    # A pass the engine records elsewhere appears with its issue.
    assert {:ok, _run} = Connector.synchronise(operator, 73, registry, adapters, "k1")
    {:ok, view, _html} = conn |> log_in_as() |> live(@path)
    assert has_element?(view, "#people-connections-freshness", "Current")
    assert has_element?(view, "#people-connections-last-run", "1 applied")
    assert has_element?(view, "#people-connections-issues", "different source")

    view |> element("#people-connections-issues button", "Mark resolved") |> render_click()
    assert has_element?(view, "#people-connections-issues-empty", "No open issues.")

    view
    |> form("#people-connections-policy-form", %{"policy" => %{"page_limit" => "5000"}})
    |> render_submit()

    assert has_element?(view, "#flash-group", "whole numbers within the ranges")

    view
    |> form("#people-connections-policy-form", %{"policy" => %{"page_limit" => "100"}})
    |> render_submit()

    assert has_element?(view, "#flash-group", "policy saved")
    assert has_element?(view, "#people-connections-policy-page_limit[value='100']")
  end

  test "a viewer sees synchronisation state without controls", %{
    conn: conn,
    operator: operator
  } do
    grant_capabilities!(@manage)
    connect_native!(operator)
    grant_capabilities!([@view], user_id: 92)

    {:ok, view, _html} = conn |> log_in_as(%{"user_id" => 92, "company_id" => 73}) |> live(@path)
    assert has_element?(view, "#people-connections-sync")
    refute has_element?(view, "#people-connections-synchronise")
    refute has_element?(view, "#people-connections-policy-form")

    render_hook(view, "synchronise", %{"key" => "forged"})
    assert has_element?(view, "#flash-group", "cannot change connections")
    assert count("people_connector_sync_runs") == 0
  end
end
