defmodule Bilimbi.PeopleConnector.Connector.Backup do
  @moduledoc """
  Operator backups of native connections, stored privately by Base Artifacts.
  Secrets, audit history, sync outcomes and replay guards are never restored.
  Restore is once per backup, after an actor-bound, state-bound preview. Recovery
  uses the restored checkpoint through the ordinary idempotent sync engine.
  """
  import Ecto.Query
  alias Bilimbi.Base.{Artifacts, Repo, Settings, Tenancy}
  alias Bilimbi.Base.Settings.Scope, as: SettingsScope
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.PeopleConnector.Connector
  alias Bilimbi.PeopleConnector.Connector.{Adapters, Connection, Operations, Providers, SyncRun}
  alias Bilimbi.PeopleConnector.Connector.Backup.{Owner, Record}
  alias Bilimbi.PeopleConnector.Connector.Sync.{Checkpoint, Projection}

  @connection_fields ~w(provider_id provider_contract_version workforce_source_id workforce_company_id enabled)a
  @checkpoint_fields ~w(version resume_cursor as_of_at)a
  @projection_fields ~w(kind source_id stable_id workforce_company_id active name code email supervisor_stable_id content_hash observed_at deactivated_at)a
  @setting_keys ~w(people-connector.sync.page_limit people-connector.sync.max_age_minutes people-connector.sync.run_timeout_minutes people-connector.files.enabled people-connector.files.json_enabled people-connector.files.max_bytes people-connector.files.max_records people-connector.files.stale_minutes people-connector.webhook.max_skew_seconds people-connector.webhook.enabled)
  @fields [
    retention_days: {"people-connector.backup.retention_days", 30, 1, 3650},
    preview_minutes: {"people-connector.backup.preview_minutes", 10, 1, 60}
  ]
  def fields, do: @fields

  def summary(%Scope{} = scope, company) do
    with {:ok, company} <- Operations.authorize(scope, company) do
      rows =
        query(scope, company)
        |> order_by(desc: :inserted_at, desc: :id)
        |> limit(20)
        |> Repo.all()

      {:ok, %{policy: policy(scope, company), records: Enum.map(rows, &present/1)}}
    end
  end

  def configure(%Scope{} = scope, company, values) when is_map(values) do
    with {:ok, company} <- Operations.authorize(scope, company),
         true <-
           Enum.all?(values, fn {field, value} ->
             case if(is_atom(field), do: Keyword.fetch(@fields, field), else: :error) do
               {:ok, {_, _, min, max}} -> is_integer(value) and value >= min and value <= max
               _ -> false
             end
           end) do
      Operations.transaction(fn ->
        for {field, value} <- values do
          {key, _, _, _} = Keyword.fetch!(@fields, field)
          put_setting!(scope, company, key, value)
        end

        Operations.audit!(scope, company, "people-connector.backup.policy", %{})
        policy(scope, company)
      end)
    else
      false -> {:error, :invalid_backup_policy}
      error -> error
    end
  end

  def create(%Scope{} = scope, company) do
    with {:ok, company} <- Operations.authorize(scope, company),
         {:ok, {row, bytes}} <-
           Operations.transaction(fn ->
             connection = lock_connection!(scope, company)
             require_idle!(connection)
             bytes = snapshot(scope, connection) |> Jason.encode!()

             row =
               %Record{
                 tenant_id: Scope.tenant_id(scope),
                 platform_company_id: company,
                 connection_id: connection.id,
                 sha256: digest(bytes),
                 expires_at:
                   DateTime.add(DateTime.utc_now(), policy(scope, company).retention_days, :day)
               }
               |> Repo.insert!()

             Operations.audit!(scope, company, "people-connector.backup.reserved", %{
               backup_id: row.id
             })

             {row, bytes}
           end) do
      publish(scope, company, row, bytes)
    end
  end

  # Artifact IO must be outside the owner's transaction: Base commits its own
  # reservations and tombstones. Publication failure leaves a failed receipt.
  defp publish(scope, company, row, bytes) do
    case Artifacts.put(
           scope,
           company,
           Owner,
           %{subject: row.id, kind: "connection-backup"},
           bytes,
           "application/json"
         ) do
      {:ok, artifact} ->
        result =
          Operations.transaction(fn ->
            Operations.audit!(scope, company, "people-connector.backup.created", %{
              backup_id: row.id,
              artifact_id: artifact.id
            })

            row
            |> Ecto.Changeset.change(
              state: :ready,
              artifact_id: artifact.id,
              expires_at: earlier(row.expires_at, artifact.expires_at)
            )
            |> Repo.update!()
            |> present()
          end)

        case result do
          {:ok, _} ->
            result

          error ->
            Artifacts.delete(scope, company, Owner, artifact.id)
            fail(row)
            error
        end

      error ->
        fail(row)
        error
    end
  end

  def preview(%Scope{} = scope, company, id) do
    with {:ok, company} <- Operations.authorize(scope, company),
         {:ok, row, document} <- read_backup(scope, company, id) do
      Operations.transaction(fn ->
        connection = lock_connection!(scope, company)
        require_idle!(connection)
        validate!(row, document, connection)
        row = fetch!(scope, company, id, true)
        if row.restored_at, do: Repo.rollback(:already_restored)
        token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
        actor = Scope.actor(scope)
        current = snapshot(scope, connection)

        row
        |> Ecto.Changeset.change(
          preview_token_hash: digest(token),
          preview_state_hash: state_hash(current),
          preview_actor_id: actor.user_id,
          preview_impersonator_id: actor.impersonator_id,
          preview_expires_at:
            DateTime.add(DateTime.utc_now(), policy(scope, company).preview_minutes, :minute)
        )
        |> Repo.update!()

        Operations.audit!(scope, company, "people-connector.backup.previewed", %{
          backup_id: row.id
        })

        %{id: row.id, token: token, changes: changes(current, document)}
      end)
    end
  end

  def restore(%Scope{} = scope, company, id, token, confirmed)
      when is_binary(token) and confirmed == true do
    with {:ok, company} <- Operations.authorize(scope, company),
         {:ok, row, document} <- read_backup(scope, company, id) do
      Operations.transaction(fn ->
        connection = lock_connection!(scope, company)
        row = fetch!(scope, company, row.id, true)
        validate!(row, document, connection)
        actor = Scope.actor(scope)

        unless row.preview_token_hash == digest(token) and row.preview_actor_id == actor.user_id and
                 row.preview_impersonator_id == actor.impersonator_id,
               do: Repo.rollback(:invalid_confirmation)

        if row.restored_at do
          Operations.audit!(scope, company, "people-connector.backup.restore_replayed", %{
            backup_id: row.id
          })

          %{id: row.id, restored_at: row.restored_at, replayed?: true}
        else
          require_idle!(connection)

          unless row.preview_expires_at &&
                   DateTime.before?(DateTime.utc_now(), row.preview_expires_at),
                 do: Repo.rollback(:preview_expired)

          unless row.preview_state_hash == state_hash(snapshot(scope, connection)),
            do: Repo.rollback(:preview_changed)

          generation = apply_snapshot!(scope, connection, document)

          restored =
            row
            |> Ecto.Changeset.change(
              restored_at: DateTime.utc_now(),
              recovery_generation: generation
            )
            |> Repo.update!()

          Operations.audit!(scope, company, "people-connector.backup.restored", %{
            backup_id: row.id
          })

          %{id: row.id, restored_at: restored.restored_at, replayed?: false}
        end
      end)
    end
  end

  def restore(%Scope{}, _, _, _, _), do: {:error, :confirmation_required}

  def recover(%Scope{} = scope, company, id) do
    with {:ok, company} <- Operations.authorize(scope, company),
         {:ok, generation} <-
           Operations.transaction(fn ->
             connection = lock_connection!(scope, company)
             row = fetch!(scope, company, id)

             unless row.restored_at && row.connection_id == connection.id,
               do: Repo.rollback(:restore_required)

             Operations.audit!(scope, company, "people-connector.backup.recovery_requested", %{
               backup_id: row.id
             })

             row.recovery_generation
           end) do
      Connector.synchronise(
        scope,
        company,
        Providers.installed(),
        Adapters.installed(),
        "recovery:" <> id,
        expected_checkpoint_version: generation
      )
    end
  end

  def purge_expired(%Scope{} = scope, company) do
    with {:ok, company} <- Operations.authorize(scope, company) do
      rows =
        query(scope, company)
        |> where([r], r.state == :ready and r.expires_at <= ^DateTime.utc_now())
        |> order_by([:expires_at, :id])
        |> limit(^Settings.get("artifacts.purge_batch_size"))
        |> Repo.all()

      results =
        Enum.map(rows, fn row ->
          result = Artifacts.delete(scope, company, Owner, row.artifact_id)

          if result == {:ok, :deleted},
            do: row |> Ecto.Changeset.change(state: :purged) |> Repo.update!()

          {row.id, result}
        end)

      {:ok,
       %{
         deleted: for({id, {:ok, :deleted}} <- results, do: id),
         errors: for({id, {:error, reason}} <- results, do: {id, reason})
       }}
    end
  end

  def authorize_artifact(%Scope{} = scope, company, :purge, nil) do
    case Operations.authorize(scope, company) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  def authorize_artifact(%Scope{} = scope, company, operation, %{
        subject: id,
        kind: "connection-backup"
      }) do
    with {:ok, company} <- Operations.authorize(scope, company),
         {:ok, row} <- fetch(scope, company, id) do
      case operation do
        :delete -> :ok
        :create -> if(row.state == :pending and live?(row), do: :ok, else: {:error, :not_found})
        :read -> if(row.state == :ready and live?(row), do: :ok, else: {:error, :not_found})
        _ -> {:error, :unauthorized}
      end
    end
  end

  def authorize_artifact(_, _, _, _), do: {:error, :unauthorized}

  defp read_backup(scope, company, id) do
    with {:ok, row} <- fetch(scope, company, id),
         true <- row.state == :ready and live?(row),
         {:ok, %{bytes: bytes}} <- Artifacts.read(scope, company, Owner, row.artifact_id),
         true <- digest(bytes) == row.sha256,
         {:ok, document} <- Jason.decode(bytes),
         true <- is_map(document) do
      {:ok, row, document}
    else
      false -> {:error, :invalid_backup}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_backup}
      error -> error
    end
  end

  defp snapshot(scope, connection) do
    checkpoint = scoped_rows(Checkpoint, scope, connection.id) |> Repo.one()

    projections =
      scoped_rows(Projection, scope, connection.id)
      |> order_by([p], [p.kind, p.source_id, p.stable_id])
      |> Repo.all()

    %{
      format: "people-connection-backup-v1",
      tenant_id: Scope.tenant_id(scope),
      platform_company_id: connection.platform_company_id,
      connection_id: connection.id,
      connection: Map.take(connection, @connection_fields),
      checkpoint: checkpoint && Map.take(checkpoint, @checkpoint_fields),
      projections: Enum.map(projections, &Map.take(&1, @projection_fields)),
      settings:
        Map.new(
          @setting_keys,
          &{&1, Settings.get(&1, settings_scope(scope, connection.platform_company_id))}
        )
    }
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp validate!(row, document, connection) do
    unless row.connection_id == connection.id and
             document["format"] == "people-connection-backup-v1" and
             document["tenant_id"] === connection.tenant_id and
             document["platform_company_id"] === connection.platform_company_id and
             document["connection_id"] === connection.id and
             Enum.all?(
               [
                 "provider_id",
                 "provider_contract_version",
                 "workforce_source_id",
                 "workforce_company_id"
               ],
               &(document["connection"][&1] ===
                   Map.fetch!(connection, String.to_existing_atom(&1)))
             ),
           do: Repo.rollback(:connection_changed)

    unless is_boolean(document["connection"]["enabled"]) and is_list(document["projections"]) and
             Enum.sort(Map.keys(document["settings"])) == Enum.sort(@setting_keys),
           do: Repo.rollback(:invalid_backup)
  end

  defp apply_snapshot!(scope, connection, document) do
    connection
    |> Connection.changeset(%{enabled: document["connection"]["enabled"]})
    |> Repo.update!()

    for {key, value} <- document["settings"],
        key != "people-connector.webhook.enabled",
        do: put_setting!(scope, connection.platform_company_id, key, value)

    # Excluded secrets must be re-entered using the existing Base UI secret input.
    for key <- [Connector.credential_key(), "people-connector.webhook.secret"] do
      :ok = Settings.delete(key, settings_scope(scope, connection.platform_company_id))
    end

    put_setting!(scope, connection.platform_company_id, "people-connector.webhook.enabled", false)
    # Never roll checkpoint versions backwards: running/late syncs compare this
    # generation. Cursor and as-of restore; the generation is newly allocated.
    old = scoped_rows(Checkpoint, scope, connection.id) |> Repo.one()

    generation =
      max((old && old.version) || 0, get_in(document, ["checkpoint", "version"]) || 0) + 1

    Repo.delete_all(scoped_rows(Checkpoint, scope, connection.id))
    Repo.delete_all(scoped_rows(Projection, scope, connection.id))

    if document["checkpoint"] do
      %Checkpoint{tenant_id: connection.tenant_id, connection_id: connection.id}
      |> Checkpoint.changeset(
        decode_fields(document["checkpoint"], @checkpoint_fields)
        |> Map.put(:version, generation)
      )
      |> Repo.insert!()
    end

    for projection <- document["projections"] do
      %Projection{tenant_id: connection.tenant_id, connection_id: connection.id}
      |> Projection.changeset(decode_fields(projection, @projection_fields))
      |> Repo.insert!()
    end

    if document["checkpoint"], do: generation, else: 0
  end

  defp decode_fields(document, fields) do
    Map.new(fields, fn field ->
      value = document[Atom.to_string(field)]

      value =
        cond do
          field in [:as_of_at, :observed_at, :deactivated_at] and value != nil ->
            case DateTime.from_iso8601(value) do
              {:ok, at, _} -> at
              _ -> Repo.rollback(:invalid_backup)
            end

          field == :kind and value == "company" ->
            :company

          field == :kind and value == "employee" ->
            :employee

          true ->
            value
        end

      {field, value}
    end)
  end

  defp lock_connection!(scope, company) do
    connection =
      Tenancy.scope_query(Connection, scope)
      |> where(platform_company_id: ^company)
      |> lock("FOR UPDATE")
      |> Repo.one()

    with %Connection{provider_id: provider} <- connection,
         true <- provider == Providers.native_id(),
         {:ok, status} <- Connector.status(scope, company),
         true <-
           status.workforce_source_id == connection.workforce_source_id and
             status.workforce_company_id == connection.workforce_company_id do
      connection
    else
      _ -> Repo.rollback(:connection_unavailable)
    end
  end

  defp require_idle!(connection) do
    if Repo.exists?(
         from(r in SyncRun, where: r.connection_id == ^connection.id and r.state == :running)
       ),
       do: Repo.rollback(:sync_in_progress)
  end

  defp changes(current, saved) do
    directory_changes = projection_changes(current["projections"], saved["projections"])

    [
      %{
        label: "Connection enabled",
        before: current["connection"]["enabled"],
        after: saved["connection"]["enabled"]
      },
      %{
        label: "Checkpoint generation",
        before: get_in(current, ["checkpoint", "version"]),
        after:
          if(saved["checkpoint"],
            do:
              max(
                get_in(current, ["checkpoint", "version"]) || 0,
                get_in(saved, ["checkpoint", "version"])
              ) + 1,
            else: nil
          )
      },
      %{
        label: "Checkpoint time",
        before: preview_value("observed_at", get_in(current, ["checkpoint", "as_of_at"])),
        after: preview_value("observed_at", get_in(saved, ["checkpoint", "as_of_at"]))
      },
      %{
        label: "Directory records",
        before: length(current["projections"]),
        after: length(saved["projections"])
      }
    ] ++
      directory_changes ++
      (Enum.reject(@setting_keys, &(&1 == "people-connector.webhook.enabled"))
       |> Enum.map(
         &%{
           label: setting_label(&1),
           before: current["settings"][&1],
           after: saved["settings"][&1]
         }
       )) ++
      [
        %{
          label: "Credentials and webhook secret",
          before: "Excluded",
          after: "Cleared; re-enter on People connections"
        },
        %{
          label: "Webhook intake",
          before: current["settings"]["people-connector.webhook.enabled"],
          after: false
        }
      ]
  end

  defp setting_label("people-connector.sync.page_limit"), do: "Sync page size"
  defp setting_label("people-connector.sync.max_age_minutes"), do: "Sync maximum age (minutes)"
  defp setting_label("people-connector.sync.run_timeout_minutes"), do: "Sync timeout (minutes)"
  defp setting_label("people-connector.files.enabled"), do: "File exchange"
  defp setting_label("people-connector.files.json_enabled"), do: "JSON file exchange"
  defp setting_label("people-connector.files.max_bytes"), do: "File size limit (bytes)"
  defp setting_label("people-connector.files.max_records"), do: "File record limit"
  defp setting_label("people-connector.files.stale_minutes"), do: "File pending timeout (minutes)"

  defp setting_label("people-connector.webhook.max_skew_seconds"),
    do: "Webhook signing window (seconds)"

  defp setting_label("people-connector.webhook.enabled"),
    do: "Saved webhook intake (restore disables it)"

  defp projection_changes(current, saved) do
    identity = &{&1["kind"], &1["source_id"], &1["stable_id"]}
    current = Map.new(current, &{identity.(&1), &1})
    saved = Map.new(saved, &{identity.(&1), &1})

    (Map.keys(current) ++ Map.keys(saved))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn {kind, _, stable_id} = key ->
      before = Map.get(current, key)
      after_value = Map.get(saved, key)

      for {field, title} <- [
            {"name", "Name"},
            {"code", "Code"},
            {"email", "Email"},
            {"supervisor_stable_id", "Supervisor reference"},
            {"active", "Active"},
            {"observed_at", "Observed"},
            {"deactivated_at", "Deactivated"}
          ],
          current_value <- [before && before[field]],
          saved_value <- [after_value && after_value[field]],
          current_value != saved_value do
        %{
          label: "#{kind} #{stable_id} · #{title}",
          before: preview_value(field, current_value),
          after: preview_value(field, saved_value)
        }
      end
    end)
  end

  defp preview_value(field, value)
       when field in ["observed_at", "deactivated_at"] and not is_nil(value) do
    {:ok, at, _} = DateTime.from_iso8601(value)
    at
  end

  defp preview_value(_, value), do: value

  defp state_hash(value), do: value |> :erlang.term_to_binary([:deterministic]) |> digest()
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp live?(row), do: DateTime.before?(DateTime.utc_now(), row.expires_at)
  defp earlier(a, b), do: if(DateTime.before?(a, b), do: a, else: b)

  defp query(scope, company),
    do: Tenancy.scope_query(Record, scope) |> where(platform_company_id: ^company)

  defp scoped_rows(schema, scope, connection),
    do: Tenancy.scope_query(schema, scope) |> where(connection_id: ^connection)

  defp fetch(scope, company, id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Record{} = row <- query(scope, company) |> where(id: ^uuid) |> Repo.one(),
         do: {:ok, row},
         else: (_ -> {:error, :not_found})
  end

  defp fetch!(scope, company, id, locked \\ false) do
    with {:ok, uuid} <- Ecto.UUID.cast(id) do
      query = query(scope, company) |> where(id: ^uuid)
      row = if(locked, do: lock(query, "FOR UPDATE"), else: query) |> Repo.one()
      row || Repo.rollback(:not_found)
    else
      _ -> Repo.rollback(:not_found)
    end
  end

  defp fail(row), do: row |> Ecto.Changeset.change(state: :failed) |> Repo.update!()

  defp present(row),
    do:
      Map.take(row, [:id, :artifact_id, :inserted_at, :expires_at, :restored_at])
      |> Map.put(:state, if(row.state == :purged or live?(row), do: row.state, else: :expired))

  defp policy(scope, company),
    do:
      Map.new(@fields, fn {field, {key, _, _, _}} ->
        {field, Settings.get(key, settings_scope(scope, company))}
      end)

  defp settings_scope(scope, company), do: SettingsScope.company(company, Scope.tenant_id(scope))

  defp put_setting!(scope, company, key, value) do
    case Settings.put(key, value, settings_scope(scope, company)) do
      {:ok, _} -> :ok
      _ -> Repo.rollback(:settings_unavailable)
    end
  end
end
