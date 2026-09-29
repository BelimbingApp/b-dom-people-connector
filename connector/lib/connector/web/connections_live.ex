defmodule Bilimbi.PeopleConnector.Connector.Web.ConnectionsLive do
  @moduledoc """
  Company-scoped connection setup. Viewing needs
  `people-connector.connections.view`; every control also needs
  `people-connector.connections.manage` with reach to the selected company,
  which the Connector facade checks again on each write.
  """

  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Core.Company
  alias Bilimbi.PeopleConnector.Connector
  alias Bilimbi.PeopleConnector.Connector.Providers
  alias Bilimbi.PeopleConnector.Connector.Registry

  @view_capability "people-connector.connections.view"
  @credential_mask "••••••••"
  @write_events ~w(configure set_enabled save_credential request_remove remove)

  @impl true
  def mount(_params, _session, socket) do
    companies =
      case Company.list_selectable_companies(socket.assigns.current_scope.actor, @view_capability) do
        {:ok, companies} -> Enum.filter(companies, &(&1.status == "active"))
        {:error, :unauthorized} -> []
      end

    registry = Providers.installed()

    {:ok,
     socket
     |> assign(:page_title, "People connections")
     |> assign(:active_nav, nil)
     |> assign(:companies, companies)
     |> assign(:registry, registry)
     |> assign(:providers, Registry.providers(registry))
     |> assign(:credential_mask, @credential_mask)
     |> assign(:pending_remove, false)}
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

  def handle_event(event, _params, %{assigns: %{can_manage?: false}} = socket)
      when event in @write_events do
    {:noreply,
     socket
     |> assign(:pending_remove, false)
     |> put_flash(:error, refusal_message(:unauthorized))}
  end

  def handle_event("configure", %{"provider_id" => provider_id}, socket) do
    socket.assigns.current_scope.scope
    |> Connector.configure_connection(
      socket.assigns.company.id,
      socket.assigns.registry,
      provider_id
    )
    |> after_write(socket, "Connection saved. It stays disabled until you enable it.")
  end

  def handle_event("set_enabled", %{"enabled" => enabled}, socket) do
    enabled = enabled == "true"

    socket.assigns.current_scope.scope
    |> Connector.set_enabled(socket.assigns.company.id, socket.assigns.registry, enabled)
    |> after_write(socket, if(enabled, do: "Connection enabled.", else: "Connection disabled."))
  end

  def handle_event("save_credential", %{"credential" => %{"secret" => secret}}, socket) do
    scope = socket.assigns.current_scope.scope
    company_id = socket.assigns.company.id
    registry = socket.assigns.registry

    cond do
      secret == @credential_mask and socket.assigns.connection_status.credential_stored? ->
        {:noreply, put_flash(socket, :info, "The stored credential was kept.")}

      secret == "" ->
        scope
        |> Connector.clear_credential(company_id, registry)
        |> after_write(socket, "Credential cleared.")

      true ->
        scope
        |> Connector.put_credential(company_id, registry, secret)
        |> after_write(socket, "Credential saved.")
    end
  end

  def handle_event("request_remove", _params, socket),
    do: {:noreply, assign(socket, :pending_remove, true)}

  def handle_event("cancel_remove", _params, socket),
    do: {:noreply, assign(socket, :pending_remove, false)}

  def handle_event("remove", _params, socket) do
    socket = assign(socket, :pending_remove, false)

    socket.assigns.current_scope.scope
    |> Connector.remove_connection(socket.assigns.company.id)
    |> after_write(socket, "Connection removed.")
  end

  defp after_write({:ok, _status}, socket, success), do: after_write(:ok, socket, success)

  defp after_write(:ok, socket, success) do
    {:noreply,
     socket
     |> select_company(Integer.to_string(socket.assigns.company.id))
     |> put_flash(:success, success)}
  end

  defp after_write({:error, reason}, socket, _success) do
    {:noreply,
     socket
     |> select_company(Integer.to_string(socket.assigns.company.id))
     |> put_flash(:error, refusal_message(reason))}
  end

  defp select_company(%{assigns: %{companies: []}} = socket, _company_id),
    do:
      assign(socket,
        company: nil,
        connection_status: nil,
        workforce_notice: nil,
        remap?: false,
        can_manage?: false,
        provider: nil
      )

  defp select_company(%{assigns: %{companies: [first | _] = companies}} = socket, company_id) do
    company = Enum.find(companies, first, &(Integer.to_string(&1.id) == company_id))
    socket = assign(socket, company: company, can_manage?: can_manage?(socket, company))

    case Connector.status(socket.assigns.current_scope.scope, company.id) do
      {:ok, status} ->
        assign(socket,
          connection_status: status,
          workforce_notice: nil,
          remap?: false,
          provider: provider(socket.assigns.registry, status.provider_id)
        )

      {:error, reason} ->
        assign(socket,
          connection_status: nil,
          workforce_notice: workforce_notice(reason),
          remap?: reason == :mapping_changed,
          provider: nil
        )
    end
  end

  defp can_manage?(socket, company) do
    match?(
      {:ok, _company},
      Company.authorize_company_target(
        socket.assigns.current_scope.actor,
        company.id,
        Connector.manage_capability()
      )
    )
  end

  defp provider(_registry, nil), do: nil

  defp provider(registry, provider_id) do
    case Registry.fetch(registry, provider_id) do
      {:ok, provider} -> provider
      {:error, :unsupported} -> nil
    end
  end

  defp workforce_notice({:not_current, {:stale, %DateTime{}}}),
    do: "Workforce identity is out of date. Connection information is unavailable."

  defp workforce_notice({:not_current, {:unavailable, _reason}}),
    do: "Workforce identity is unavailable. Connection information cannot be shown."

  defp workforce_notice(:mapping_changed),
    do:
      "This company now maps to a different workforce company. Choose the provider again to record the current mapping."

  defp workforce_notice(:not_found),
    do: "This company has no workforce identity. Choose another company."

  defp refusal_message(:unauthorized),
    do: "You cannot change connections for this company. Ask an administrator for access."

  defp refusal_message(:unsupported), do: "That provider is not installed. Choose another."
  defp refusal_message(:disconnected), do: "Choose a provider for this company first."

  defp refusal_message(:credential_missing),
    do: "Save the provider's credential before enabling the connection."

  defp refusal_message(:credential_not_required),
    do: "This provider does not use a credential."

  defp refusal_message(:invalid_credential),
    do: "Enter a credential of at most 4096 characters."

  defp refusal_message(:workforce_company_taken),
    do: "Another company is already connected to this workforce company."

  defp refusal_message(:mapping_changed),
    do: "The workforce mapping changed. Choose the provider again first."

  defp refusal_message(:conflict),
    do: "Someone else changed this connection. Review it and try again."

  defp refusal_message(_reason),
    do: "Workforce identity is unavailable for this company. Try again later."

  defp state_label(:disconnected), do: "Not connected"
  defp state_label(:disabled), do: "Disabled"
  defp state_label(:enabled), do: "Enabled"

  defp state_kind(:enabled), do: :success
  defp state_kind(_state), do: :neutral

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="people-connections-page" variant={:list}>
        <.header>
          People connections
          <:subtitle>Workforce connection for a company.</:subtitle>
        </.header>

        <div :if={@companies == []} class="mt-5 rounded-xl border border-line bg-surface px-4 py-8">
          <.empty_state
            id="people-connections-no-company"
            title="No active company is available."
            reason="Choose a company you can view to see its connection state."
          />
        </div>

        <form
          :if={@companies != []}
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

        <section
          :if={@connection_status}
          id="people-connections-status"
          class="mt-5 rounded-xl border border-line bg-surface p-5"
        >
          <.list id="people-connections-facts">
            <:item title="State" id="people-connections-state">
              <.badge kind={state_kind(@connection_status.state)}>
                {state_label(@connection_status.state)}
              </.badge>
            </:item>
            <:item title="Provider" id="people-connections-provider">
              {cond do
                @provider -> @provider.name
                @connection_status.provider_id -> "Not installed (#{@connection_status.provider_id})"
                true -> "None chosen"
              end}
            </:item>
            <:item title="Platform company" id="people-connections-platform-company">
              {@company.name}
            </:item>
            <:item title="Workforce company" id="people-connections-workforce-company">
              {@connection_status.workforce_source_id} · {@connection_status.workforce_company_id}
            </:item>
            <:item :if={@provider} title="Credential" id="people-connections-credential-state">
              {cond do
                @provider.credential == :none -> "Not required"
                @connection_status.credential_stored? -> "Stored"
                true -> "Missing"
              end}
            </:item>
          </.list>

          <.empty_state
            :if={@connection_status.state == :disconnected and not @can_manage?}
            id="people-connections-disconnected"
            title="No workforce connection is configured."
            reason="Ask someone who can manage People connections to choose a provider."
          />

          <.empty_state
            :if={@connection_status.state != :disconnected and not @can_manage?}
            id="people-connections-read-only"
            forbidden="change People connections for this company"
          />

          <div :if={@can_manage?} class="mt-5 space-y-5">
            <.provider_form providers={@providers} status={@connection_status} />

            <form
              :if={@provider && @provider.credential == :secret}
              id="people-connections-credential-form"
              phx-submit="save_credential"
            >
              <.secret_input
                id="people-connections-credential"
                name="credential[secret]"
                label="Provider credential"
                subject="credential"
                stored?={@connection_status.credential_stored?}
                mask={@credential_mask}
                maxlength="4096"
              />
              <.button id="people-connections-save-credential" type="submit">Save credential</.button>
            </form>

            <div :if={@connection_status.state != :disconnected} class="flex flex-wrap gap-3">
              <.button
                :if={@connection_status.state == :disabled}
                id="people-connections-enable"
                variant="primary"
                phx-click="set_enabled"
                phx-value-enabled="true"
              >
                Enable
              </.button>
              <.button
                :if={@connection_status.state == :enabled}
                id="people-connections-disable"
                phx-click="set_enabled"
                phx-value-enabled="false"
              >
                Disable
              </.button>
              <.button id="people-connections-remove" variant="danger" phx-click="request_remove">
                Remove connection
              </.button>
            </div>
          </div>
        </section>

        <.confirm_dialog
          :if={@pending_remove}
          id="people-connections-remove-confirm"
          consequence={"The workforce connection for #{@company.name} will be removed."}
          detail={
            if @connection_status && @connection_status.credential_stored?,
              do:
                "Its stored credential is deleted. People records are not changed. You can connect again later.",
              else: "People records are not changed. You can connect again later."
          }
          confirm="Remove"
          working="Removing…"
          on_confirm={JS.push("remove")}
          on_cancel={JS.push("cancel_remove")}
        />

        <div :if={@workforce_notice} class="mt-5 rounded-xl border border-line bg-surface px-4 py-8">
          <.empty_state
            id="people-connections-workforce-unavailable"
            title="Workforce information is unavailable."
            reason={@workforce_notice}
          />
          <div :if={@can_manage? and @remap?} class="mt-5">
            <.provider_form providers={@providers} status={nil} />
          </div>
        </div>
      </.page>
    </Layouts.app>
    """
  end

  attr(:providers, :list, required: true)
  attr(:status, :any, required: true)

  defp provider_form(assigns) do
    ~H"""
    <form
      id="people-connections-provider-form"
      phx-submit="configure"
      class="flex flex-wrap items-end gap-3"
    >
      <div>
        <label for="people-connections-provider-select" class="block text-sm font-medium text-ink-strong">
          Provider
        </label>
        <select
          id="people-connections-provider-select"
          name="provider_id"
          class="mt-2.5 rounded-md border border-line bg-surface px-3 py-1.5 text-sm text-ink"
        >
          <option
            :for={provider <- @providers}
            value={provider.id}
            selected={@status && provider.id == @status.provider_id}
          >
            {provider.name}
          </option>
        </select>
      </div>
      <.button id="people-connections-save-provider" type="submit">
        {if @status && @status.state != :disconnected, do: "Save provider", else: "Connect"}
      </.button>
    </form>
    """
  end
end
