defmodule Bilimbi.PeopleConnector.Connector.Web.FilesLive do
  @moduledoc false
  use Bilimbi.Base.UI, :live_view
  alias Bilimbi.Core.Company
  alias Bilimbi.PeopleConnector.Connector
  alias Bilimbi.PeopleConnector.Connector.FileExchange

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
       page_title: "People file exchange",
       active_nav: nil,
       companies: companies,
       company: nil,
       summary: nil,
       policy_form: nil,
       pending_purge: false
     )
     |> allow_upload(:directory, accept: [".json"], max_entries: 1, max_file_size: 10_485_760)}
  end

  @impl true
  def handle_params(params, _, socket) do
    socket =
      Enum.reduce(
        socket.assigns.uploads.directory.entries,
        socket,
        &cancel_upload(&2, :directory, &1.ref)
      )

    company =
      Enum.find(
        socket.assigns.companies,
        List.first(socket.assigns.companies),
        &(to_string(&1.id) == params["company_id"])
      )

    {:noreply, socket |> assign(company: company, pending_purge: false) |> refresh()}
  end

  @impl true
  def handle_event("select_company", %{"company_id" => id}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/integrations/people/files?company_id=#{id}")}

  def handle_event(_, _, %{assigns: %{company: nil}} = socket),
    do: {:noreply, put_flash(socket, :error, "No company is available for file exchange.")}

  def handle_event("validate", _, socket), do: {:noreply, socket}

  def handle_event("save_policy", %{"policy" => params}, socket) do
    with {bytes, ""} <- Integer.parse(params["max_bytes"] || ""),
         {records, ""} <- Integer.parse(params["max_records"] || ""),
         {stale, ""} <- Integer.parse(params["stale_minutes"] || "") do
      FileExchange.configure(socket.assigns.current_scope.scope, socket.assigns.company.id, %{
        enabled: params["enabled"] == "true",
        json_enabled: params["json_enabled"] == "true",
        max_bytes: bytes,
        max_records: records,
        stale_minutes: stale
      })
      |> outcome(socket, "File policy saved.")
    else
      _ -> outcome({:error, :invalid_file_policy}, socket, nil)
    end
  end

  def handle_event("import", _, socket) do
    results =
      consume_uploaded_entries(socket, :directory, fn %{path: path}, _entry ->
        result =
          with {:ok, bytes} <- File.read(path),
               do:
                 FileExchange.import_file(
                   socket.assigns.current_scope.scope,
                   socket.assigns.company.id,
                   bytes
                 )

        {:ok, result}
      end)

    case results do
      [result] -> outcome(result, socket, "Directory file imported for review.")
      _ -> outcome({:error, :missing_file}, socket, nil)
    end
  end

  def handle_event("export", _, socket) do
    FileExchange.export_file(socket.assigns.current_scope.scope, socket.assigns.company.id)
    |> outcome(socket, "Directory file exported. Download it from the exchange history.")
  end

  def handle_event("request_purge", _, socket),
    do: {:noreply, assign(socket, :pending_purge, true)}

  def handle_event("cancel_purge", _, socket),
    do: {:noreply, assign(socket, :pending_purge, false)}

  def handle_event("purge", _, %{assigns: %{pending_purge: false}} = socket),
    do: {:noreply, socket}

  def handle_event("purge", _, socket) do
    socket = assign(socket, :pending_purge, false)

    FileExchange.purge_expired(socket.assigns.current_scope.scope, socket.assigns.company.id)
    |> case do
      {:ok, %{errors: []}} = result -> outcome(result, socket, "Expired files removed.")
      {:ok, _} -> outcome({:error, :purge_incomplete}, socket, nil)
      error -> outcome(error, socket, nil)
    end
  end

  defp outcome({:ok, %{replayed?: true}}, socket, _),
    do: {:noreply, socket |> refresh() |> put_flash(:info, "This file is already recorded.")}

  defp outcome({:ok, _}, socket, message),
    do: {:noreply, socket |> refresh() |> put_flash(:success, message)}

  defp outcome({:error, _}, socket, _),
    do:
      {:noreply,
       socket
       |> refresh()
       |> put_flash(
         :error,
         "File exchange refused. Check the connection, file policy and private storage settings."
       )}

  defp refresh(%{assigns: %{company: nil}} = socket), do: socket

  defp refresh(socket) do
    case FileExchange.summary(socket.assigns.current_scope.scope, socket.assigns.company.id) do
      {:ok, summary} ->
        form =
          summary.policy
          |> Map.new(fn {k, v} -> {Atom.to_string(k), to_string(v)} end)
          |> to_form(as: :policy)

        assign(socket, summary: summary, policy_form: form)

      _ ->
        assign(socket, summary: nil, policy_form: nil)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page title="People file exchange">
        <.link navigate={~p"/integrations/people/connections"}>People connections</.link>
        <form :if={@companies != []} phx-change="select_company" id="people-files-company-form">
          <.input type="select" name="company_id" id="people-files-company" label="Company" value={@company && @company.id} options={Enum.map(@companies, &{&1.name, &1.id})} />
        </form>
        <.empty_state :if={is_nil(@summary)} id="people-files-unavailable" title="File exchange is unavailable." reason="A connection manager must select an accessible company." />
        <section :if={@summary} class="mt-5 space-y-5">
          <.section_heading title="Directory files" />
          <p class="text-sm text-muted">Imports are retained for review. Synchronise the native connection to refresh live directory records.</p>
          <.link :if={allowed?(@current_scope, "base.settings.global.manage") and allowed?(@current_scope, "admin.system.artifacts.manage")} navigate={~p"/system/settings"}>Private storage and retention settings</.link>
          <.form for={@policy_form} id="people-files-policy" phx-submit="save_policy">
            <.input field={@policy_form[:enabled]} type="select" label="File exchange" options={[{"Disabled", "false"}, {"Enabled", "true"}]} />
            <.input field={@policy_form[:json_enabled]} type="select" label="Directory JSON format" options={[{"Disabled", "false"}, {"Enabled", "true"}]} />
            <.input field={@policy_form[:max_bytes]} type="number" label="Maximum file bytes" min="1" max="10485760" required />
            <.input field={@policy_form[:max_records]} type="number" label="Maximum directory records" min="1" max="100000" required />
            <.input field={@policy_form[:stale_minutes]} type="number" label="Abandon in-progress exchanges after (minutes)" min="1" max="1440" required />
            <.button type="submit" id="people-files-save" phx-disable-with="Saving…">Save file policy</.button>
          </.form>
          <form id="people-files-import" phx-submit="import" phx-change="validate">
            <label for={@uploads.directory.ref}>Directory JSON file</label>
            <.live_file_input upload={@uploads.directory} />
            <p :for={error <- upload_errors(@uploads.directory)} class="text-danger">{upload_message(error)}</p>
            <div :for={entry <- @uploads.directory.entries}>
              <progress value={entry.progress} max="100">{entry.progress}%</progress>
              <p :for={error <- upload_errors(@uploads.directory, entry)} class="text-danger">{upload_message(error)}</p>
            </div>
            <.button type="submit" disabled={not @summary.policy.enabled or not @summary.policy.json_enabled} phx-disable-with="Importing…">Import for review</.button>
          </form>
          <.button id="people-files-export" phx-click="export" disabled={not @summary.policy.enabled or not @summary.policy.json_enabled} phx-disable-with="Exporting…">Export directory</.button>
          <.button id="people-files-purge" phx-click="request_purge">Remove expired files</.button>
          <.confirm_dialog :if={@pending_purge} id="people-files-purge-confirm"
            consequence="Expired directory files for this company will be removed."
            detail="Exchange receipts remain as audit history. Expired files are already unavailable for download."
            confirm="Remove" working="Removing…" on_confirm={JS.push("purge")} on_cancel={JS.push("cancel_purge")} />
          <p class="text-sm text-muted">Downloads require a current enabled connection and an unexpired retained file.</p>
          <.table id="people-files-history" rows={@summary.records} caption="Recent file exchanges">
            <:col :let={row} label="Direction">{if row.direction == :import, do: "Import for review", else: "Export"}</:col>
            <:col :let={row} label="Records">{row.record_count}</:col>
            <:col :let={row} label="State">{exchange_state(row.state)}</:col>
            <:col :let={row} label="Created"><.datetime id={"people-file-date-#{row.id}"} value={row.inserted_at} /></:col>
            <:action :let={row}><.link :if={row.state == :ready} href={~p"/integrations/people/files/#{@company.id}/#{row.id}"}>Download</.link></:action>
            <:empty>No files exchanged.</:empty>
          </.table>
        </section>
      </.page>
    </Layouts.app>
    """
  end

  defp exchange_state(:ready), do: "Completed"
  defp exchange_state(:pending), do: "In progress"
  defp exchange_state(:failed), do: "Failed"
  defp exchange_state(:stale), do: "Abandoned"
  defp exchange_state(:expired), do: "Expired"

  defp upload_message(:too_large), do: "File exceeds the upload limit."
  defp upload_message(:not_accepted), do: "Choose a JSON file."
  defp upload_message(_), do: "Choose one complete file."
end
