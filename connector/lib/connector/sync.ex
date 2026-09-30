defmodule Bilimbi.PeopleConnector.Connector.Sync do
  @moduledoc """
  The synchronisation engine behind the Connector facade.

  The facade authorizes the actor and checks the connection, provider
  declaration and adapter before calling `run/5`. A pass then:

    1. locks the connection, marks any pass that outlived the company's run
       timeout `:unknown`, returns the recorded run for a repeated
       idempotency key, refuses a second pass in flight, and records a
       `:running` run - a `:bootstrap` pass without a checkpoint, otherwise
       `:incremental`;
    2. reads every page outside a transaction; a stale or unavailable page,
       an adapter error or a broken page contract stops the pass with
       nothing applied;
    3. in one transaction, applies the pages to the projection and moves the
       checkpoint, provided the run is still `:running`, the connection is
       unchanged and the checkpoint has not moved.

  Every projection write is idempotent: a repeated or older observation
  changes nothing. A record the Connector refuses becomes a reconciliation
  issue and the pass continues. A completed bootstrap deactivates records the
  provider no longer lists. Rows are deactivated, never deleted, and only
  Connector-owned tables are written.
  """

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Settings
  alias Bilimbi.Base.Settings.Scope, as: SettingsScope
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.People.Workforce.ReadResult
  alias Bilimbi.PeopleConnector.Connector.Connection
  alias Bilimbi.PeopleConnector.Connector.Deactivation
  alias Bilimbi.PeopleConnector.Connector.Page
  alias Bilimbi.PeopleConnector.Connector.PortAuthorization
  alias Bilimbi.PeopleConnector.Connector.PortRequest
  alias Bilimbi.PeopleConnector.Connector.Provider
  alias Bilimbi.PeopleConnector.Connector.ReconciliationIssue
  alias Bilimbi.PeopleConnector.Connector.Status
  alias Bilimbi.PeopleConnector.Connector.Sync.Checkpoint
  alias Bilimbi.PeopleConnector.Connector.Sync.Projection
  alias Bilimbi.PeopleConnector.Connector.SyncRun
  alias Bilimbi.PeopleConnector.Connector.SyncSummary
  alias Bilimbi.PeopleConnector.Connector.WorkforceRecord

  @stream_capability "employee_directory"
  @cursor_max 1000

  # Operator policy, each a company-scoped Base Setting: {key, minimum, maximum}.
  @policy [
    page_limit: {"people-connector.sync.page_limit", 1, 1000},
    max_age_minutes: {"people-connector.sync.max_age_minutes", 5, 43_200},
    run_timeout_minutes: {"people-connector.sync.run_timeout_minutes", 1, 1440}
  ]

  @empty_tally %{applied: 0, unchanged: 0, superseded: 0, deactivated: 0, refused: 0}

  @type policy :: %{
          page_limit: pos_integer(),
          max_age_minutes: pos_integer(),
          run_timeout_minutes: pos_integer()
        }

  @doc "The read declaration a provider needs before any pass is requested."
  @spec stream_capability() :: String.t()
  def stream_capability, do: @stream_capability

  @doc "Policy fields with their setting key and inclusive bounds."
  @spec policy_fields() :: keyword({String.t(), pos_integer(), pos_integer()})
  def policy_fields, do: @policy

  @spec validate_key(term()) :: :ok | {:error, :invalid_idempotency_key}
  def validate_key(key) when is_binary(key) do
    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,99}\z/, key),
      do: :ok,
      else: {:error, :invalid_idempotency_key}
  end

  def validate_key(_key), do: {:error, :invalid_idempotency_key}

  @spec policy(Scope.t(), pos_integer()) :: policy()
  def policy(%Scope{} = scope, platform_company_id) do
    settings_scope = SettingsScope.company(platform_company_id, Scope.tenant_id(scope))

    Map.new(@policy, fn {field, {key, _min, _max}} ->
      {field, Settings.get(key, settings_scope)}
    end)
  end

  @spec put_policy(Scope.t(), pos_integer(), map()) ::
          {:ok, policy()} | {:error, {:invalid_policy, atom()}}
  def put_policy(%Scope{} = scope, platform_company_id, values) when is_map(values) do
    with {:ok, validated} <- validate_policy(values) do
      settings_scope = SettingsScope.company(platform_company_id, Scope.tenant_id(scope))

      transact(fn ->
        Enum.reduce_while(validated, {:ok, nil}, fn {field, value}, _acc ->
          {key, _min, _max} = Keyword.fetch!(@policy, field)

          case Settings.put(key, value, settings_scope) do
            {:ok, _stored} -> {:cont, {:ok, nil}}
            {:error, _changeset} -> {:halt, {:error, {:invalid_policy, field}}}
          end
        end)
      end)
      |> case do
        {:ok, _} -> {:ok, policy(scope, platform_company_id)}
        {:error, _reason} = error -> error
      end
    end
  end

  def put_policy(%Scope{}, _platform_company_id, _values),
    do: {:error, {:invalid_policy, :values}}

  defp validate_policy(values) do
    Enum.reduce_while(@policy, {:ok, []}, fn {field, {_key, min, max}}, {:ok, acc} ->
      case Map.fetch(values, field) do
        {:ok, value} when is_integer(value) and value >= min and value <= max ->
          {:cont, {:ok, [{field, value} | acc]}}

        :error ->
          {:cont, {:ok, acc}}

        {:ok, _invalid} ->
          {:halt, {:error, {:invalid_policy, field}}}
      end
    end)
  end

  @doc """
  Runs one pass for an enabled connection whose provider and adapter the
  facade has already checked. Returns the recorded run. `full: true` asks for
  a bootstrap pass even after a checkpoint exists.
  """
  @spec run(Scope.t(), Status.t(), Provider.t(), module(), String.t(), keyword()) ::
          {:ok, SyncRun.t()} | {:error, :sync_in_progress | :conflict}
  def run(
        %Scope{} = scope,
        %Status{state: :enabled} = status,
        %Provider{} = provider,
        adapter,
        key,
        opts \\ []
      )
      when is_atom(adapter) do
    policy = policy(scope, status.platform_company_id)
    full? = Keyword.get(opts, :full, false) == true

    case start(scope, status, key, policy, full?) do
      {:ok, {:existing, run}} ->
        {:ok, run}

      {:ok, {:started, run, connection, checkpoint}} ->
        authorization = %PortAuthorization{
          scope: scope,
          platform_company_id: connection.platform_company_id,
          workforce_source_id: connection.workforce_source_id,
          workforce_company_id: connection.workforce_company_id,
          provider_id: provider.id,
          capability: @stream_capability
        }

        outcome = read_pages(adapter, authorization, run.pass, checkpoint, policy.page_limit)
        finish(scope, run, checkpoint, provider, outcome)

      {:error, _reason} = error ->
        error
    end
  end

  @doc "The company's synchronisation state for display; changes nothing."
  @spec summary(Scope.t(), Status.t()) :: SyncSummary.t()
  def summary(%Scope{} = scope, %Status{} = status) do
    policy = policy(scope, status.platform_company_id)
    now = DateTime.utc_now()

    case connection_for(scope, status) do
      nil ->
        %SyncSummary{
          freshness: {:unavailable, :disconnected},
          checkpoint_version: nil,
          as_of_at: nil,
          last_run: nil,
          open_issues: [],
          policy: policy
        }

      %Connection{} = connection ->
        checkpoint = get_checkpoint(connection)

        last_run =
          Repo.one(
            from(r in SyncRun,
              where: r.connection_id == ^connection.id,
              order_by: [desc: r.started_at, desc: r.id],
              limit: 1
            )
          )

        %SyncSummary{
          freshness: freshness(status, checkpoint, policy, now),
          checkpoint_version: checkpoint && checkpoint.version,
          as_of_at: checkpoint && checkpoint.as_of_at,
          last_run: last_run && presented_run(last_run, policy, now),
          open_issues: open_issues(connection),
          policy: policy
        }
    end
  end

  @doc "Active projected records with the freshness a consumer may rely on."
  @spec workforce(Scope.t(), Status.t()) :: ReadResult.t()
  def workforce(%Scope{} = scope, %Status{} = status) do
    policy = policy(scope, status.platform_company_id)

    case connection_for(scope, status) do
      nil ->
        ReadResult.unavailable(:disconnected)

      %Connection{} = connection ->
        checkpoint = get_checkpoint(connection)

        case freshness(status, checkpoint, policy, DateTime.utc_now()) do
          :current -> ReadResult.current(active_records(connection))
          {:stale, as_of} -> ReadResult.stale(active_records(connection), as_of)
          {:unavailable, reason} -> ReadResult.unavailable(reason)
        end
    end
  end

  @doc "Marks one of the company's open issues resolved."
  @spec resolve_issue(Scope.t(), Status.t(), term()) :: :ok | {:error, :not_found}
  def resolve_issue(%Scope{} = scope, %Status{} = status, issue_id) when is_integer(issue_id) do
    with %Connection{} = connection <- connection_for(scope, status),
         %ReconciliationIssue{status: :open} = issue <-
           Repo.one(
             from(i in ReconciliationIssue,
               where: i.id == ^issue_id and i.connection_id == ^connection.id
             )
           ),
         {:ok, _issue} <-
           issue
           |> ReconciliationIssue.changeset(%{status: :resolved, resolved_at: DateTime.utc_now()})
           |> Repo.update() do
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  def resolve_issue(%Scope{}, %Status{}, _issue_id), do: {:error, :not_found}

  @doc """
  Forgets what was synchronised through a connection whose provider or
  company mapping changed, so the next pass bootstraps. Runs and issues stay.
  """
  @spec reset(Connection.t()) :: :ok
  def reset(%Connection{id: connection_id}) do
    Repo.delete_all(from(p in Projection, where: p.connection_id == ^connection_id))
    Repo.delete_all(from(c in Checkpoint, where: c.connection_id == ^connection_id))
    :ok
  end

  ## Start

  defp start(scope, status, key, policy, full?) do
    transact(fn ->
      with {:ok, connection} <- lock_connection(scope, status) do
        now = DateTime.utc_now()
        expire_overdue(connection, policy, now)

        case Repo.one(
               from(r in SyncRun,
                 where: r.connection_id == ^connection.id and r.idempotency_key == ^key
               )
             ) do
          %SyncRun{} = run ->
            {:ok, {:existing, run}}

          nil ->
            begin_run(connection, key, full?, now)
        end
      end
    end)
  end

  defp begin_run(connection, key, full?, now) do
    if Repo.exists?(
         from(r in SyncRun, where: r.connection_id == ^connection.id and r.state == :running)
       ) do
      {:error, :sync_in_progress}
    else
      checkpoint = get_checkpoint(connection)

      %SyncRun{
        tenant_id: connection.tenant_id,
        connection_id: connection.id,
        platform_company_id: connection.platform_company_id,
        provider_id: connection.provider_id,
        idempotency_key: key,
        pass: if(checkpoint && not full?, do: :incremental, else: :bootstrap),
        state: :running,
        started_at: now
      }
      |> SyncRun.changeset(%{})
      |> Repo.insert()
      |> case do
        {:ok, run} -> {:ok, {:started, run, connection, checkpoint}}
        {:error, %Ecto.Changeset{}} -> {:error, :sync_in_progress}
      end
    end
  end

  defp expire_overdue(connection, policy, now) do
    cutoff = DateTime.add(now, -policy.run_timeout_minutes * 60, :second)

    Repo.all(
      from(r in SyncRun,
        where:
          r.connection_id == ^connection.id and r.state == :running and r.started_at < ^cutoff,
        lock: "FOR UPDATE"
      )
    )
    |> Enum.each(fn run ->
      {:ok, _run} =
        run
        |> SyncRun.changeset(%{state: :unknown, reason: "no_outcome_recorded", finished_at: now})
        |> Repo.update()

      report_issue(connection, "run:" <> run.idempotency_key, now, %{
        kind: "unknown_outcome",
        reason: "no_outcome_recorded",
        severity: :warning
      })
    end)
  end

  ## Read

  defp read_pages(adapter, authorization, pass, checkpoint, limit) do
    request = %PortRequest{
      pass: if(pass == :bootstrap, do: :bootstrap, else: :changes),
      since: if(pass == :incremental, do: checkpoint.resume_cursor),
      cursor: nil,
      limit: limit
    }

    read_pages(adapter, authorization, request, %{pages: [], as_of: nil, seen: MapSet.new()})
  end

  defp read_pages(adapter, authorization, request, acc) do
    with {:ok, page} <- call(adapter, authorization, request),
         :ok <- check_page(page, request),
         :current <- page.freshness do
      acc = %{
        acc
        | pages: [page.entries | acc.pages],
          as_of: earliest(acc.as_of, usec(page.as_of)),
          seen: MapSet.put(acc.seen, request.cursor)
      }

      cond do
        is_nil(page.next_cursor) ->
          entries = acc.pages |> Enum.reverse() |> Enum.concat()
          {:complete, entries, acc.as_of, page.resume_cursor}

        MapSet.member?(acc.seen, page.next_cursor) ->
          {:failed, "cursor_repeated"}

        true ->
          read_pages(adapter, authorization, %{request | cursor: page.next_cursor}, acc)
      end
    else
      {:stale, %DateTime{} = as_of} -> {:stale, usec(as_of)}
      {:unavailable, _reason} -> {:unavailable, "provider_unavailable"}
      {:failed, _reason} = failed -> failed
    end
  end

  defp call(adapter, authorization, request) do
    case adapter.read(authorization, request) do
      {:ok, %Page{} = page} -> {:ok, page}
      {:ok, _other} -> {:failed, "invalid_page"}
      {:error, _reason} -> {:failed, "adapter_error"}
      _other -> {:failed, "invalid_page"}
    end
  rescue
    _error -> {:failed, "adapter_error"}
  catch
    kind, _reason when kind in [:exit, :throw] -> {:failed, "adapter_error"}
  end

  defp check_page(%Page{} = page, request) do
    valid? =
      is_list(page.entries) and length(page.entries) <= request.limit and
        match?(%DateTime{}, page.as_of) and cursor?(page.next_cursor) and
        cursor?(page.resume_cursor) and freshness?(page.freshness) and
        (request.pass == :changes or not Enum.any?(page.entries, &match?(%Deactivation{}, &1)))

    if valid?, do: :ok, else: {:failed, "invalid_page"}
  end

  defp cursor?(nil), do: true

  defp cursor?(cursor),
    do: is_binary(cursor) and cursor != "" and byte_size(cursor) <= @cursor_max

  defp freshness?(:current), do: true
  defp freshness?({:stale, %DateTime{}}), do: true
  defp freshness?({:unavailable, reason}), do: is_atom(reason) or is_binary(reason)
  defp freshness?(_freshness), do: false

  defp earliest(nil, as_of), do: as_of

  defp earliest(current, as_of),
    do: if(DateTime.before?(as_of, current), do: as_of, else: current)

  ## Finish

  defp finish(scope, run, checkpoint, provider, outcome) do
    transact(fn ->
      run = Repo.one!(from(r in SyncRun, where: r.id == ^run.id, lock: "FOR UPDATE"))

      # A pass that outlived its timeout was already recorded as unknown; its
      # late result is discarded rather than applied.
      if run.state == :running,
        do: record_outcome(scope, run, checkpoint, provider, outcome),
        else: {:ok, run}
    end)
    |> case do
      {:ok, run} -> {:ok, run}
      {:error, _reason} -> {:error, :conflict}
    end
  end

  defp record_outcome(_scope, run, _checkpoint, _provider, {:stale, as_of}),
    do: close(run, :stale, "provider_stale", %{as_of_at: as_of})

  defp record_outcome(_scope, run, _checkpoint, _provider, {:unavailable, reason}),
    do: close(run, :unavailable, reason, %{})

  defp record_outcome(_scope, run, _checkpoint, _provider, {:failed, reason}),
    do: close(run, :failed, reason, %{})

  defp record_outcome(scope, run, checkpoint, provider, {:complete, entries, as_of, resume}) do
    connection =
      Repo.one(
        from(c in Tenancy.scope_query(Connection, scope),
          where: c.id == ^run.connection_id,
          lock: "FOR UPDATE"
        )
      )

    cond do
      is_nil(connection) or not connection.enabled or connection.provider_id != provider.id ->
        close(run, :refused, "connection_changed", %{as_of_at: as_of})

      checkpoint_version(get_checkpoint(connection)) != checkpoint_version(checkpoint) ->
        close(run, :failed, "checkpoint_moved", %{as_of_at: as_of})

      true ->
        apply_pass(connection, run, provider, entries, as_of, resume)
    end
  end

  defp apply_pass(connection, run, provider, entries, as_of, resume) do
    now = DateTime.utc_now()

    projections =
      Repo.all(from(p in Projection, where: p.connection_id == ^connection.id))
      |> Map.new(&{{&1.kind, &1.source_id, &1.stable_id}, &1})

    state = %{tally: @empty_tally, projections: projections, seen: MapSet.new()}

    state =
      Enum.reduce(entries, state, &apply_entry(&1, &2, connection, provider, now))

    tally = state.tally

    if run.pass == :bootstrap and entries == [] do
      report_issue(connection, "bootstrap:empty", now, %{
        kind: "empty_bootstrap",
        reason: "no_records",
        severity: :warning
      })
    end

    if tally.refused > 0 and
         tally.applied + tally.deactivated + tally.unchanged + tally.superseded == 0 do
      report_issue(connection, "feed:refused", now, %{
        kind: "feed_refused",
        reason: "every_record_refused",
        severity: :error
      })

      close(run, :refused, "every_record_refused", Map.put(tally, :as_of_at, as_of))
    else
      tally =
        if run.pass == :bootstrap,
          do: deactivate_absent(state, as_of).tally,
          else: tally

      version = advance_checkpoint(connection, as_of, resume)
      resolve_key(connection, "feed:refused", now)

      close(
        run,
        :succeeded,
        nil,
        Map.merge(tally, %{as_of_at: as_of, checkpoint_version: version})
      )
    end
  end

  defp apply_entry(entry, state, connection, provider, now) do
    case classify(entry, connection, provider) do
      {:ok, %WorkforceRecord{} = record} ->
        state
        |> mark_seen(record)
        |> upsert(record, connection, now)

      {:ok, %Deactivation{} = change} ->
        deactivate(state, change, connection, now)

      {:refuse, reason, identity} ->
        report_issue(connection, record_issue_key(identity), now, %{
          kind: "record_refused",
          reason: reason,
          severity: :error,
          record_kind: identity && Atom.to_string(elem(identity, 0)),
          stable_id: identity && elem(identity, 2)
        })

        state
        |> mark_seen(identity)
        |> bump(:refused)
    end
  end

  defp classify(%WorkforceRecord{} = record, connection, provider) do
    cond do
      not WorkforceRecord.valid?(record) -> {:refuse, "invalid_record", identity(record)}
      true -> classify_identity(record, record.workforce_company_id, connection, provider)
    end
  end

  defp classify(%Deactivation{} = change, connection, provider) do
    if Deactivation.valid?(change),
      do: classify_identity(change, connection.workforce_company_id, connection, provider),
      else: {:refuse, "invalid_record", identity(change)}
  end

  defp classify(_entry, _connection, _provider), do: {:refuse, "invalid_record", nil}

  defp identity(%{kind: kind, source_id: source_id, stable_id: stable_id})
       when kind in [:company, :employee] do
    if WorkforceRecord.identifier?(source_id) and WorkforceRecord.identifier?(stable_id),
      do: {kind, source_id, stable_id},
      else: nil
  end

  defp identity(_entry), do: nil

  defp classify_identity(entry, workforce_company_id, connection, provider) do
    identity = {entry.kind, entry.source_id, entry.stable_id}

    cond do
      entry.source_id != connection.workforce_source_id ->
        {:refuse, "foreign_source", identity}

      not declared?(provider, entry.kind) ->
        {:refuse, "undeclared_capability", identity}

      workforce_company_id != connection.workforce_company_id ->
        {:refuse, "other_company", identity}

      true ->
        {:ok, %{entry | observed_at: usec(entry.observed_at)}}
    end
  end

  # Provider times may carry any precision or offset; store them as UTC microseconds.
  defp usec(%DateTime{} = at),
    do: at |> DateTime.to_unix(:microsecond) |> DateTime.from_unix!(:microsecond)

  defp declared?(%Provider{capabilities: capabilities}, kind) do
    capability = WorkforceRecord.capability(kind)
    Enum.any?(capabilities, &(&1.key == capability and &1.direction == :read))
  end

  defp upsert(state, record, connection, now) do
    key = {record.kind, record.source_id, record.stable_id}
    hash = content_hash(record)

    case Map.get(state.projections, key) do
      nil ->
        projection =
          %Projection{
            tenant_id: connection.tenant_id,
            connection_id: connection.id,
            kind: record.kind,
            source_id: record.source_id,
            stable_id: record.stable_id
          }
          |> Projection.changeset(record_changes(record, hash))
          |> Repo.insert!()

        resolve_key(connection, record_issue_key(key), now)
        %{state | projections: Map.put(state.projections, key, projection)} |> bump(:applied)

      %Projection{} = current ->
        cond do
          DateTime.before?(record.observed_at, current.observed_at) ->
            bump(state, :superseded)

          current.content_hash == hash ->
            resolve_key(connection, record_issue_key(key), now)
            bump(state, :unchanged)

          true ->
            projection =
              current |> Projection.changeset(record_changes(record, hash)) |> Repo.update!()

            resolve_key(connection, record_issue_key(key), now)
            counter = if current.active and not record.active, do: :deactivated, else: :applied
            %{state | projections: Map.put(state.projections, key, projection)} |> bump(counter)
        end
    end
  end

  defp deactivate(state, change, connection, now) do
    key = {change.kind, change.source_id, change.stable_id}

    case Map.get(state.projections, key) do
      nil ->
        report_issue(connection, record_issue_key(key), now, %{
          kind: "record_refused",
          reason: "unknown_reference",
          severity: :error,
          record_kind: Atom.to_string(change.kind),
          stable_id: change.stable_id
        })

        bump(state, :refused)

      %Projection{} = current ->
        cond do
          DateTime.before?(change.observed_at, current.observed_at) ->
            bump(state, :superseded)

          not current.active ->
            bump(state, :unchanged)

          true ->
            projection = switch_off(current, change.observed_at, change.observed_at)

            %{state | projections: Map.put(state.projections, key, projection)}
            |> bump(:deactivated)
        end
    end
  end

  defp deactivate_absent(state, as_of) do
    state.projections
    |> Enum.filter(fn {key, projection} ->
      projection.active and not MapSet.member?(state.seen, key)
    end)
    |> Enum.reduce(state, fn {key, projection}, state ->
      deactivated_at =
        if DateTime.before?(projection.observed_at, as_of),
          do: as_of,
          else: projection.observed_at

      projection = switch_off(projection, projection.observed_at, deactivated_at)
      %{state | projections: Map.put(state.projections, key, projection)} |> bump(:deactivated)
    end)
  end

  defp switch_off(projection, observed_at, deactivated_at) do
    hash =
      content_hash(%{
        workforce_company_id: projection.workforce_company_id,
        name: projection.name,
        code: projection.code,
        email: projection.email,
        supervisor_stable_id: projection.supervisor_stable_id,
        active: false
      })

    projection
    |> Projection.changeset(%{
      active: false,
      deactivated_at: deactivated_at,
      observed_at: observed_at,
      content_hash: hash
    })
    |> Repo.update!()
  end

  defp record_changes(record, hash) do
    %{
      workforce_company_id: record.workforce_company_id,
      active: record.active,
      name: record.name,
      code: record.code,
      email: record.email,
      supervisor_stable_id: record.supervisor_stable_id,
      content_hash: hash,
      observed_at: record.observed_at,
      deactivated_at: if(record.active, do: nil, else: record.observed_at)
    }
  end

  defp content_hash(record) do
    {record.workforce_company_id, record.name, record.code, record.email,
     record.supervisor_stable_id, record.active}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp mark_seen(state, nil), do: state

  defp mark_seen(state, %WorkforceRecord{} = record),
    do: mark_seen(state, {record.kind, record.source_id, record.stable_id})

  defp mark_seen(state, key), do: %{state | seen: MapSet.put(state.seen, key)}

  defp bump(state, counter), do: %{state | tally: Map.update!(state.tally, counter, &(&1 + 1))}

  defp advance_checkpoint(connection, as_of, resume) do
    case get_checkpoint(connection) do
      nil ->
        %Checkpoint{tenant_id: connection.tenant_id, connection_id: connection.id}
        |> Checkpoint.changeset(%{version: 1, resume_cursor: resume, as_of_at: as_of})
        |> Repo.insert!()
        |> Map.fetch!(:version)

      %Checkpoint{} = checkpoint ->
        checkpoint
        |> Checkpoint.changeset(%{
          version: checkpoint.version + 1,
          resume_cursor: resume,
          as_of_at: as_of
        })
        |> Repo.update!()
        |> Map.fetch!(:version)
    end
  end

  defp close(run, state, reason, changes) do
    changes =
      changes
      |> Map.take([
        :applied,
        :unchanged,
        :superseded,
        :deactivated,
        :refused,
        :as_of_at,
        :checkpoint_version
      ])
      |> Map.merge(%{state: state, reason: reason, finished_at: DateTime.utc_now()})

    run |> SyncRun.changeset(changes) |> Repo.update()
  end

  ## Issues

  defp record_issue_key(nil), do: "record:invalid"

  defp record_issue_key({kind, source_id, stable_id}) do
    digest =
      :crypto.hash(:sha256, source_id <> <<0>> <> stable_id) |> Base.encode16(case: :lower)

    "record:#{kind}:#{digest}"
  end

  defp report_issue(connection, key, now, attributes) do
    case get_issue(connection, key) do
      nil ->
        %ReconciliationIssue{
          tenant_id: connection.tenant_id,
          connection_id: connection.id,
          issue_key: key
        }
        |> ReconciliationIssue.changeset(
          Map.merge(attributes, %{status: :open, first_seen_at: now, last_seen_at: now})
        )
        |> Repo.insert!()

      %ReconciliationIssue{} = issue ->
        issue
        |> ReconciliationIssue.changeset(
          Map.merge(attributes, %{
            status: :open,
            occurrences: issue.occurrences + 1,
            last_seen_at: now,
            resolved_at: nil
          })
        )
        |> Repo.update!()
    end
  end

  defp resolve_key(connection, key, now) do
    case get_issue(connection, key) do
      %ReconciliationIssue{status: :open} = issue ->
        issue
        |> ReconciliationIssue.changeset(%{status: :resolved, resolved_at: now})
        |> Repo.update!()

      _ ->
        nil
    end
  end

  defp get_issue(connection, key) do
    Repo.one(
      from(i in ReconciliationIssue,
        where: i.connection_id == ^connection.id and i.issue_key == ^key
      )
    )
  end

  defp open_issues(connection) do
    Repo.all(
      from(i in ReconciliationIssue,
        where: i.connection_id == ^connection.id and i.status == :open,
        order_by: [asc: i.severity, desc: i.last_seen_at, desc: i.id],
        limit: 50
      )
    )
  end

  ## Reads

  defp freshness(%Status{state: :enabled}, nil, _policy, _now),
    do: {:unavailable, :never_synchronised}

  defp freshness(%Status{state: :enabled}, %Checkpoint{as_of_at: as_of}, policy, now) do
    if DateTime.diff(now, as_of, :second) > policy.max_age_minutes * 60,
      do: {:stale, as_of},
      else: :current
  end

  defp freshness(%Status{}, _checkpoint, _policy, _now), do: {:unavailable, :disconnected}

  # A pass past the company's run timeout is shown as unknown before the next
  # pass records it so.
  defp presented_run(%SyncRun{state: :running} = run, policy, now) do
    if DateTime.diff(now, run.started_at, :second) > policy.run_timeout_minutes * 60,
      do: %{run | state: :unknown, reason: "no_outcome_recorded"},
      else: run
  end

  defp presented_run(run, _policy, _now), do: run

  defp active_records(connection) do
    Repo.all(
      from(p in Projection,
        where: p.connection_id == ^connection.id and p.active,
        order_by: [asc: p.kind, asc: p.name, asc: p.stable_id]
      )
    )
    |> Enum.map(fn projection ->
      %WorkforceRecord{
        kind: projection.kind,
        source_id: projection.source_id,
        stable_id: projection.stable_id,
        workforce_company_id: projection.workforce_company_id,
        name: projection.name,
        code: projection.code,
        email: projection.email,
        supervisor_stable_id: projection.supervisor_stable_id,
        observed_at: projection.observed_at,
        active: true
      }
    end)
  end

  ## Connection

  defp connection_for(scope, %Status{} = status) do
    Repo.one(
      from(c in Tenancy.scope_query(Connection, scope),
        where: c.platform_company_id == ^status.platform_company_id
      )
    )
  end

  defp lock_connection(scope, %Status{} = status) do
    connection =
      Repo.one(
        from(c in Tenancy.scope_query(Connection, scope),
          where: c.platform_company_id == ^status.platform_company_id,
          lock: "FOR UPDATE"
        )
      )

    if connection && connection.enabled && connection.provider_id == status.provider_id &&
         connection.workforce_source_id == status.workforce_source_id &&
         connection.workforce_company_id == status.workforce_company_id,
       do: {:ok, connection},
       else: {:error, :conflict}
  end

  defp get_checkpoint(connection),
    do: Repo.one(from(c in Checkpoint, where: c.connection_id == ^connection.id))

  defp checkpoint_version(nil), do: 0
  defp checkpoint_version(%Checkpoint{version: version}), do: version

  defp transact(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end
end
