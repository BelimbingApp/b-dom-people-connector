defmodule Bilimbi.PeopleConnector.Connector.TestFixtures do
  @moduledoc false

  alias Bilimbi.Base.Repo
  alias Ecto.Adapters.SQL

  # Mirrors the owned migration so tests run without the shared migrated schema.
  def create_connection_tables! do
    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE IF NOT EXISTS people_connector_connections (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL,
        platform_company_id bigint NOT NULL, provider_id varchar(100) NOT NULL,
        provider_contract_version varchar(20) NOT NULL,
        workforce_source_id varchar(100) NOT NULL, workforce_company_id bigint NOT NULL,
        enabled boolean NOT NULL DEFAULT false,
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_connector_connections_platform_company_unique
          UNIQUE (platform_company_id),
        CONSTRAINT people_connector_connections_workforce_company_unique
          UNIQUE (tenant_id, workforce_source_id, workforce_company_id)
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    create_sync_tables!()
    create_webhook_tables!()
    create_file_tables!()
    create_retention_tables!()
    create_backup_tables!()
  end

  defp create_backup_tables! do
    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE IF NOT EXISTS people_connector_backups (
        id uuid PRIMARY KEY, tenant_id bigint NOT NULL, platform_company_id bigint NOT NULL,
        connection_id bigint REFERENCES people_connector_connections(id) ON DELETE SET NULL,
        sha256 varchar(64) NOT NULL, state varchar(10) NOT NULL,
        artifact_id uuid, expires_at timestamp(6) NOT NULL,
        preview_token_hash varchar(64), preview_state_hash varchar(64),
        preview_actor_id bigint, preview_impersonator_id bigint, preview_expires_at timestamp(6),
        recovery_generation integer, restored_at timestamp(6),
        purge_attempts integer NOT NULL, purge_last_error varchar(255),
        purge_attempted_at timestamp(6), purge_held_at timestamp(6),
        inserted_at timestamp(6) NOT NULL, updated_at timestamp(6) NOT NULL,
        CONSTRAINT people_connector_backups_state CHECK
          (state IN ('pending','ready','failed','purged') AND
           (state NOT IN ('ready','purged') OR artifact_id IS NOT NULL))
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      "CREATE INDEX IF NOT EXISTS people_connector_backups_tenant_id_platform_company_id_expires_ ON people_connector_backups (tenant_id, platform_company_id, expires_at)",
      []
    )
  end

  defp create_retention_tables! do
    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE IF NOT EXISTS people_connector_retention_attempts (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, platform_company_id bigint NOT NULL,
        kind varchar(10) NOT NULL CHECK (kind IN ('sync', 'webhook', 'nonce', 'file')),
        record_id varchar(36) NOT NULL, attempted_at timestamp(6) NOT NULL,
        CONSTRAINT people_connector_retention_attempts_identity UNIQUE (platform_company_id, kind, record_id)
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )
  end

  defp create_file_tables! do
    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE IF NOT EXISTS people_connector_file_exchanges (
        id uuid PRIMARY KEY, tenant_id bigint NOT NULL, platform_company_id bigint NOT NULL,
        connection_id bigint REFERENCES people_connector_connections(id) ON DELETE SET NULL,
        workforce_source_id varchar(100) NOT NULL, workforce_company_id bigint NOT NULL,
        direction varchar(10) NOT NULL, sha256 varchar(64) NOT NULL, record_count integer NOT NULL,
        state varchar(10) NOT NULL, artifact_id uuid, expires_at timestamp(6),
        failure_reason varchar(20),
        inserted_at timestamp(6) NOT NULL, updated_at timestamp(6) NOT NULL,
        CONSTRAINT people_connector_file_exchange_values CHECK (
          direction IN ('import', 'export') AND state IN ('pending', 'ready', 'failed') AND
          record_count >= 0 AND workforce_company_id > 0 AND
          (state <> 'ready' OR (artifact_id IS NOT NULL AND expires_at IS NOT NULL)) AND
          (failure_reason IS NULL OR (state = 'failed' AND failure_reason = 'stale')))
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE UNIQUE INDEX IF NOT EXISTS people_connector_file_exchanges_pending_unique
        ON people_connector_file_exchanges (connection_id, direction, sha256)
        WHERE state = 'pending'
      """,
      []
    )
  end

  defp create_webhook_tables! do
    for {table, identity, extra} <- [
          {"people_connector_webhook_deliveries", "delivery_hash",
           "body_hash varchar(64) NOT NULL,"},
          {"people_connector_webhook_nonces", "nonce_hash", ""}
        ] do
      SQL.query!(
        Repo,
        """
        CREATE TEMPORARY TABLE IF NOT EXISTS #{table} (
          id bigserial PRIMARY KEY, tenant_id bigint NOT NULL,
          connection_id bigint NOT NULL REFERENCES people_connector_connections(id) ON DELETE CASCADE,
          #{identity} varchar(64) NOT NULL, #{extra}
          received_at timestamp NOT NULL,
          CONSTRAINT #{table}_identity_unique UNIQUE (connection_id, #{identity})
        ) ON COMMIT PRESERVE ROWS
        """,
        []
      )
    end
  end

  defp create_sync_tables! do
    for statement <- [
          """
          CREATE TEMPORARY TABLE IF NOT EXISTS people_connector_sync_checkpoints (
            id bigserial PRIMARY KEY, tenant_id bigint NOT NULL,
            connection_id bigint NOT NULL
              REFERENCES people_connector_connections(id) ON DELETE CASCADE,
            version bigint NOT NULL CHECK (version > 0), resume_cursor varchar(1000),
            as_of_at timestamp NOT NULL,
            inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
            CONSTRAINT people_connector_sync_checkpoints_connection_unique UNIQUE (connection_id)
          ) ON COMMIT PRESERVE ROWS
          """,
          """
          CREATE TEMPORARY TABLE IF NOT EXISTS people_connector_sync_runs (
            id bigserial PRIMARY KEY, tenant_id bigint NOT NULL,
            connection_id bigint NOT NULL
              REFERENCES people_connector_connections(id) ON DELETE CASCADE,
            platform_company_id bigint NOT NULL, provider_id varchar(100) NOT NULL,
            idempotency_key varchar(100) NOT NULL,
            pass varchar(20) NOT NULL CHECK (pass IN ('bootstrap', 'incremental')),
            state varchar(20) NOT NULL CHECK (state IN
              ('running', 'succeeded', 'stale', 'unavailable', 'refused', 'failed', 'unknown')),
            reason varchar(60), checkpoint_version bigint, as_of_at timestamp,
            applied integer NOT NULL DEFAULT 0, unchanged integer NOT NULL DEFAULT 0,
            superseded integer NOT NULL DEFAULT 0, deactivated integer NOT NULL DEFAULT 0,
            refused integer NOT NULL DEFAULT 0,
            started_at timestamp NOT NULL, finished_at timestamp,
            inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
            CONSTRAINT people_connector_sync_runs_idempotency_unique
              UNIQUE (connection_id, idempotency_key)
          ) ON COMMIT PRESERVE ROWS
          """,
          """
          CREATE UNIQUE INDEX IF NOT EXISTS people_connector_sync_runs_one_running
            ON people_connector_sync_runs (connection_id) WHERE state = 'running'
          """,
          """
          CREATE TEMPORARY TABLE IF NOT EXISTS people_connector_workforce_records (
            id bigserial PRIMARY KEY, tenant_id bigint NOT NULL,
            connection_id bigint NOT NULL
              REFERENCES people_connector_connections(id) ON DELETE CASCADE,
            kind varchar(20) NOT NULL CHECK (kind IN ('company', 'employee', 'position')),
            source_id varchar(100) NOT NULL, stable_id varchar(100) NOT NULL,
            workforce_company_id bigint NOT NULL, active boolean NOT NULL,
            name varchar(255) NOT NULL, code varchar(100) NOT NULL, email varchar(255),
            supervisor_stable_id varchar(100), parent_stable_id varchar(100),
            version integer, vacant boolean, assignments_incomplete boolean,
            assignments jsonb[] NOT NULL DEFAULT ARRAY[]::jsonb[], content_hash varchar(64) NOT NULL,
            observed_at timestamp NOT NULL, deactivated_at timestamp,
            inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
            CONSTRAINT people_connector_workforce_records_identity_unique
              UNIQUE (connection_id, kind, source_id, stable_id)
          ) ON COMMIT PRESERVE ROWS
          """,
          """
          CREATE TEMPORARY TABLE IF NOT EXISTS people_connector_reconciliation_issues (
            id bigserial PRIMARY KEY, tenant_id bigint NOT NULL,
            connection_id bigint NOT NULL
              REFERENCES people_connector_connections(id) ON DELETE CASCADE,
            issue_key varchar(200) NOT NULL, kind varchar(40) NOT NULL,
            reason varchar(60) NOT NULL, severity varchar(10) NOT NULL,
            record_kind varchar(20), stable_id varchar(100),
            status varchar(10) NOT NULL, occurrences integer NOT NULL DEFAULT 1,
            first_seen_at timestamp NOT NULL, last_seen_at timestamp NOT NULL,
            resolved_at timestamp,
            inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
            CONSTRAINT people_connector_reconciliation_issues_key_unique
              UNIQUE (connection_id, issue_key),
            CONSTRAINT people_connector_reconciliation_issues_status
              CHECK (status IN ('open', 'resolved') AND severity IN ('warning', 'error'))
          ) ON COMMIT PRESERVE ROWS
          """
        ] do
      SQL.query!(Repo, statement, [])
    end
  end

  @doc "Stores a row directly, as an earlier mapping or another company's claim would."
  def insert_connection!(attributes) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    SQL.query!(
      Repo,
      """
      INSERT INTO people_connector_connections
        (tenant_id, platform_company_id, provider_id, provider_contract_version,
         workforce_source_id, workforce_company_id, enabled, inserted_at, updated_at)
      VALUES ($1, $2, $3, '1.0.0', 'people/native', $4, $5, $6, $6)
      RETURNING id
      """,
      [
        Map.fetch!(attributes, :tenant_id),
        Map.fetch!(attributes, :platform_company_id),
        Map.get(attributes, :provider_id, "people.native"),
        Map.fetch!(attributes, :workforce_company_id),
        Map.get(attributes, :enabled, false),
        now
      ]
    )
  end

  @doc "Moves a run's start back, as a pass that stopped long ago would look."
  def age_run!(idempotency_key, minutes) do
    SQL.query!(
      Repo,
      "UPDATE people_connector_sync_runs SET started_at = started_at - make_interval(mins => $2) WHERE idempotency_key = $1",
      [idempotency_key, minutes]
    )
  end

  @doc "Moves a checkpoint's provider watermark back."
  def age_checkpoint!(minutes) do
    SQL.query!(
      Repo,
      "UPDATE people_connector_sync_checkpoints SET as_of_at = as_of_at - make_interval(mins => $1)",
      [minutes]
    )
  end
end

defmodule Bilimbi.PeopleConnector.Connector.TestAdapter do
  @moduledoc """
  A read-port adapter driven by the calling process: it reports each request
  to that process and answers with the function stored under `:pages`.
  """

  @behaviour Bilimbi.PeopleConnector.Connector.ReadPort

  @impl true
  def read(%{capability: "organization_directory"}, _request) do
    {:ok,
     %Bilimbi.PeopleConnector.Connector.Page{
       entries: [],
       as_of: DateTime.utc_now(),
       snapshot: true
     }}
  end

  def read(authorization, request) do
    send(self(), {:port_read, authorization, request})
    Process.get(:people_connector_test_pages).(request)
  end

  def serve(fun) when is_function(fun, 1), do: Process.put(:people_connector_test_pages, fun)
end
