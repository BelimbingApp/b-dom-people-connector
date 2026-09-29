defmodule Bilimbi.PeopleConnector.Connector.Web.ConnectionsLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures

  setup do
    UserFixtures.create_user_tables!()
    CompanyFixtures.insert_tenant!(%{id: 41})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, name: "Company A"})
    UserFixtures.insert_user!(%{id: 91, company_id: 73, name: "Operator"})
    :ok
  end

  test "authorized operator sees a disconnected state without activation controls", %{conn: conn} do
    grant_capabilities!("people-connector.connections.view")
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/integrations/people/connections")

    assert has_element?(view, "#people-connections-disconnected", "No workforce connection is configured.")
    refute has_element?(view, "#people-connections-page button")
  end

  test "the route refuses an actor without the view capability", %{conn: conn} do
    assert {:error, {_kind, _redirect}} =
             conn |> log_in_as() |> live(~p"/integrations/people/connections")
  end
end
