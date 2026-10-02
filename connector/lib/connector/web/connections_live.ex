defmodule Bilimbi.PeopleConnector.Connector.Web.ConnectionsLive do
  @moduledoc """
  Company-scoped connection setup and synchronisation. Viewing needs
  `people-connector.connections.view`; every control also needs
  `people-connector.connections.manage` with reach to the selected company,
  which the Connector facade checks again on each write.

  Each synchronise button carries an idempotency key minted for this page,
  so a repeated click returns the recorded run instead of starting another.
  """

  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Core.Company
  alias Bilimbi.PeopleConnector.Connector
  alias Bilimbi.PeopleConnector.Connector.Adapters
  alias Bilimbi.PeopleConnector.Connector.Providers
  alias Bilimbi.PeopleConnector.Connector.Registry
  alias Bilimbi.PeopleConnector.Connector.Sync

  @view_capability "people-connector.connections.view"
  @credential_mask "••••••••"
  @write_events ~w(configure set_enabled save_credential request_remove remove synchronise resolve_issue save_policy save_webhook)

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
     |> assign(:adapters, Adapters.installed())
     |> assign(:sync_key, new_sync_key())
     |> assign(:policy_fields, policy_fields())
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

  def handle_event("synchronise", %{"key" => key} = params, socket) do
    socket = assign(socket, :sync_key, new_sync_key())
    full? = Map.get(params, "full") == "true"

    socket.assigns.current_scope.scope
    |> Connector.synchronise(
      socket.assigns.company.id,
      socket.assigns.registry,
      socket.assigns.adapters,
      if(full?, do: key <> ":full", else: key),
      full: full?
    )
    |> case do
      {:ok, run} ->
        {:noreply,
         socket
         |> select_company(Integer.to_string(socket.assigns.company.id))
         |> put_flash(run_flash_kind(run.state), "Synchronisation: #{run_label(run.state)}.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> select_company(Integer.to_string(socket.assigns.company.id))
         |> put_flash(:error, sync_refusal_message(reason))}
    end
  end

  def handle_event("resolve_issue", %{"id" => id}, socket) do
    case Integer.parse(id) do
      {issue_id, ""} ->
        socket.assigns.current_scope.scope
        |> Connector.resolve_issue(socket.assigns.company.id, issue_id)
        |> after_write(socket, "Issue marked resolved.")

      _ ->
        after_write({:error, :not_found}, socket, nil)
    end
  end

  def handle_event("save_policy", %{"policy" => params}, socket) do
    case parse_policy(params) do
      {:ok, values} ->
        socket.assigns.current_scope.scope
        |> Connector.put_sync_policy(socket.assigns.company.id, values)
        |> after_write(socket, "Synchronisation policy saved.")

      {:error, _reason} = error ->
        after_write(error, socket, nil)
    end
  end

  def handle_event("save_webhook", %{"webhook" => params}, socket) do
    case Integer.parse(Map.get(params, "max_skew_seconds", "")) do
      {skew, ""} ->
        values = %{enabled: params["enabled"] == "true", max_skew_seconds: skew}
        # Phoenix filters password parameters from event logs; a field named
        # secret would expose a newly entered signing value in development.
        secret = Map.get(params, "password", @credential_mask)
        values = if secret == @credential_mask, do: values, else: Map.put(values, :secret, secret)

        socket.assigns.current_scope.scope
        |> Connector.put_webhook_settings(socket.assigns.company.id, values)
        |> after_write(socket, "Webhook settings saved.")

      _ ->
        after_write({:error, :invalid_webhook_settings}, socket, nil)
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
        provider: nil,
        webhook: nil,
        sync: nil
      )

  defp select_company(%{assigns: %{companies: [first | _] = companies}} = socket, company_id) do
    company = Enum.find(companies, first, &(Integer.to_string(&1.id) == company_id))
    socket = assign(socket, company: company, can_manage?: can_manage?(socket, company))

    webhook = webhook_summary(socket, company.id)
    socket = assign(socket, :webhook_form, webhook_form(webhook))

    case Connector.status(socket.assigns.current_scope.scope, company.id) do
      {:ok, status} ->
        assign(socket,
          connection_status: status,
          workforce_notice: nil,
          remap?: false,
          provider: provider(socket.assigns.registry, status.provider_id),
          webhook: webhook,
          sync: sync_summary(socket, company.id)
        )

      {:error, reason} ->
        assign(socket,
          connection_status: nil,
          workforce_notice: workforce_notice(reason),
          remap?: reason == :mapping_changed,
          provider: nil,
          webhook: nil,
          sync: nil
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

  defp sync_summary(socket, company_id) do
    case Connector.sync_summary(socket.assigns.current_scope.scope, company_id) do
      {:ok, summary} -> summary
      {:error, _reason} -> nil
    end
  end

  defp webhook_form(nil), do: nil

  defp webhook_form(summary) do
    to_form(
      %{
        "enabled" => to_string(summary.enabled),
        "max_skew_seconds" => summary.max_skew_seconds,
        "password" => if(summary.secret_stored?, do: @credential_mask, else: "")
      },
      as: :webhook
    )
  end

  defp webhook_summary(socket, company_id) do
    case Connector.webhook_summary(socket.assigns.current_scope.scope, company_id) do
      {:ok, summary} -> summary
      {:error, _reason} -> nil
    end
  end

  defp new_sync_key, do: "page-" <> Ecto.UUID.generate()

  defp policy_fields do
    labels = %{
      page_limit: {"Page size", "Most records the provider returns on one page."},
      max_age_minutes:
        {"Maximum age (minutes)", "After this long without a completed pass, records are stale."},
      run_timeout_minutes:
        {"Run timeout (minutes)", "A pass still running after this is recorded as unknown."}
    }

    for {field, {_key, min, max}} <- Sync.policy_fields() do
      {label, hint} = Map.fetch!(labels, field)
      %{field: field, name: Atom.to_string(field), label: label, hint: hint, min: min, max: max}
    end
  end

  defp parse_policy(params) when is_map(params) do
    Enum.reduce_while(Sync.policy_fields(), {:ok, %{}}, fn {field, _bounds}, {:ok, acc} ->
      case Map.get(params, Atom.to_string(field)) do
        nil ->
          {:cont, {:ok, acc}}

        value when is_binary(value) ->
          case Integer.parse(String.trim(value)) do
            {integer, ""} -> {:cont, {:ok, Map.put(acc, field, integer)}}
            _ -> {:halt, {:error, {:invalid_policy, field}}}
          end

        _ ->
          {:halt, {:error, {:invalid_policy, field}}}
      end
    end)
  end

  defp parse_policy(_params), do: {:error, {:invalid_policy, :values}}

  defp sync_refusal_message(:adapter_unavailable),
    do: "No adapter serves this provider yet, so it cannot be synchronised."

  defp sync_refusal_message(:disconnected), do: "Enable the connection before synchronising."

  defp sync_refusal_message(:sync_in_progress),
    do: "A synchronisation is already running for this company. Try again when it finishes."

  defp sync_refusal_message(reason), do: refusal_message(reason)

  defp run_flash_kind(:succeeded), do: :success
  defp run_flash_kind(_state), do: :error

  defp run_label(:running), do: "running"
  defp run_label(:succeeded), do: "succeeded"
  defp run_label(:stale), do: "provider data was stale; nothing applied"
  defp run_label(:unavailable), do: "provider unavailable; nothing applied"
  defp run_label(:refused), do: "refused; the checkpoint did not move"
  defp run_label(:failed), do: "failed; nothing applied"
  defp run_label(:unknown), do: "outcome unknown; nothing counts as applied"

  defp run_kind(:succeeded), do: :success
  defp run_kind(:running), do: :neutral
  defp run_kind(state) when state in [:stale, :unknown], do: :warning
  defp run_kind(_state), do: :danger

  defp freshness_label(:current), do: "Current"
  defp freshness_label({:stale, _as_of}), do: "Stale"
  defp freshness_label({:unavailable, :never_synchronised}), do: "Never synchronised"
  defp freshness_label({:unavailable, _reason}), do: "Not enabled"

  defp freshness_kind(:current), do: :success
  defp freshness_kind({:stale, _as_of}), do: :warning
  defp freshness_kind(_freshness), do: :neutral

  defp issue_message(%{kind: "record_refused", reason: "foreign_source"}),
    do: "A record came from a different source than this connection's."

  defp issue_message(%{kind: "record_refused", reason: "other_company"}),
    do: "A record belongs to a different workforce company."

  defp issue_message(%{kind: "record_refused", reason: "undeclared_capability"}),
    do: "The provider sent a kind of record it does not declare."

  defp issue_message(%{kind: "record_refused", reason: "invalid_record"}),
    do: "A record was incomplete or malformed."

  defp issue_message(%{kind: "record_refused", reason: "unknown_reference"}),
    do: "A deactivation named a record that was never synchronised."

  defp issue_message(%{kind: "feed_refused"}),
    do: "Every record in a pass was refused, so the checkpoint did not move."

  defp issue_message(%{kind: "empty_bootstrap"}), do: "A full read returned no records."

  defp issue_message(%{kind: "unknown_outcome"}),
    do: "A pass stopped without recording an outcome. Nothing from it was applied."

  defp issue_message(_issue), do: "The provider sent something that could not be applied."

  defp issue_subject(%{record_kind: nil}), do: "—"
  defp issue_subject(%{record_kind: kind, stable_id: nil}), do: kind
  defp issue_subject(%{record_kind: kind, stable_id: stable_id}), do: "#{kind} #{stable_id}"

  defp workforce_notice({:not_current, {:stale, %DateTime{}}}),
    do: "Workforce identity is out of date. Connection information is unavailable."

  defp workforce_notice({:not_current, {:unavailable, _reason}}),
    do: "Workforce identity is unavailable. Connection information cannot be shown."

  defp workforce_notice(:mapping_changed),
    do:
      "This company now maps to a different workforce company. Choose the provider again to record the current mapping."

  defp workforce_notice(:not_found),
    do: "This company has no workforce identity. Choose another company."

  defp refusal_message(:invalid_webhook_settings),
    do: "Enter a secret of 32–4096 bytes and an allowed clock difference of 1–86400 seconds."

  defp refusal_message(:webhook_secret_missing),
    do: "Store a webhook signing secret before enabling intake."

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

  defp refusal_message(:not_found),
    do: "That item is no longer available. Review the page and try again."

  defp refusal_message({:invalid_policy, _field}),
    do: "Enter whole numbers within the ranges shown."

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
            <.link navigate={~p"/integrations/people/files?company_id=#{@company.id}"} id="people-connections-files">File exchange</.link>
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

        <.sync_section
          :if={@sync && @connection_status && @connection_status.state != :disconnected}
          sync={@sync}
          webhook={@webhook}
          webhook_form={@webhook_form}
          can_manage?={@can_manage?}
          enabled?={@connection_status.state == :enabled}
          sync_key={@sync_key}
          policy_fields={@policy_fields}
        />

        <.confirm_dialog
          :if={@pending_remove}
          id="people-connections-remove-confirm"
          consequence={"The workforce connection for #{@company.name} will be removed."}
          detail={
            if @connection_status && @connection_status.credential_stored?,
              do:
                "Its stored credential, signing secret, synchronised records and notification history are deleted. People records are not changed. You can connect again later.",
              else:
                "Its synchronised records, signing secret and notification history are deleted. People records are not changed. You can connect again later."
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

  attr(:sync, :any, required: true)
  attr(:can_manage?, :boolean, required: true)
  attr(:enabled?, :boolean, required: true)
  attr(:sync_key, :string, required: true)
  attr(:policy_fields, :list, required: true)

  attr(:webhook, :any, required: true)
  attr(:webhook_form, :any, required: true)

  defp sync_section(assigns) do
    ~H"""
    <section id="people-connections-sync" class="mt-5 rounded-xl border border-line bg-surface p-5">
      <.section_heading title="Synchronisation">
        <:description>
          Directory records read from the provider into this connection. People records are never changed.
        </:description>
      </.section_heading>

      <.list id="people-connections-sync-facts">
        <:item title="Freshness" id="people-connections-freshness">
          <.badge kind={freshness_kind(@sync.freshness)}>{freshness_label(@sync.freshness)}</.badge>
        </:item>
        <:item title="Data as of" id="people-connections-as-of">
          <.datetime :if={@sync.as_of_at} id="people-connections-as-of-value" value={@sync.as_of_at} />
          <span :if={is_nil(@sync.as_of_at)}>No completed pass</span>
        </:item>
        <:item title="Last pass" id="people-connections-last-run">
          <span :if={is_nil(@sync.last_run)}>None yet</span>
          <span :if={@sync.last_run} class="flex flex-wrap items-center gap-2">
            <.badge kind={run_kind(@sync.last_run.state)}>{run_label(@sync.last_run.state)}</.badge>
            <span>
              {if @sync.last_run.pass == :bootstrap, do: "Full read", else: "Changes"} ·
              {@sync.last_run.applied} applied · {@sync.last_run.unchanged} unchanged ·
              {@sync.last_run.deactivated} deactivated · {@sync.last_run.refused} refused
            </span>
          </span>
        </:item>
      </.list>

      <div :if={@can_manage?} class="mt-5 flex flex-wrap gap-3">
        <.button
          id="people-connections-synchronise"
          variant="primary"
          disabled={not @enabled?}
          phx-click="synchronise"
          phx-value-key={@sync_key}
          phx-disable-with="Synchronising…"
        >
          Synchronise now
        </.button>
        <.button
          id="people-connections-full-read"
          disabled={not @enabled?}
          phx-click="synchronise"
          phx-value-key={@sync_key}
          phx-value-full="true"
          phx-disable-with="Reading…"
        >
          Full read
        </.button>
      </div>

      <div class="mt-5">
        <.section_heading
          id="people-connections-issues-heading"
          title="Open issues"
          count={length(@sync.open_issues)}
        />
        <.table
          id="people-connections-issues"
          rows={@sync.open_issues}
          row_id={&"people-connections-issue-#{&1.id}"}
          caption="Open reconciliation issues"
        >
          <:col :let={issue} label="Issue">
            <.badge kind={if issue.severity == :error, do: :danger, else: :warning}>
              {if issue.severity == :error, do: "Error", else: "Warning"}
            </.badge>
            {issue_message(issue)}
          </:col>
          <:col :let={issue} label="Record">{issue_subject(issue)}</:col>
          <:col :let={issue} label="Seen" align={:right}>{issue.occurrences}</:col>
          <:col :let={issue} label="Last seen">
            <.datetime id={"people-connections-issue-#{issue.id}-seen"} value={issue.last_seen_at} />
          </:col>
          <:action :let={issue}>
            <.button
              :if={@can_manage?}
              id={"people-connections-resolve-#{issue.id}"}
              phx-click="resolve_issue"
              phx-value-id={issue.id}
            >
              Mark resolved
            </.button>
          </:action>
          <:empty :if={@sync.open_issues == []}>No open issues.</:empty>
        </.table>
      </div>

      <section :if={@webhook} id="people-connections-webhook" class="my-5 border-t border-line pt-4">
        <.section_heading id="people-connections-webhook-heading" title="Inbound notifications" />
        <.list>
          <:item title="Intake">
            <span id="people-connections-webhook-state">{if @webhook.enabled and @enabled?, do: "Enabled", else: "Disabled"}</span>
          </:item>
          <:item title="Signing secret">
            <span id="people-connections-webhook-secret-state">{if @webhook.secret_stored?, do: "Stored", else: "Not stored"}</span>
          </:item>
          <:item title="Last directory-change notification">
            <.datetime :if={@webhook.last_received_at} id="people-connections-webhook-received" value={@webhook.last_received_at} />
            <span :if={is_nil(@webhook.last_received_at)}>None yet</span>
          </:item>
        </.list>
        <p class="my-3 text-sm text-muted">Notifications are recorded for review. Use Synchronise now to refresh the directory.</p>
        <.form :if={@can_manage?} for={@webhook_form} :let={f} id="people-connections-webhook-form" phx-submit="save_webhook">
          <.input field={f[:enabled]} type="select" label="Inbound intake" hint="Receiving notifications also requires an enabled workforce connection." options={[{"Disabled", "false"}, {"Enabled", "true"}]} />
          <.secret_input field={f[:password]} subject="webhook signing secret" label="Signing secret" reveal={false} />
          <.input field={f[:max_skew_seconds]} type="number" label="Allowed clock difference (seconds)" min="1" max="86400" required />
          <.button id="people-connections-webhook-save" type="submit" phx-disable-with="Saving…">Save webhook settings</.button>
        </.form>
      </section>

      <form
        :if={@can_manage?}
        id="people-connections-policy-form"
        phx-submit="save_policy"
        class="mt-5 grid gap-x-4 sm:grid-cols-3"
      >
        <.input
          :for={field <- @policy_fields}
          id={"people-connections-policy-#{field.name}"}
          name={"policy[#{field.name}]"}
          type="number"
          label={field.label}
          hint={field.hint}
          value={Map.fetch!(@sync.policy, field.field)}
          min={field.min}
          max={field.max}
          required
        />
        <div class="sm:col-span-3">
          <.button id="people-connections-save-policy" type="submit">Save policy</.button>
        </div>
      </form>
    </section>
    """
  end
end
