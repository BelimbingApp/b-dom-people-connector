defmodule Bilimbi.PeopleConnector.Connector.Web.BackupsLive do
  @moduledoc false
  use Bilimbi.Base.UI, :live_view
  alias Bilimbi.Base.UI.CommitStatus
  alias Bilimbi.Core.Company
  alias Bilimbi.PeopleConnector.Connector
  alias Bilimbi.PeopleConnector.Connector.Backup

  @fields %{"retention_days" => :retention_days, "preview_minutes" => :preview_minutes}
  @impl true
  def mount(_, _, socket) do
    companies =
      case Company.list_selectable_companies(
             socket.assigns.current_scope.actor,
             Connector.manage_capability()
           ) do
        {:ok, companies} -> Enum.filter(companies, &(&1.status == "active"))
        _ -> []
      end

    {:ok,
     socket
     |> assign(
       active_nav: nil,
       page_title: "People connection backups",
       companies: companies,
       company: nil,
       policy: nil,
       records: [],
       holds: [],
       preview: nil,
       confirming: false
     )
     |> CommitStatus.init()}
  end

  @impl true
  def handle_params(params, _, socket) do
    company =
      if Map.has_key?(params, "company_id"),
        do: Enum.find(socket.assigns.companies, &(to_string(&1.id) == params["company_id"])),
        else: List.first(socket.assigns.companies)

    {:noreply,
     socket
     |> assign(company: company, preview: nil, confirming: false)
     |> CommitStatus.init()
     |> refresh()}
  end

  @impl true
  def handle_event("select_company", %{"company_id" => id}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/integrations/people/backups?company_id=#{id}")}

  def handle_event(_, _, %{assigns: %{company: nil}} = socket),
    do: {:noreply, put_flash(socket, :error, "Select a company you may manage.")}

  def handle_event("save_policy", params, socket) do
    case CommitStatus.inline_field(params, @fields) do
      {:ok, name, field, value} ->
        result =
          with {number, ""} <- Integer.parse(value),
               do: Backup.configure(scope(socket), company(socket), %{field => number})

        case result do
          {:ok, policy} ->
            {:noreply, socket |> assign(policy: policy) |> CommitStatus.put(name, :saved)}

          _ ->
            {:noreply,
             CommitStatus.put(
               socket,
               name,
               {:error, "Enter a whole number within the stated range."}
             )}
        end

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("backup", _, socket),
    do: outcome(socket, Backup.create(scope(socket), company(socket)), "Backup stored privately.")

  def handle_event("preview", %{"id" => id}, socket) do
    case Backup.preview(scope(socket), company(socket), id) do
      {:ok, preview} ->
        {:noreply, socket |> clear_flash() |> assign(preview: preview, confirming: false)}

      {:error, reason} ->
        {:noreply,
         socket |> assign(preview: nil) |> clear_flash() |> put_flash(:error, message(reason))}
    end
  end

  def handle_event("request_restore", _, %{assigns: %{preview: preview}} = socket)
      when not is_nil(preview),
      do: {:noreply, socket |> clear_flash() |> assign(confirming: true)}

  def handle_event("cancel_restore", _, socket),
    do: {:noreply, assign(socket, :confirming, false)}

  def handle_event("restore", _, %{assigns: %{confirming: true, preview: preview}} = socket) do
    result = Backup.restore(scope(socket), company(socket), preview.id, preview.token, true)

    outcome(
      assign(socket, preview: nil, confirming: false),
      result,
      "Backup restored. Re-enter secrets on People connections before enabling webhook intake."
    )
  end

  def handle_event("recover", %{"id" => id}, socket) do
    case Backup.recover(scope(socket), company(socket), id) do
      {:ok, %{state: :succeeded}} = result ->
        outcome(socket, result, "Recovery synchronisation completed.")

      {:ok, _} ->
        {:noreply,
         socket
         |> clear_flash()
         |> put_flash(
           :error,
           "Recovery did not complete. Review connection health and sync outcomes."
         )}

      error ->
        outcome(socket, error, "")
    end
  end

  def handle_event("purge", _, socket),
    do:
      outcome(
        socket,
        Backup.purge_expired(scope(socket), company(socket)),
        "Expired backup cleanup completed."
      )

  def handle_event("retry_purge", %{"id" => id}, socket),
    do:
      outcome(
        socket,
        Backup.retry_purge(scope(socket), company(socket), id),
        "Held backup removed."
      )

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp outcome(socket, {:ok, %{errors: [_ | _]}}, _),
    do:
      {:noreply,
       socket
       |> refresh()
       |> clear_flash()
       |> put_flash(
         :error,
         "Some backups could not be removed. Review private storage settings and retry."
       )}

  defp outcome(socket, {:ok, _}, text),
    do: {:noreply, socket |> refresh() |> clear_flash() |> put_flash(:success, text)}

  defp outcome(socket, {:error, reason}, _),
    do: {:noreply, socket |> refresh() |> clear_flash() |> put_flash(:error, message(reason))}

  defp refresh(%{assigns: %{company: nil}} = socket),
    do: assign(socket, policy: nil, records: [], holds: [])

  defp refresh(socket) do
    case Backup.summary(scope(socket), company(socket)) do
      {:ok, summary} ->
        assign(socket, policy: summary.policy, records: summary.records, holds: summary.holds)

      _ ->
        assign(socket, policy: nil, records: [], holds: [])
    end
  end

  defp scope(socket), do: socket.assigns.current_scope.scope
  defp company(socket), do: socket.assigns.company.id
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page>
        <.header>People connection backups<:actions><.action_link id="people-backups-connections" icon="manage" title="People connections" navigate={~p"/integrations/people/connections"}>People connections</.action_link></:actions></.header>
        <.form :if={@companies != []} for={to_form(%{"company_id" => @company && to_string(@company.id)})} id="people-backups-company-form" phx-change="select_company" phx-submit="select_company">
          <.input type="select" name="company_id" id="people-backups-company" label="Company" value={@company && @company.id} options={Enum.map(@companies, &{&1.name, &1.id})} />
        </.form>
        <.empty_state :if={is_nil(@policy)} id="people-backups-unavailable" title="Backups unavailable" reason="Select an accessible active company with connection management permission." />
        <div :if={@policy} class="space-y-5 mt-5">
          <.card inner_class="p-5 sm:p-6">
            <.section_heading title="Backup policy" />
            <.list id="people-backups-policy">
              <:item :for={{field, {_, _, min, max}} <- Backup.fields()} title={label(field)}>
                <.inline_edit id={"people-backups-#{field}"} name={Atom.to_string(field)} label={label(field)} value={to_string(@policy[field])} id_value={@company.id} save_event="save_policy" status={@field_status[Atom.to_string(field)]} />
                <span class="text-sm text-muted">{min}–{max}</span>
              </:item>
            </.list>
            <p class="text-sm text-muted mt-3">Backups exclude secrets. Retention is capped by the installation's private artifact retention; configure storage in Operator Settings.</p>
          </.card>
          <.card inner_class="p-5 sm:p-6">
            <.section_heading title="Recent backups">
              <:actions><.button id="people-backups-create" phx-click="backup" phx-disable-with="Backing up…">Back up connection</.button></:actions>
            </.section_heading>
            <.table id="people-backups-history" rows={@records} framed={false} caption="Recent connection backups">
              <:col :let={row} label="Created"><.datetime id={"backup-#{row.id}-created"} value={row.inserted_at} /></:col>
              <:col :let={row} label="Expires"><.datetime id={"backup-#{row.id}-expires"} value={row.expires_at} /></:col>
              <:col :let={row} label="State">{if row.restored_at, do: "Restored", else: Atom.to_string(row.state)}</:col>
              <:action :let={row}>
                <.button :if={row.state == :ready && is_nil(row.restored_at)} id={"preview-#{row.id}"} phx-click="preview" phx-value-id={row.id}>Preview restore</.button>
                <.button :if={row.state == :ready && row.restored_at} id={"recover-#{row.id}"} phx-click="recover" phx-value-id={row.id} phx-disable-with="Recovering…">Sync from checkpoint</.button>
              </:action>
              <:empty :if={@records == []}>No backups created. Back up a configured native connection to begin.</:empty>
            </.table>
            <.button id="people-backups-purge" phx-click="purge" phx-disable-with="Cleaning…">Clean expired backups</.button>
          </.card>
          <.card :if={@holds != []} inner_class="p-5 sm:p-6">
            <.section_heading title="Held cleanup" />
            <.table id="people-backups-holds" rows={@holds} framed={false} caption="Expired backups whose cleanup is held">
              <:col :let={row} label="Created"><.datetime id={"backup-hold-#{row.id}-created"} value={row.inserted_at} /></:col>
              <:col :let={row} label="Attempts">{row.purge_attempts}</:col>
              <:col :let={row} label="Reason">{row.purge_last_error}</:col>
              <:col :let={row} label="Held"><.datetime id={"backup-hold-#{row.id}-held"} value={row.purge_held_at} /></:col>
              <:action :let={row}>
                <.button id={"retry-purge-#{row.id}"} phx-click="retry_purge" phx-value-id={row.id} phx-disable-with="Retrying…">Retry cleanup</.button>
              </:action>
            </.table>
            <p class="text-sm text-muted mt-3">Cleanup stopped after repeated failures. Review private storage in Operator Settings, then retry.</p>
          </.card>
          <.card :if={@preview} inner_class="p-5 sm:p-6">
            <.section_heading title="Restore preview" />
            <.table id="people-backups-preview" rows={@preview.changes} framed={false} caption="Changes on restore">
              <:col :let={change} label="Fact">{change.label}</:col>
              <:col :let={change} label="Current"><.datetime :if={is_struct(change.before, DateTime)} id={"backup-change-#{change_id(change)}-before"} value={change.before} /><span :if={not is_struct(change.before, DateTime)} class="break-all">{display(change.before)}</span></:col>
              <:col :let={change} label="Backup"><.datetime :if={is_struct(change.after, DateTime)} id={"backup-change-#{change_id(change)}-after"} value={change.after} /><span :if={not is_struct(change.after, DateTime)} class="break-all">{display(change.after)}</span></:col>
            </.table>
            <p class="text-sm text-muted">Directory contents and checkpoint cursor will be replaced. The checkpoint generation advances. Sync outcomes, reconciliation, audit history and webhook replay guards remain.</p>
            <.button id="people-backups-request-restore" phx-click="request_restore">Restore backup</.button>
          </.card>
          <.confirm_dialog :if={@confirming && @preview} id="people-backups-confirm" consequence={"Connection state for #{@company.name} will be replaced."} detail="Configuration, checkpoint and directory records will be restored to the reviewed backup. Credentials and webhook secrets will be cleared; webhook intake will be disabled. This replaces current connector state." confirm="Restore" working="Restoring…" on_confirm={JS.push("restore")} on_cancel={JS.push("cancel_restore")} />
        </div>
      </.page>
    </Layouts.app>
    """
  end

  defp label(:retention_days), do: "Retention (days)"
  defp label(:preview_minutes), do: "Preview validity (minutes)"
  defp change_id(change), do: :crypto.hash(:sha256, change.label) |> Base.encode16(case: :lower)
  defp display(nil), do: "None"
  defp display(true), do: "Enabled"
  defp display(false), do: "Disabled"
  defp display(value), do: to_string(value)

  defp message(:disconnected),
    do: "Enable the native connection on People connections before recovery."

  defp message(:checkpoint_moved),
    do:
      "The restored checkpoint was advanced by another sync. Use normal synchronisation on People connections."

  defp message(:preview_changed),
    do: "Connection state changed after the preview. Preview the backup again."

  defp message(:preview_expired), do: "The preview expired. Preview the backup again."

  defp message(:sync_in_progress),
    do: "A sync is running. Wait for its recorded outcome before backup or restore."

  defp message(:connection_changed),
    do:
      "The backup belongs to a different connection or mapping. Use a backup of this connection."

  defp message(:connection_unavailable),
    do: "Configure a native connection on People connections first."

  defp message(:integrity_failure),
    do: "Backup integrity failed. Use another backup and review private storage."

  defp message(:storage_not_configured),
    do: "Configure private artifact storage in Operator Settings."

  defp message(:retention_not_configured),
    do: "Configure artifact retention in Operator Settings."

  defp message(:unauthorized),
    do: "Connection management permission is required for this company."

  defp message(:cleanup_pending),
    do: "Private storage could not remove the backup. Review private storage settings and retry."

  defp message(:restore_required), do: "Restore this backup before requesting recovery."

  defp message(_),
    do:
      "The backup operation was refused. Check access, connection health and private artifact storage, then preview again."
end
