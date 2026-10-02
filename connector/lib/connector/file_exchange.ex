defmodule Bilimbi.PeopleConnector.Connector.FileExchange do
  @moduledoc """
  Operator file exchange of native Connector directory snapshots.

  Imports are validated review documents, not a provider transport or a restore
  operation. They never advance a checkpoint or write People/projection rows.
  Content replay is scoped to a connection and direction. Base Artifacts owns
  private bytes and installation retention policy; receipts retain provenance.
  """
  import Ecto.Query
  alias Bilimbi.Base.{Artifacts, Audit, Authz, Repo, Settings, Tenancy}
  alias Bilimbi.Base.Settings.Scope, as: SettingsScope
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.PeopleConnector.Connector
  alias Bilimbi.PeopleConnector.Connector.{Connection, Providers, WorkforceRecord}
  alias Bilimbi.PeopleConnector.Connector.FileExchange.{Owner, Record}

  @format "people-directory-v1"
  @policy [
    enabled: {"people-connector.files.enabled", :boolean, nil, nil},
    max_bytes: {"people-connector.files.max_bytes", :integer, 1, 10_485_760},
    max_records: {"people-connector.files.max_records", :integer, 1, 100_000},
    json_enabled: {"people-connector.files.json_enabled", :boolean, nil, nil}
  ]
  @record_keys ~w(kind source_id stable_id workforce_company_id name code email supervisor_stable_id observed_at active)
  @envelope_keys ~w(format tenant_id platform_company_id workforce_source_id workforce_company_id records)

  defp policy(scope, company) do
    settings_scope = SettingsScope.company(company, Scope.tenant_id(scope))
    Map.new(@policy, fn {field, {key, _, _, _}} -> {field, Settings.get(key, settings_scope)} end)
  end

  def summary(scope, company) do
    with :ok <- authorize(scope, company) do
      records =
        query(scope, company)
        |> order_by(desc: :inserted_at, desc: :id)
        |> limit(20)
        |> Repo.all()

      {:ok, %{policy: policy(scope, company), records: Enum.map(records, &present/1)}}
    end
  end

  def configure(scope, company, values) when is_map(values) do
    valid? =
      Enum.all?(values, fn {field, value} ->
        case if(is_atom(field), do: Keyword.fetch(@policy, field), else: :error) do
          {:ok, {_, :boolean, _, _}} -> is_boolean(value)
          {:ok, {_, :integer, min, max}} -> is_integer(value) and value >= min and value <= max
          _ -> false
        end
      end)

    with :ok <- authorize(scope, company),
         true <- valid? do
      Repo.transaction(fn ->
        for {field, value} <- values do
          {key, _, _, _} = Keyword.fetch!(@policy, field)

          case Settings.put(key, value, SettingsScope.company(company, Scope.tenant_id(scope))) do
            {:ok, _} -> :ok
            _ -> Repo.rollback(:invalid_file_policy)
          end
        end

        audit!(scope, company, "people-connector.files.policy", %{})
        policy(scope, company)
      end)
    else
      false -> {:error, :invalid_file_policy}
      error -> error
    end
  end

  def configure(_, _, _), do: {:error, :invalid_file_policy}

  def import_file(scope, company, bytes) when is_binary(bytes) do
    with {:ok, status} <- gate(scope, company),
         :ok <- check_size(scope, company, bytes),
         {:ok, envelope} <- decode_file(bytes),
         :ok <- validate(scope, status, envelope) do
      store(scope, status, :import, bytes, length(envelope["records"]))
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_file}
      error -> error
    end
  end

  def import_file(_, _, _), do: {:error, :invalid_file}

  def export_file(scope, company) do
    with {:ok, status} <- gate(scope, company),
         {:ok, %{freshness: :current, value: records}} <- Connector.workforce(scope, company),
         true <- length(records) <= policy(scope, company).max_records do
      envelope = %{
        format: @format,
        tenant_id: Scope.tenant_id(scope),
        platform_company_id: company,
        workforce_source_id: status.workforce_source_id,
        workforce_company_id: status.workforce_company_id,
        records: Enum.map(records, &encode_record/1)
      }

      bytes = Jason.encode!(envelope)

      with :ok <- check_size(scope, company, bytes),
           do: store(scope, status, :export, bytes, length(records))
    else
      false -> {:error, :too_many_records}
      {:ok, _} -> {:error, :directory_unavailable}
      error -> error
    end
  end

  def download(scope, company, id) do
    with :ok <- authorize(scope, company),
         {:ok, row} <- fetch(scope, company, id),
         true <- row.state == :ready,
         {:ok, document} <- Artifacts.read(scope, company, Owner, row.artifact_id) do
      {:ok, document}
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  # File-only retention; no cross-company doctor or recovery subsystem.
  def purge_expired(scope, company), do: Artifacts.purge_expired(scope, company, Owner)

  def authorize_artifact(scope, company, :purge, nil), do: authorize(scope, company)

  def authorize_artifact(scope, company, operation, %{subject: id, kind: "directory-file"}) do
    with :ok <- authorize(scope, company),
         {:ok, row} <- fetch(scope, company, id) do
      case operation do
        :delete -> :ok
        :create -> authorize_current(scope, company, row, :pending)
        :read -> authorize_current(scope, company, row, :ready)
        _ -> {:error, :unauthorized}
      end
    end
  end

  def authorize_artifact(_, _, _, _), do: {:error, :unauthorized}

  defp authorize_current(scope, company, row, state) do
    with {:ok, status} <- gate(scope, company),
         true <-
           row.state == state and matches?(row, status) and
             current_connection?(scope, company, row) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp gate(scope, company) do
    with :ok <- authorize(scope, company),
         {:ok, %{state: :enabled} = status} <- Connector.status(scope, company),
         true <- status.provider_id == Providers.native_id(),
         %{enabled: true, json_enabled: true} <- policy(scope, company) do
      {:ok, status}
    else
      {:error, _} = error -> error
      _ -> {:error, :file_exchange_disabled}
    end
  end

  defp authorize(scope, company) do
    with {:ok, actor} <- Authz.scope_actor(scope),
         {:ok, _} <-
           Company.authorize_company_target(actor, company, Connector.manage_capability()) do
      :ok
    else
      {:error, :no_authenticated_actor} -> {:error, :unauthorized}
      error -> error
    end
  end

  defp check_size(scope, company, bytes) do
    if byte_size(bytes) in 1..policy(scope, company).max_bytes,
      do: :ok,
      else: {:error, :file_too_large}
  end

  defp decode_file(bytes) do
    with {:ok, decoded} <- Jason.decode(bytes, objects: :ordered_objects),
         {:ok, normalized} <- normalize_json(decoded) do
      {:ok, normalized}
    end
  end

  defp normalize_json(%Jason.OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if length(Enum.uniq(keys)) == length(keys) do
      Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        case normalize_json(value) do
          {:ok, item} -> {:cont, {:ok, Map.put(acc, key, item)}}
          error -> {:halt, error}
        end
      end)
    else
      {:error, :invalid_file}
    end
  end

  defp normalize_json(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case normalize_json(value) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp normalize_json(value), do: {:ok, value}

  defp validate(scope, status, file) when is_map(file) do
    records = file["records"]

    valid? =
      Enum.sort(Map.keys(file)) == Enum.sort(@envelope_keys) and
        file["format"] == @format and file["tenant_id"] === Scope.tenant_id(scope) and
        file["platform_company_id"] === status.platform_company_id and
        file["workforce_source_id"] == status.workforce_source_id and
        file["workforce_company_id"] === status.workforce_company_id and
        is_list(records) and
        length(records) <= policy(scope, status.platform_company_id).max_records and
        Enum.all?(records, &valid_record?(&1, status)) and
        length(Enum.uniq_by(records, &{&1["kind"], &1["stable_id"]})) == length(records)

    if valid?, do: :ok, else: {:error, :invalid_file}
  end

  defp validate(_, _, _), do: {:error, :invalid_file}

  defp valid_record?(record, status) when is_map(record) do
    with true <- Enum.sort(Map.keys(record)) == Enum.sort(@record_keys),
         kind when kind in ["company", "employee"] <- record["kind"],
         timestamp when is_binary(timestamp) <- record["observed_at"],
         {:ok, observed, _} <- DateTime.from_iso8601(timestamp) do
      parsed = %WorkforceRecord{
        kind: if(kind == "company", do: :company, else: :employee),
        source_id: record["source_id"],
        stable_id: record["stable_id"],
        workforce_company_id: record["workforce_company_id"],
        name: record["name"],
        code: record["code"],
        email: record["email"],
        supervisor_stable_id: record["supervisor_stable_id"],
        observed_at: observed,
        active: record["active"]
      }

      WorkforceRecord.valid?(parsed) and parsed.source_id == status.workforce_source_id and
        parsed.workforce_company_id == status.workforce_company_id
    else
      _ -> false
    end
  end

  defp valid_record?(_, _), do: false

  defp encode_record(record) do
    record
    |> Map.from_struct()
    |> Map.update!(:kind, &Atom.to_string/1)
    |> Map.update!(:observed_at, &DateTime.to_iso8601/1)
  end

  defp store(scope, status, direction, bytes, count) do
    hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    case reserve(scope, status, direction, hash, count) do
      {:ok, {:existing, row}} -> {:ok, Map.put(present(row), :replayed?, true)}
      {:ok, {:new, row}} -> publish(scope, status, row, bytes)
      error -> error
    end
  end

  defp reserve(scope, status, direction, hash, count) do
    Repo.transaction(fn ->
      connection = lock_connection!(scope, status)

      existing =
        query(scope, status.platform_company_id)
        |> where(
          [r],
          r.connection_id == ^connection.id and r.direction == ^direction and r.sha256 == ^hash
        )
        |> Repo.one()

      case existing do
        %Record{state: :ready} = row ->
          audit!(scope, status.platform_company_id, "people-connector.files.replay", %{
            exchange_id: row.id
          })

          {:existing, row}

        %Record{state: :pending} ->
          Repo.rollback(:file_exchange_in_progress)

        row ->
          row =
            row ||
              %Record{
                tenant_id: Scope.tenant_id(scope),
                platform_company_id: status.platform_company_id,
                connection_id: connection.id,
                workforce_source_id: status.workforce_source_id,
                workforce_company_id: status.workforce_company_id,
                direction: direction,
                sha256: hash,
                record_count: count
              }

          row = row |> Ecto.Changeset.change(state: :pending) |> Repo.insert_or_update!()
          {:new, row}
      end
    end)
  end

  defp publish(scope, status, row, bytes) do
    # Artifacts must commit reservations/tombstones outside the receipt transaction.
    case Artifacts.put(
           scope,
           status.platform_company_id,
           Owner,
           %{subject: row.id, kind: "directory-file"},
           bytes,
           "application/json"
         ) do
      {:ok, artifact} ->
        result =
          Repo.transaction(fn ->
            connection = lock_connection!(scope, status)
            if connection.id != row.connection_id, do: Repo.rollback(:connection_changed)

            audit!(
              scope,
              status.platform_company_id,
              "people-connector.files.#{row.direction}",
              %{exchange_id: row.id, artifact_id: artifact.id, record_count: row.record_count}
            )

            row
            |> Ecto.Changeset.change(state: :ready, artifact_id: artifact.id)
            |> Repo.update!()
          end)

        case result do
          {:ok, ready} ->
            {:ok, Map.put(present(ready), :replayed?, false)}

          {:error, _} = error ->
            Artifacts.delete(scope, status.platform_company_id, Owner, artifact.id)
            fail(row)
            error
        end

      {:error, _} = error ->
        fail(row)
        error
    end
  end

  defp fail(row), do: row |> Ecto.Changeset.change(state: :failed) |> Repo.update!()

  defp lock_connection!(scope, status) do
    with {:ok, current} <- gate(scope, status.platform_company_id),
         true <-
           current.workforce_source_id == status.workforce_source_id and
             current.workforce_company_id == status.workforce_company_id,
         %Connection{} = connection <-
           Tenancy.scope_query(Connection, scope)
           |> where([c], c.platform_company_id == ^status.platform_company_id)
           |> lock("FOR UPDATE")
           |> Repo.one(),
         true <-
           connection.enabled and connection.provider_id == Providers.native_id() and
             matches?(connection, status) do
      connection
    else
      _ -> Repo.rollback(:connection_changed)
    end
  end

  defp current_connection?(scope, company, %{connection_id: id}) when is_integer(id) do
    Tenancy.scope_query(Connection, scope)
    |> where([c], c.platform_company_id == ^company and c.id == ^id)
    |> Repo.exists?()
  end

  defp current_connection?(_, _, _), do: false

  defp matches?(row, status),
    do:
      row.workforce_source_id == status.workforce_source_id and
        row.workforce_company_id == status.workforce_company_id

  defp query(scope, company),
    do: Tenancy.scope_query(Record, scope) |> where(platform_company_id: ^company)

  defp fetch(scope, company, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case query(scope, company) |> where(id: ^uuid) |> Repo.one() do
          nil -> {:error, :not_found}
          row -> {:ok, row}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp present(row),
    do: Map.take(row, [:id, :direction, :record_count, :state, :inserted_at, :artifact_id])

  defp audit!(scope, company, event, payload) do
    actor = Scope.actor(scope)

    case Audit.record_action(scope, %{
           company_id: company,
           actor_type: "user",
           actor_id: actor.user_id,
           impersonator_id: actor.impersonator_id,
           occurred_at: NaiveDateTime.utc_now(),
           event: event,
           payload: Map.put(payload, :result, "succeeded")
         }) do
      {:ok, _} -> :ok
      _ -> Repo.rollback(:audit_unavailable)
    end
  rescue
    _error in [Ecto.ConstraintError, Postgrex.Error] -> Repo.rollback(:audit_unavailable)
  end
end
