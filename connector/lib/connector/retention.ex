defmodule Bilimbi.PeopleConnector.Connector.Retention do
  @moduledoc """
  Operator-run, company-scoped retention of Connector operational records.

  Periods are company settings, unset by default (keep records). Each eligible
  row is independently audited and purged; a failed row is held until the retry
  interval, so it cannot starve later batches. Active sync passes, each
  connection's latest sync run and latest successful sync run, and pending
  file exchanges are preserved. File receipts survive until bytes expire and
  Base Artifacts confirms cleanup. Checkpoints, projections, issues and audit
  history are never purged here. Purged idempotency history cannot deduplicate
  future requests. Webhook nonces survive at least twice the signing skew.
  """
  import Ecto.Query
  alias Bilimbi.Base.{Artifacts, Repo, Settings, Tenancy}
  alias Bilimbi.Base.Settings.Scope, as: SettingsScope
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.PeopleConnector.Connector.{Connection, Operations, SyncRun}
  alias Bilimbi.PeopleConnector.Connector.Webhooks.{Delivery, Nonce}
  alias Bilimbi.PeopleConnector.Connector.FileExchange.{Owner, Record}
  alias Bilimbi.PeopleConnector.Connector.Retention.Attempt

  @fields [
    sync_days: {"people-connector.retention.sync_days", nil, 1, 3650},
    webhook_days: {"people-connector.retention.webhook_days", nil, 1, 3650},
    file_days: {"people-connector.retention.file_days", nil, 1, 3650},
    batch_size: {"people-connector.retention.batch_size", 100, 1, 1000},
    retry_minutes: {"people-connector.retention.retry_minutes", 60, 1, 1440}
  ]

  @doc "Company policy fields: setting key, safe initial value and inclusive bounds."
  def fields, do: @fields

  def policy(%Scope{} = scope, company) do
    with {:ok, company} <- Operations.authorize(scope, company), do: {:ok, values(scope, company)}
  end

  def configure(%Scope{} = scope, company, changes) when is_map(changes) do
    with {:ok, company} <- Operations.authorize(scope, company),
         true <- Enum.all?(changes, &valid?/1) do
      Operations.transaction(fn ->
        for {field, value} <- changes do
          {key, _, _, _} = Keyword.fetch!(@fields, field)

          case Settings.put(key, value, settings_scope(scope, company)) do
            {:ok, _} -> :ok
            _ -> Repo.rollback(:invalid_retention_policy)
          end
        end

        Operations.audit!(scope, company, "people-connector.retention.policy", %{
          result: "succeeded",
          fields: Map.keys(changes)
        })

        values(scope, company)
      end)
    else
      false -> {:error, :invalid_retention_policy}
      error -> error
    end
  end

  def configure(%Scope{}, _, _), do: {:error, :invalid_retention_policy}

  def purge(%Scope{} = scope, company) do
    with {:ok, company} <- Operations.authorize(scope, company),
         {:ok, _} <-
           Operations.transaction(fn ->
             Operations.audit!(scope, company, "people-connector.retention.started", %{
               result: "succeeded",
               policy: values(scope, company)
             })
           end) do
      policy = values(scope, company)
      now = DateTime.utc_now()

      results =
        for kind <- [:sync, :webhook, :nonce, :file],
            row <- candidates(scope, company, kind, policy, now) do
          result = purge_row(scope, company, kind, row.id)

          if match?({:error, _}, result),
            do: record_failure(scope, company, kind, row.id, elem(result, 1))

          %{kind: kind, id: row.id, result: result}
        end

      {:ok,
       %{
         deleted:
           for(%{result: {:ok, :deleted}} = result <- results, do: Map.take(result, [:kind, :id])),
         errors:
           for(
             %{result: {:error, reason}} = result <- results,
             do: Map.put(Map.take(result, [:kind, :id]), :reason, reason)
           )
       }}
    end
  end

  defp purge_row(scope, company, kind, id) do
    # Artifact cleanup must commit outside the receipt transaction. A failed
    # cleanup retains the receipt, allowing authorization and a later retry.
    with {:ok, _} <- Operations.authorize(scope, company),
         :ok <- clean_file(scope, company, kind, id) do
      Operations.transaction(fn ->
        case Operations.authorize(scope, company) do
          {:ok, _} -> :ok
          _ -> Repo.rollback(:unauthorized)
        end

        # Same lock order as sync/webhook/file writers: connection, then record.
        connections(scope, company) |> lock("FOR UPDATE") |> Repo.all()

        row =
          eligible(scope, company, kind, values(scope, company), DateTime.utc_now())
          |> where(id: ^id)
          |> lock("FOR UPDATE")
          |> Repo.one()

        if is_nil(row), do: Repo.rollback(:no_longer_eligible)

        Operations.audit!(scope, company, "people-connector.retention.purged", %{
          result: "succeeded",
          kind: kind,
          record_id: to_string(id)
        })

        Repo.delete!(row)
        attempts(scope, company, kind) |> where(record_id: ^to_string(id)) |> Repo.delete_all()
        :deleted
      end)
    end
  end

  defp clean_file(scope, company, :file, id) do
    row =
      eligible(scope, company, :file, values(scope, company), DateTime.utc_now())
      |> where(id: ^id)
      |> Repo.one()

    case row do
      nil ->
        {:error, :no_longer_eligible}

      %{artifact_id: nil} ->
        :ok

      %{artifact_id: artifact} ->
        case Artifacts.delete(scope, company, Owner, artifact) do
          {:ok, :deleted} -> :ok
          {:error, _} -> {:error, :artifact_cleanup_failed}
        end
    end
  rescue
    _ in [Ecto.ConstraintError, Postgrex.Error] -> {:error, :artifact_cleanup_failed}
  end

  defp clean_file(_, _, _, _), do: :ok

  defp record_failure(scope, company, kind, id, reason) do
    Operations.transaction(fn ->
      case Operations.authorize(scope, company) do
        {:ok, _} -> :ok
        _ -> Repo.rollback(:unauthorized)
      end

      Operations.audit!(scope, company, "people-connector.retention.failed", %{
        result: "failed",
        kind: kind,
        record_id: to_string(id),
        reason: reason
      })

      %Attempt{
        tenant_id: Scope.tenant_id(scope),
        platform_company_id: company,
        kind: to_string(kind),
        record_id: to_string(id),
        attempted_at: DateTime.utc_now()
      }
      |> Repo.insert!(
        on_conflict: {:replace, [:attempted_at]},
        conflict_target: [:platform_company_id, :kind, :record_id]
      )
    end)
  end

  defp candidates(scope, company, kind, policy, now) do
    recent =
      attempts(scope, company, kind)
      |> where([a], a.attempted_at > ^DateTime.add(now, -policy.retry_minutes, :minute))
      |> select([a], a.record_id)

    eligible(scope, company, kind, policy, now)
    |> where([r], fragment("?::text", r.id) not in subquery(recent))
    |> order_by(asc: :id)
    |> limit(^policy.batch_size)
    |> Repo.all()
  end

  defp eligible(scope, company, :file, policy, now) do
    query = Tenancy.scope_query(Record, scope) |> where(platform_company_id: ^company)

    if policy.file_days do
      cutoff = DateTime.add(now, -policy.file_days, :day)

      query
      |> where(
        [r],
        r.state != :pending and r.inserted_at < ^cutoff and
          (is_nil(r.expires_at) or r.expires_at <= ^now)
      )
    else
      where(query, false)
    end
  end

  defp eligible(scope, company, kind, policy, now) do
    schema =
      case kind do
        :sync -> SyncRun
        :webhook -> Delivery
        :nonce -> Nonce
      end

    ids = connections(scope, company) |> select([c], c.id)
    query = Tenancy.scope_query(schema, scope) |> where([r], r.connection_id in subquery(ids))

    case kind do
      :sync when not is_nil(policy.sync_days) ->
        cutoff = DateTime.add(now, -policy.sync_days, :day)
        latest = latest_runs(query)
        succeeded = latest_runs(where(query, state: :succeeded))

        query
        |> where([r], r.state != :running and r.finished_at < ^cutoff)
        |> where([r], r.id not in subquery(latest) and r.id not in subquery(succeeded))

      kind when kind in [:webhook, :nonce] and not is_nil(policy.webhook_days) ->
        skew =
          Settings.get(
            "people-connector.webhook.max_skew_seconds",
            settings_scope(scope, company)
          )

        cutoff = DateTime.add(now, -max(policy.webhook_days * 86_400, 2 * skew), :second)
        query |> where([r], r.received_at < ^cutoff)

      _ ->
        where(query, false)
    end
  end

  defp latest_runs(query) do
    query
    |> distinct([r], r.connection_id)
    |> order_by([r], asc: r.connection_id, desc: r.started_at, desc: r.id)
    |> select([r], r.id)
  end

  defp connections(scope, company),
    do: Tenancy.scope_query(Connection, scope) |> where(platform_company_id: ^company)

  defp attempts(scope, company, kind),
    do:
      Tenancy.scope_query(Attempt, scope)
      |> where(platform_company_id: ^company, kind: ^to_string(kind))

  defp settings_scope(scope, company), do: SettingsScope.company(company, Scope.tenant_id(scope))

  defp values(scope, company),
    do:
      Map.new(@fields, fn {field, {key, _, _, _}} ->
        {field, Settings.get(key, settings_scope(scope, company))}
      end)

  defp valid?({field, value}) when is_atom(field) do
    case Keyword.fetch(@fields, field) do
      {:ok, {_, nil, _, _}} when is_nil(value) -> true
      {:ok, {_, _, min, max}} -> is_integer(value) and value in min..max
      _ -> false
    end
  end

  defp valid?(_), do: false
end
