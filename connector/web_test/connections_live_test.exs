defmodule Bilimbi.PeopleConnector.Connector.Web.ConnectionsLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Audit
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.PeopleConnector.Connector.TestFixtures, as: ConnectorFixtures

  @path "/integrations/people/connections"

  setup do
    UserFixtures.create_user_tables!()
    ConnectorFixtures.create_connection_tables!()
    CompanyFixtures.insert_tenant!(%{id: 41})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, name: "Company A"})
    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, name: "Company B", code: "b"})
    UserFixtures.insert_user!(%{id: 91, company_id: 73, name: "Operator"})
    :ok
  end

  test "a viewer sees a disconnected state without controls and cannot reach a sibling", %{
    conn: conn
  } do
    grant_capabilities!("people-connector.connections.view")
    {:ok, view, _html} = conn |> log_in_as() |> live(@path)

    assert has_element?(view, "#people-connections-state", "Not connected")

    assert has_element?(
             view,
             "#people-connections-disconnected",
             "No workforce connection is configured."
           )

    refute has_element?(view, "#people-connections-page button")
    refute has_element?(view, "#people-connections-company option[value='74']")

    render_hook(view, "configure", %{"provider_id" => "people.native"})
    assert has_element?(view, "#flash-group", "cannot change connections")
    assert has_element?(view, "#people-connections-state", "Not connected")
  end

  test "a manager connects, enables and removes the native provider", %{conn: conn} do
    grant_capabilities!([
      "people-connector.connections.view",
      "people-connector.connections.manage"
    ])

    {:ok, view, _html} = conn |> log_in_as() |> live(@path)

    view |> form("#people-connections-provider-form") |> render_submit()

    assert has_element?(view, "#people-connections-state", "Disabled")
    assert has_element?(view, "#people-connections-provider", "People (this installation)")
    assert has_element?(view, "#people-connections-credential-state", "Not required")
    refute has_element?(view, "#people-connections-credential-form")

    view |> element("#people-connections-enable") |> render_click()
    assert has_element?(view, "#people-connections-state", "Enabled")

    view |> element("#people-connections-remove") |> render_click()
    assert has_element?(view, "#people-connections-remove-confirm")
    view |> element("#people-connections-remove-confirm button", "Remove") |> render_click()
    assert has_element?(view, "#people-connections-state", "Not connected")

    {:ok, scope} = Tenancy.scope(41)
    {:ok, mutations} = Audit.list_mutations(scope)

    connection_mutations =
      Enum.filter(mutations, &String.ends_with?(&1.auditable_type, "Connector.Connection"))

    assert Enum.map(connection_mutations, & &1.event) == ["created", "updated", "deleted"]
    assert Enum.all?(connection_mutations, &(&1.actor_type == "user" and &1.actor_id == 91))
  end

  test "a manager records the current mapping after Workforce remaps the company", %{conn: conn} do
    grant_capabilities!([
      "people-connector.connections.view",
      "people-connector.connections.manage"
    ])

    ConnectorFixtures.insert_connection!(%{
      tenant_id: 41,
      platform_company_id: 73,
      workforce_company_id: 999,
      enabled: true
    })

    {:ok, view, _html} = conn |> log_in_as() |> live(@path)

    assert has_element?(view, "#people-connections-workforce-unavailable", "different workforce")
    refute has_element?(view, "#people-connections-status")

    view |> form("#people-connections-provider-form") |> render_submit()

    assert has_element?(view, "#people-connections-state", "Disabled")
    assert has_element?(view, "#people-connections-workforce-company", "people/native · 73")
  end

  test "the route refuses an actor without the view capability", %{conn: conn} do
    assert {:error, {_kind, _redirect}} = conn |> log_in_as() |> live(@path)
  end
end
