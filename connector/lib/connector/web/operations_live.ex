defmodule Bilimbi.PeopleConnector.Connector.Web.OperationsLive do
  @moduledoc false
  use Bilimbi.Base.UI, :live_view
  alias Bilimbi.Base.UI.CommitStatus
  alias Bilimbi.Core.Company
  alias Bilimbi.PeopleConnector.Connector
  alias Bilimbi.PeopleConnector.Connector.{Doctor, Retention}

  @fields %{
    "sync_days" => :sync_days,
    "webhook_days" => :webhook_days,
    "file_days" => :file_days,
    "batch_size" => :batch_size,
    "retry_minutes" => :retry_minutes
  }

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
       page_title: "People connection health",
       active_nav: nil,
       companies: companies,
       company: nil,
       policy: nil,
       report: nil,
       purge_result: nil,
       pending_purge: false
     )
     |> CommitStatus.init()}
  end

  @impl true
  def handle_params(params, _, socket) do
    company =
      if Map.has_key?(params, "company_id") do
        Enum.find(socket.assigns.companies, &(to_string(&1.id) == params["company_id"]))
      else
        List.first(socket.assigns.companies)
      end

    {:noreply,
     socket
     |> assign(company: company, report: nil, purge_result: nil, pending_purge: false)
     |> CommitStatus.init()
     |> refresh()}
  end

  @impl true
  def handle_event("select_company", %{"company_id" => id}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/integrations/people/operations?company_id=#{id}")}

  def handle_event(_, _, %{assigns: %{company: nil}} = socket),
    do: {:noreply, put_flash(socket, :error, "Select a company you may manage.")}

  def handle_event("run_doctor", _, socket) do
    case Doctor.run(socket.assigns.current_scope.scope, socket.assigns.company.id) do
      {:ok, report} ->
        {:noreply,
         socket |> assign(report: report) |> put_flash(:success, "Health check recorded.")}

      {:error, reason} ->
        {:noreply, socket |> assign(report: nil) |> put_flash(:error, message(reason))}
    end
  end

  def handle_event("save_policy", params, socket) do
    case CommitStatus.inline_field(params, @fields) do
      {:ok, name, field, value} ->
        parsed = if value == "", do: {:ok, nil}, else: parse_integer(value)

        result =
          with {:ok, number} <- parsed,
               do:
                 Retention.configure(
                   socket.assigns.current_scope.scope,
                   socket.assigns.company.id,
                   %{field => number}
                 )

        case result do
          {:ok, policy} ->
            {:noreply, socket |> assign(policy: policy) |> CommitStatus.put(name, :saved)}

          {:error, reason} ->
            {:noreply, CommitStatus.put(socket, name, {:error, message(reason)})}
        end

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("request_purge", _, socket),
    do: {:noreply, socket |> clear_flash() |> assign(pending_purge: true)}

  def handle_event("cancel_purge", _, socket),
    do: {:noreply, assign(socket, :pending_purge, false)}

  def handle_event("purge", _, %{assigns: %{pending_purge: false}} = socket),
    do: {:noreply, socket}

  def handle_event("purge", _, socket) do
    socket = assign(socket, :pending_purge, false)

    case Retention.purge(socket.assigns.current_scope.scope, socket.assigns.company.id) do
      {:ok, result} ->
        {kind, text} =
          if result.errors == [],
            do: {:success, "Retention batch completed."},
            else:
              {:error,
               "Some records could not be removed. Review the results and retry after the configured delay."}

        {:noreply, socket |> assign(purge_result: result, report: nil) |> put_flash(kind, text)}

      {:error, reason} ->
        {:noreply, socket |> assign(purge_result: nil) |> put_flash(:error, message(reason))}
    end
  end

  defp refresh(%{assigns: %{company: nil}} = socket), do: assign(socket, :policy, nil)

  defp refresh(socket) do
    case Retention.policy(socket.assigns.current_scope.scope, socket.assigns.company.id) do
      {:ok, policy} -> assign(socket, :policy, policy)
      _ -> assign(socket, :policy, nil)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page title="People connection health">
        <.form :if={@companies != []} for={to_form(%{"company_id" => @company && to_string(@company.id)})}
          id="people-operations-company-form" phx-change="select_company" phx-submit="select_company">
          <.input type="select" name="company_id" id="people-operations-company" label="Company"
            value={@company && @company.id} options={Enum.map(@companies, &{&1.name, &1.id})} />
        </.form>
        <.empty_state :if={is_nil(@policy)} id="people-operations-unavailable" title="Connection operations unavailable"
          reason="Select an accessible company. A connection manager must have permission to manage it." />
        <div :if={@policy} class="space-y-5 mt-5">
          <.card inner_class="p-5 sm:p-6" role="region" aria-labelledby="people-doctor-heading">
            <.section_heading id="people-doctor-heading" title="Connection health">
              <:actions><.button id="people-doctor-run" phx-click="run_doctor" phx-disable-with="Checking…">Run health check</.button></:actions>
            </.section_heading>
            <div class="flex flex-wrap gap-3 mb-3">
              <.action_link id="people-operations-backups" icon="manage" title="Backup and recovery" navigate={~p"/integrations/people/backups?company_id=#{@company.id}"}>Backup and recovery</.action_link>
              <.action_link id="people-operations-connections" icon="manage" title="People connections" navigate={~p"/integrations/people/connections?company_id=#{@company.id}"}>People connections</.action_link>
              <.action_link id="people-operations-files" icon="manage" title="File exchange" navigate={~p"/integrations/people/files?company_id=#{@company.id}"}>File exchange</.action_link>
            </div>
            <.empty_state :if={is_nil(@report)} id="people-doctor-empty" title="No health check run"
              reason="Run a check to review this company's connection, synchronisation, webhook and file exchange state." />
            <.list :if={@report} id="people-doctor-facts">
              <:item title="Checked"><.datetime id="people-doctor-time" value={@report.checked_at} /></:item>
              <:item title="Result">{if @report.healthy?, do: "Healthy", else: "Review findings"}</:item>
            </.list>
            <.table :if={@report} id="people-doctor-checks" rows={@report.checks} framed={false} caption="Health check findings">
              <:col :let={check} label="Check">{check.title}</:col>
              <:col :let={check} label="State">{state_label(check.state)}</:col>
              <:col :let={check} label="Records">{check.count || "—"}</:col>
              <:col :let={check} label="Last activity"><.datetime :if={check.at} id={"people-doctor-#{check.code}-at"} value={check.at} /><span :if={is_nil(check.at)}>—</span></:col>
              <:col :let={check} label="Next step">{check.action}</:col>
            </.table>
          </.card>
          <.card inner_class="p-5 sm:p-6" role="region" aria-labelledby="people-retention-heading">
            <.section_heading id="people-retention-heading" title="Record retention">
              <:description>Unset periods keep records. Changes apply to the next purge.</:description>
              <:actions><.button id="people-retention-request" phx-click="request_purge">Purge eligible records</.button></:actions>
            </.section_heading>
            <.list id="people-retention-policy">
              <:item :for={{field, {_key, default, min, max}} <- Retention.fields()} title={label(field)}>
                <.inline_edit id={"people-retention-#{field}"} name={Atom.to_string(field)} label={label(field)}
                  value={if is_nil(@policy[field]), do: "", else: to_string(@policy[field])}
                  placeholder={if is_nil(default), do: "Keep records", else: "Required"}
                  allow_empty={is_nil(default)} id_value={@company.id} save_event="save_policy" status={@field_status[Atom.to_string(field)]} />
                <span class="text-sm text-muted">{min}–{max}{if is_nil(default), do: " days; blank keeps records", else: ""}</span>
              </:item>
            </.list>
            <p class="text-sm text-muted mt-3">Purging removes replay history for old requests. Running syncs, each connection's latest and latest successful sync, and pending exchanges remain. File receipts remain until their bytes expire and cleanup succeeds. Webhook replay guards remain throughout the signing window.</p>
            <.confirm_dialog :if={@pending_purge} id="people-retention-confirm"
              consequence={"Eligible connector records for #{@company.name} will be deleted."}
              detail="This cannot be undone. Each record is audited. Checkpoints, directory projections, reconciliation issues and audit history remain."
              confirm="Purge" working="Purging…" on_confirm={JS.push("purge")} on_cancel={JS.push("cancel_purge")} />
            <.list :if={@purge_result} id="people-retention-result">
              <:item title="Removed">{length(@purge_result.deleted)}</:item>
              <:item title="Failed">{length(@purge_result.errors)}</:item>
            </.list>
            <.table :if={@purge_result && @purge_result.errors != []} id="people-retention-errors" rows={@purge_result.errors} framed={false} caption="Records retained for retry">
              <:col :let={row} label="Record type">{kind_label(row.kind)}</:col>
              <:col :let={row} label="Record ID">{row.id}</:col>
              <:col :let={row} label="Next step">{message(row.reason)}</:col>
            </.table>
          </.card>
        </div>
      </.page>
    </Layouts.app>
    """
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _ -> {:error, :invalid_retention_policy}
    end
  end

  defp message(:invalid_retention_policy),
    do:
      "Enter a whole number within the stated range, or clear a retention period to keep records."

  defp message(:unauthorized),
    do: "A connection manager must have permission to manage this company."

  defp message(:not_found), do: "Select an accessible active company."

  defp message(:artifact_cleanup_failed),
    do: "Receipt kept because file cleanup failed. Check private storage settings and retry."

  defp message(:audit_unavailable), do: "Audit is unavailable. Restore audit storage and retry."

  defp message(:no_longer_eligible),
    do: "The record is no longer eligible. Run another batch if needed."

  defp message(_),
    do: "Record kept because the operation failed. Check database and audit storage, then retry."

  defp label(:sync_days), do: "Sync runs (days)"
  defp label(:webhook_days), do: "Webhook deliveries (days)"
  defp label(:file_days), do: "File receipts (days)"
  defp label(:batch_size), do: "Batch size per record type"
  defp label(:retry_minutes), do: "Retry delay (minutes)"
  defp state_label(:ok), do: "OK"
  defp state_label(:warning), do: "Review"
  defp state_label(:error), do: "Action required"
  defp kind_label(:sync), do: "Sync run"
  defp kind_label(:webhook), do: "Webhook delivery"
  defp kind_label(:nonce), do: "Webhook replay guard"
  defp kind_label(:file), do: "File receipt"
end
