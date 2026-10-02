defmodule Bilimbi.PeopleConnector.Connector.Doctor do
  @moduledoc """
  An operator-run health check for one Core platform company's connection.

  Returns fixed, actionable check results and counts; never secret values,
  employee data, provider exception text or private storage paths. Configuration
  refusals (including a changed workforce mapping) become findings, so an
  operator can diagnose a broken connection. Only connection managers with
  reach to the company may run it. Records an audit action, without repair,
  sync, webhook dispatch, file transport or backup/recovery side effects.
  """
  import Ecto.Query
  alias Bilimbi.Base.{Repo, Settings, Tenancy}
  alias Bilimbi.Base.Settings.Scope, as: SettingsScope
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.PeopleConnector.Connector

  alias Bilimbi.PeopleConnector.Connector.{
    Adapters,
    Connection,
    Operations,
    Providers,
    Registry,
    ReconciliationIssue,
    Sync,
    SyncRun,
    Webhooks
  }

  alias Bilimbi.PeopleConnector.Connector.FileExchange.Record

  def run(%Scope{} = scope, company) do
    with {:ok, company} <- Operations.authorize(scope, company) do
      Operations.transaction(fn ->
        connection =
          Tenancy.scope_query(Connection, scope)
          |> where(platform_company_id: ^company)
          |> Repo.one()

        now = DateTime.utc_now()

        checks =
          configuration(scope, company, connection) ++
            sync_checks(scope, company, connection, now) ++
            webhook_checks(scope, company) ++ file_checks(scope, company, now)

        report = %{
          checked_at: now,
          platform_company_id: company,
          checks: checks,
          healthy?: Enum.all?(checks, &(&1.state == :ok))
        }

        Operations.audit!(scope, company, "people-connector.doctor", %{
          result: "succeeded",
          checks: Enum.map(checks, &Map.take(&1, [:code, :state, :count]))
        })

        report
      end)
    end
  end

  defp configuration(scope, company, connection) do
    status =
      case Connector.status(scope, company) do
        {:ok, %{state: :enabled}} ->
          check(:configuration, :ok, "Connection enabled", "The company mapping is current.")

        {:ok, %{state: :disabled}} ->
          check(
            :configuration,
            :warning,
            "Connection disabled",
            "Enable the connection when directory synchronisation is required."
          )

        {:ok, _} ->
          check(
            :configuration,
            :warning,
            "No connection configured",
            "Choose the native provider on People connections."
          )

        {:error, :mapping_changed} ->
          check(
            :configuration,
            :error,
            "Company mapping changed",
            "Reconfigure the connection to the current workforce company, then synchronise."
          )

        {:error, _} ->
          check(
            :configuration,
            :error,
            "Company identity unavailable",
            "Restore the People workforce company before synchronising."
          )
      end

    provider =
      if connection,
        do: Registry.fetch(Providers.installed(), connection.provider_id),
        else: {:error, :unsupported}

    provider_checks =
      case provider do
        {:ok, provider} ->
          settings = SettingsScope.company(company, Scope.tenant_id(scope))

          credential? =
            provider.credential == :none or
              Settings.overridden?(Connector.credential_key(), settings)

          [
            check(
              :provider,
              if(connection.provider_contract_version == provider.contract_version,
                do: :ok,
                else: :error
              ),
              "Provider contract",
              "Reconfigure if the stored provider contract no longer matches the installed provider."
            ),
            check(
              :credential,
              if(credential?, do: :ok, else: :error),
              "Provider credential",
              if(provider.credential == :none,
                do: "The co-located native provider requires no credential.",
                else: "Store the required encrypted credential on People connections."
              )
            ),
            check(
              :adapter,
              if(Map.has_key?(Adapters.installed(), provider.id), do: :ok, else: :error),
              "Native adapter",
              "Install the adapter that registers this provider's directory reads."
            )
          ]

        _ ->
          [
            check(
              :provider,
              :error,
              "No supported provider",
              "Choose the co-located native provider; remote and vendor transport are disabled."
            )
          ]
      end

    [status | provider_checks]
  end

  defp sync_checks(_, _, nil, _),
    do: [
      check(
        :projection,
        :warning,
        "Directory unavailable",
        "Configure and synchronise the connection."
      )
    ]

  defp sync_checks(scope, company, connection, now) do
    policy = Sync.policy(scope, company)
    runs = owned(scope, SyncRun, connection)

    stalled =
      runs
      |> where(
        [r],
        r.state == :running and
          r.started_at < ^DateTime.add(now, -policy.run_timeout_minutes, :minute)
      )
      |> Repo.aggregate(:count)

    failed =
      runs
      |> where([r], r.state in [:failed, :unknown, :refused, :stale, :unavailable])
      |> Repo.aggregate(:count)

    issues =
      owned(scope, ReconciliationIssue, connection)
      |> where(status: :open)
      |> Repo.aggregate(:count)

    last = runs |> order_by(desc: :started_at, desc: :id) |> limit(1) |> Repo.one()

    freshness =
      case Connector.sync_summary(scope, company) do
        {:ok, %{freshness: :current, as_of_at: at}} ->
          check(
            :projection,
            :ok,
            "Directory current",
            "The completed checkpoint is within the company freshness policy."
          )
          |> Map.put(:at, at)

        {:ok, %{freshness: {:stale, at}}} ->
          check(
            :projection,
            :warning,
            "Directory stale",
            "Run a synchronisation pass on People connections."
          )
          |> Map.put(:at, at)

        _ ->
          check(
            :projection,
            :error,
            "Directory unavailable",
            "Restore the connection mapping and complete a synchronisation pass."
          )
      end

    [
      freshness,
      check(
        :last_sync,
        if(last && last.state == :succeeded, do: :ok, else: :warning),
        "Last synchronisation",
        "Review the last pass on People connections and retry if it did not complete."
      )
      |> Map.put(:at, last && (last.finished_at || last.started_at)),
      tally(
        :stalled_syncs,
        stalled,
        "Timed-out synchronisations",
        "Run a new pass to record the unknown outcome and retry."
      ),
      tally(
        :failed_syncs,
        failed,
        "Unsuccessful synchronisations retained",
        "Review pass outcomes and reconciliation issues; resolved history remains until retention applies."
      ),
      tally(
        :issues,
        issues,
        "Open reconciliation issues",
        "Review and resolve the issues on People connections."
      )
    ]
  end

  defp webhook_checks(scope, company) do
    summary = Webhooks.summary(scope, company)
    state = if summary.enabled and not summary.secret_stored?, do: :error, else: :ok

    [
      check(
        :webhook,
        state,
        if(summary.enabled, do: "Webhook intake enabled", else: "Webhook intake disabled"),
        if(state == :error,
          do: "Store an encrypted signing secret or disable intake on People connections.",
          else: "Intake is operator controlled; notifications do not run synchronisation."
        )
      )
      |> Map.put(:at, summary.last_received_at)
    ]
  end

  defp file_checks(scope, company, now) do
    settings = SettingsScope.company(company, Scope.tenant_id(scope))
    enabled = Settings.get("people-connector.files.enabled", settings)
    format = Settings.get("people-connector.files.json_enabled", settings)

    cutoff =
      DateTime.add(now, -Settings.get("people-connector.files.stale_minutes", settings), :minute)

    query = Tenancy.scope_query(Record, scope) |> where(platform_company_id: ^company)
    failed = query |> where(state: :failed) |> Repo.aggregate(:count)

    stalled =
      query
      |> where([r], r.state == :pending and r.updated_at < ^cutoff)
      |> Repo.aggregate(:count)

    expired =
      query |> where([r], r.state == :ready and r.expires_at <= ^now) |> Repo.aggregate(:count)

    storage? =
      Settings.get("artifacts.storage_root") != "" and
        not is_nil(Settings.get("artifacts.retention_days"))

    [
      check(
        :file_storage,
        if(enabled and not storage?, do: :error, else: :ok),
        "Private file storage configuration",
        "An installation operator must configure private document storage and document retention in System settings."
      ),
      check(
        :files,
        if(enabled and not format, do: :warning, else: :ok),
        if(enabled, do: "File exchange enabled", else: "File exchange disabled"),
        "Review format and private storage settings on File exchange."
      ),
      tally(
        :failed_files,
        failed,
        "Failed file exchanges",
        "Review the exchange history and private storage settings before retrying."
      ),
      tally(
        :stalled_files,
        stalled,
        "Abandoned file exchanges",
        "Retry the file exchange to record abandonment and create a fresh receipt."
      ),
      tally(
        :expired_files,
        expired,
        "Expired file receipts",
        "Remove expired bytes on File exchange; configure receipt retention here."
      )
    ]
  end

  defp owned(scope, schema, connection),
    do: Tenancy.scope_query(schema, scope) |> where(connection_id: ^connection.id)

  defp check(code, state, title, action),
    do: %{code: code, state: state, title: title, action: action, count: nil, at: nil}

  defp tally(code, count, title, action),
    do:
      check(code, if(count == 0, do: :ok, else: :warning), title, action)
      |> Map.put(:count, count)
end
