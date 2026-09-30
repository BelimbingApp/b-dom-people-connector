defmodule Bilimbi.PeopleConnector.Connector do
  @moduledoc """
  Provider-neutral Connector boundary.

  Tenant-owned calls take a validated Tenancy scope and an explicit platform
  company ID (a Core Company in that tenant). The People Workforce public API
  validates that company and returns its separate workforce-company identity;
  a stored connection records both axes and is refused once they stop
  matching the current Workforce mapping.

  Reads follow People Workforce's read policy: each one first asks
  `Workforce.company/2` for the company and is refused when Workforce refuses
  it. Every write also needs the scope's signed-in actor to hold
  `people-connector.connections.manage` with reach to the target company, so a
  same-tenant sibling company needs tenant-wide company reach.
  A provider credential is an encrypted company-scoped Base Setting; this
  facade stores or clears it and reports only whether one exists.

  `synchronise/6` reads an enabled connection's provider through a read-port
  adapter into Connector-owned projections, with a checkpoint, durable
  idempotency keys and reconciliation issues. `workforce/2` returns those
  projections with their freshness. No adapter is installed yet, so
  `request_port/6` and `synchronise/6` refuse with `:adapter_unavailable`.
  """

  import Ecto.Query

  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Settings
  alias Bilimbi.Base.Settings.Scope, as: SettingsScope
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.People.Workforce
  alias Bilimbi.People.Workforce.ReadResult
  alias Bilimbi.PeopleConnector.Connector.Adapters
  alias Bilimbi.PeopleConnector.Connector.Connection
  alias Bilimbi.PeopleConnector.Connector.Provider
  alias Bilimbi.PeopleConnector.Connector.Registry
  alias Bilimbi.PeopleConnector.Connector.Status
  alias Bilimbi.PeopleConnector.Connector.Sync
  alias Bilimbi.PeopleConnector.Connector.SyncRun
  alias Bilimbi.PeopleConnector.Connector.SyncSummary

  @manage_capability "people-connector.connections.manage"
  @credential_key "people-connector.connection.credential"
  @credential_max_bytes 4096

  @type read_refusal ::
          :not_found | :mapping_changed | {:not_current, ReadResult.freshness()}

  @type write_refusal ::
          read_refusal()
          | :unauthorized
          | :unsupported
          | :disconnected
          | :credential_not_required
          | :credential_missing
          | :invalid_credential
          | :workforce_company_taken
          | :conflict

  @type refusal ::
          read_refusal() | :unsupported | :disconnected | :adapter_unavailable

  @type sync_refusal ::
          refusal()
          | :unauthorized
          | :invalid_idempotency_key
          | :sync_in_progress
          | :conflict

  @doc "The capability every connection write requires."
  @spec manage_capability() :: String.t()
  def manage_capability, do: @manage_capability

  @doc "The encrypted company-scoped setting that holds a provider credential."
  @spec credential_key() :: String.t()
  def credential_key, do: @credential_key

  @doc """
  The company's connection state. Stale or unavailable workforce identity,
  and a stored mapping that no longer matches Workforce, are refused.
  """
  @spec status(Scope.t(), term()) :: {:ok, Status.t()} | {:error, read_refusal()}
  def status(%Scope{} = scope, platform_company_id) do
    with {:ok, current} <- workforce_status(scope, platform_company_id) do
      case get_connection(scope, current.platform_company_id) do
        nil -> {:ok, current}
        %Connection{} = connection -> connected_status(current, connection)
      end
    end
  end

  @doc """
  Chooses the company's provider and records the current platform/workforce
  company mapping. A new or changed provider starts disabled; changing
  provider discards the previous provider's credential.
  """
  @spec configure_connection(Scope.t(), term(), Registry.t(), String.t()) ::
          {:ok, Status.t()} | {:error, write_refusal()}
  def configure_connection(
        %Scope{} = scope,
        platform_company_id,
        %Registry{} = registry,
        provider_id
      ) do
    with {:ok, company_id} <- authorize(scope, platform_company_id),
         {:ok, %Provider{} = provider} <- Registry.fetch(registry, provider_id),
         {:ok, current} <- workforce_status(scope, company_id),
         {:ok, _connection} <- store_connection(scope, current, provider) do
      status(scope, company_id)
    end
  end

  @doc "Stores a secret for a connection whose provider declares one."
  @spec put_credential(Scope.t(), term(), Registry.t(), term()) ::
          :ok | {:error, write_refusal()}
  def put_credential(%Scope{} = scope, platform_company_id, %Registry{} = registry, secret) do
    with {:ok, company_id} <- authorize(scope, platform_company_id),
         {:ok, connection, provider} <- connection_provider(scope, company_id, registry),
         :ok <- require_secret_provider(provider),
         :ok <- validate_secret(secret),
         {:ok, _stored} <- Settings.put(@credential_key, secret, settings_scope(connection)) do
      :ok
    end
  end

  @doc "Clears the stored secret and disables a connection that needs one."
  @spec clear_credential(Scope.t(), term(), Registry.t()) :: :ok | {:error, write_refusal()}
  def clear_credential(%Scope{} = scope, platform_company_id, %Registry{} = registry) do
    with {:ok, company_id} <- authorize(scope, platform_company_id),
         {:ok, connection, provider} <- connection_provider(scope, company_id, registry),
         :ok <- require_secret_provider(provider) do
      transact(fn ->
        :ok = Settings.delete(@credential_key, settings_scope(connection))

        if connection.enabled,
          do: connection |> Connection.changeset(%{enabled: false}) |> Repo.update(),
          else: {:ok, connection}
      end)
      |> case do
        {:ok, _connection} -> :ok
        {:error, _reason} = error -> error
      end
    end
  end

  @doc """
  Enables or disables a connection. Enabling requires a current company
  mapping, an installed provider and, when the provider declares one, a
  stored credential.
  """
  @spec set_enabled(Scope.t(), term(), Registry.t(), boolean()) ::
          {:ok, Status.t()} | {:error, write_refusal()}
  def set_enabled(%Scope{} = scope, platform_company_id, %Registry{} = registry, enabled)
      when is_boolean(enabled) do
    with {:ok, company_id} <- authorize(scope, platform_company_id),
         {:ok, %Status{} = current} <- status(scope, company_id),
         {:ok, connection, provider} <- connection_provider(scope, company_id, registry),
         :ok <- require_credential(provider, current, enabled),
         {:ok, _connection} <-
           connection |> Connection.changeset(%{enabled: enabled}) |> Repo.update() do
      status(scope, company_id)
    end
  end

  @doc "Removes the company's connection and its stored credential."
  @spec remove_connection(Scope.t(), term()) :: :ok | {:error, write_refusal()}
  def remove_connection(%Scope{} = scope, platform_company_id) do
    with {:ok, company_id} <- authorize(scope, platform_company_id),
         %Connection{} = connection <- get_connection(scope, company_id) do
      transact(fn ->
        :ok = Settings.delete(@credential_key, settings_scope(connection))
        Repo.delete(connection)
      end)
      |> case do
        {:ok, _connection} -> :ok
        {:error, _reason} = error -> error
      end
    else
      nil -> {:error, :disconnected}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Checks a provider's declaration for a direction, then the company's
  connection. An undeclared operation is refused even if an adapter
  implements it. A declared port is `:disconnected` unless that provider's
  connection is enabled, and `:adapter_unavailable` while no adapter serves it.
  """
  @spec request_port(
          Scope.t(),
          term(),
          Registry.t(),
          String.t(),
          String.t(),
          :read | :write
        ) :: {:error, refusal()}
  def request_port(
        %Scope{} = scope,
        platform_company_id,
        %Registry{} = registry,
        provider_id,
        capability,
        direction
      ) do
    with {:ok, status} <- status(scope, platform_company_id),
         :ok <- Registry.permit(registry, provider_id, capability, direction) do
      if status.state == :enabled and status.provider_id == provider_id,
        do: {:error, :adapter_unavailable},
        else: {:error, :disconnected}
    end
  end

  @doc """
  Runs one synchronisation pass for the company's enabled connection.

  Needs the manage capability, like every connection write. `idempotency_key`
  names the request: asking again with the same key returns the recorded
  run without reading the provider again. The first pass bootstraps; later
  passes read changes after the checkpoint; `full: true` reads the whole
  directory again and deactivates records the provider no longer lists. A
  pass outcome that is not `:succeeded` is still `{:ok, run}`; see `SyncRun`
  for the states.
  """
  @spec synchronise(Scope.t(), term(), Registry.t(), Adapters.t(), term(), keyword()) ::
          {:ok, SyncRun.t()} | {:error, sync_refusal()}
  def synchronise(
        %Scope{} = scope,
        platform_company_id,
        %Registry{} = registry,
        adapters,
        idempotency_key,
        opts \\ []
      )
      when is_map(adapters) and is_list(opts) do
    with {:ok, company_id} <- authorize(scope, platform_company_id),
         :ok <- Sync.validate_key(idempotency_key),
         {:ok, status} <- enabled_status(scope, company_id),
         :ok <- Registry.permit(registry, status.provider_id, Sync.stream_capability(), :read),
         {:ok, provider} <- Registry.fetch(registry, status.provider_id),
         {:ok, adapter} <- fetch_adapter(adapters, provider.id) do
      Sync.run(scope, status, provider, adapter, idempotency_key, opts)
    end
  end

  @doc """
  The company's checkpoint, last run, open issues and policy, under People
  Workforce's read policy for the company.
  """
  @spec sync_summary(Scope.t(), term()) :: {:ok, SyncSummary.t()} | {:error, read_refusal()}
  def sync_summary(%Scope{} = scope, platform_company_id) do
    with {:ok, status} <- status(scope, platform_company_id) do
      {:ok, Sync.summary(scope, status)}
    end
  end

  @doc """
  The company's active synchronised directory records as a People Workforce
  `ReadResult`, under Workforce's read policy for the company: current, stale past the maximum age, or unavailable when the
  connection is not enabled or has never completed a pass.
  """
  @spec workforce(Scope.t(), term()) :: {:ok, ReadResult.t()} | {:error, read_refusal()}
  def workforce(%Scope{} = scope, platform_company_id) do
    with {:ok, status} <- status(scope, platform_company_id) do
      {:ok, Sync.workforce(scope, status)}
    end
  end

  @doc "Marks one of the company's open reconciliation issues resolved."
  @spec resolve_issue(Scope.t(), term(), term()) :: :ok | {:error, write_refusal()}
  def resolve_issue(%Scope{} = scope, platform_company_id, issue_id) do
    with {:ok, company_id} <- authorize(scope, platform_company_id),
         {:ok, status} <- status(scope, company_id) do
      Sync.resolve_issue(scope, status, issue_id)
    end
  end

  @doc """
  Stores the company's synchronisation policy. `values` may hold
  `:page_limit`, `:max_age_minutes` and `:run_timeout_minutes` integers within
  `Sync.policy_fields/0` bounds; an out-of-range value changes nothing.
  """
  @spec put_sync_policy(Scope.t(), term(), map()) ::
          {:ok, Sync.policy()} | {:error, write_refusal() | {:invalid_policy, atom()}}
  def put_sync_policy(%Scope{} = scope, platform_company_id, values) do
    with {:ok, company_id} <- authorize(scope, platform_company_id),
         {:ok, _status} <- workforce_status(scope, company_id) do
      Sync.put_policy(scope, company_id, values)
    end
  end

  defp enabled_status(scope, company_id) do
    case status(scope, company_id) do
      {:ok, %Status{state: :enabled} = status} -> {:ok, status}
      {:ok, %Status{}} -> {:error, :disconnected}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_adapter(adapters, provider_id) do
    case Map.fetch(adapters, provider_id) do
      {:ok, adapter} when is_atom(adapter) -> {:ok, adapter}
      _ -> {:error, :adapter_unavailable}
    end
  end

  defp workforce_status(scope, platform_company_id) do
    with {:ok, result} <- Workforce.company(scope, platform_company_id) do
      Status.from_workforce_result(result)
    end
  end

  defp connected_status(%Status{} = current, %Connection{} = connection) do
    if connection.workforce_source_id == current.workforce_source_id and
         connection.workforce_company_id == current.workforce_company_id do
      {:ok,
       %Status{
         current
         | state: if(connection.enabled, do: :enabled, else: :disabled),
           provider_id: connection.provider_id,
           credential_stored?: Settings.overridden?(@credential_key, settings_scope(connection))
       }}
    else
      {:error, :mapping_changed}
    end
  end

  defp store_connection(scope, %Status{} = current, %Provider{} = provider) do
    mapping = %{
      provider_id: provider.id,
      provider_contract_version: provider.contract_version,
      workforce_source_id: current.workforce_source_id,
      workforce_company_id: current.workforce_company_id
    }

    transact(fn ->
      case get_connection(scope, current.platform_company_id, lock: true) do
        nil ->
          %Connection{
            tenant_id: Scope.tenant_id(scope),
            platform_company_id: current.platform_company_id,
            enabled: false
          }
          |> Connection.changeset(mapping)
          |> Repo.insert()

        %Connection{} = connection ->
          provider_changed? = connection.provider_id != provider.id

          remapped? =
            connection.workforce_source_id != current.workforce_source_id or
              connection.workforce_company_id != current.workforce_company_id

          if provider_changed?,
            do: :ok = Settings.delete(@credential_key, settings_scope(connection))

          # Records synchronised from another provider or workforce company
          # must not survive as this mapping's data.
          if provider_changed? or remapped?, do: :ok = Sync.reset(connection)

          changes =
            if provider_changed? or remapped?,
              do: Map.put(mapping, :enabled, false),
              else: mapping

          connection |> Connection.changeset(changes) |> Repo.update()
      end
    end)
    |> case do
      {:ok, connection} -> {:ok, connection}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, constraint_refusal(changeset)}
    end
  end

  defp constraint_refusal(%Ecto.Changeset{errors: errors}) do
    if Keyword.has_key?(errors, :workforce_company_id),
      do: :workforce_company_taken,
      else: :conflict
  end

  defp connection_provider(scope, company_id, registry) do
    with %Connection{} = connection <- get_connection(scope, company_id),
         {:ok, provider} <- Registry.fetch(registry, connection.provider_id) do
      {:ok, connection, provider}
    else
      nil -> {:error, :disconnected}
      {:error, :unsupported} = error -> error
    end
  end

  defp require_secret_provider(%Provider{credential: :secret}), do: :ok
  defp require_secret_provider(%Provider{}), do: {:error, :credential_not_required}

  defp require_credential(
         %Provider{credential: :secret},
         %Status{credential_stored?: false},
         true
       ),
       do: {:error, :credential_missing}

  defp require_credential(_provider, _status, _enabled), do: :ok

  defp validate_secret(secret)
       when is_binary(secret) and secret != "" and byte_size(secret) <= @credential_max_bytes do
    if String.valid?(secret) and String.trim(secret) != "",
      do: :ok,
      else: {:error, :invalid_credential}
  end

  defp validate_secret(_secret), do: {:error, :invalid_credential}

  defp authorize(scope, platform_company_id) do
    with {:ok, actor} <- Authz.scope_actor(scope),
         {:ok, company} <-
           Company.authorize_company_target(actor, platform_company_id, @manage_capability) do
      {:ok, company.id}
    else
      {:error, :no_authenticated_actor} -> {:error, :unauthorized}
      {:error, :unauthorized} -> {:error, :unauthorized}
      {:error, _not_found} -> {:error, :not_found}
    end
  end

  defp get_connection(scope, platform_company_id, opts \\ []) do
    query =
      from(c in Tenancy.scope_query(Connection, scope),
        where: c.platform_company_id == ^platform_company_id
      )

    query = if Keyword.get(opts, :lock, false), do: lock(query, "FOR UPDATE"), else: query
    Repo.one(query)
  end

  defp settings_scope(%Connection{} = connection),
    do: SettingsScope.company(connection.platform_company_id, connection.tenant_id)

  defp transact(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end
end
