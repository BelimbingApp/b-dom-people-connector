defmodule Bilimbi.PeopleConnector.Connector.Web.ConnectionsLive do
  @moduledoc "Company-scoped, fail-closed state before connection setup exists."

  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Core.Company
  alias Bilimbi.PeopleConnector.Connector

  @capability "people-connector.connections.view"

  @impl true
  def mount(_params, _session, socket) do
    companies =
      case Company.list_selectable_companies(socket.assigns.current_scope.actor, @capability) do
        {:ok, companies} -> Enum.filter(companies, &(&1.status == "active"))
        {:error, :unauthorized} -> []
      end

    {:ok,
     socket
     |> assign(:page_title, "People connections")
     |> assign(:active_nav, nil)
     |> assign(:companies, companies)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, select_company(socket, Map.get(params, "company_id"))}
  end

  @impl true
  def handle_event("select_company", %{"company_id" => company_id}, socket) do
    {:noreply,
     push_patch(socket, to: ~p"/integrations/people/connections?company_id=#{company_id}")}
  end

  defp select_company(%{assigns: %{companies: []}} = socket, _company_id),
    do: assign(socket, company: nil, connection_status: nil, freshness_notice: nil)

  defp select_company(%{assigns: %{companies: [first | _] = companies}} = socket, company_id) do
    company = Enum.find(companies, first, &(Integer.to_string(&1.id) == company_id))

    case Connector.status(socket.assigns.current_scope.scope, company.id) do
      {:ok, status} ->
        assign(socket, company: company, connection_status: status, freshness_notice: nil)

      {:error, {:not_current, freshness}} ->
        assign(socket,
          company: company,
          connection_status: nil,
          freshness_notice: freshness_notice(freshness)
        )

      {:error, :not_found} ->
        assign(socket, company: nil, connection_status: nil, freshness_notice: nil)
    end
  end

  defp freshness_notice({:stale, %DateTime{}}),
    do: "Workforce identity is out of date. Connection information is unavailable."

  defp freshness_notice({:unavailable, _reason}),
    do: "Workforce identity is unavailable. Connection information cannot be shown."

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="people-connections-page" variant={:list}>
        <.header>
          People connections
          <:subtitle>Workforce connection state for a company.</:subtitle>
        </.header>

        <div :if={@company == nil} class="mt-5 rounded-xl border border-line bg-surface px-4 py-8">
          <.empty_state
            id="people-connections-no-company"
            title="No active company is available."
            reason="Choose a company you can view to see its connection state."
          />
        </div>

        <form
          :if={@company}
          id="people-connections-company-form"
          phx-change="select_company"
          phx-submit="select_company"
          class="mt-5"
        >
          <label for="people-connections-company" class="block text-sm font-medium text-ink-strong">
            Company
          </label>
          <select
            id="people-connections-company"
            name="company_id"
            class="mt-2.5 w-full rounded-md border border-line bg-surface px-3 py-1.5 text-sm text-ink"
          >
            <option :for={company <- @companies} value={company.id} selected={company.id == @company.id}>
              {company.name}
            </option>
          </select>
        </form>

        <div :if={@connection_status} class="mt-5 rounded-xl border border-line bg-surface px-4 py-8">
          <.empty_state
            id="people-connections-disconnected"
            title="No workforce connection is configured."
            reason="Provider setup and synchronization are not available yet."
          />
        </div>

        <div :if={@freshness_notice} class="mt-5 rounded-xl border border-line bg-surface px-4 py-8">
          <.empty_state
            id="people-connections-workforce-unavailable"
            title="Workforce information is unavailable."
            reason={@freshness_notice}
          />
        </div>
      </.page>
    </Layouts.app>
    """
  end
end
