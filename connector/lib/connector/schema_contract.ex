defmodule Bilimbi.PeopleConnector.Connector.SchemaContract do
  @moduledoc """
  Fresh Bilimbi-only connection, sync, webhook, file and retention structures.

  Verify after migration, alongside Backup.SchemaContract. Check expressions
  and partial predicates use PostgreSQL's canonical forms, not migration SQL.
  Platform company IDs and Workforce company IDs are separate axes; connection
  ownership and replay identities are checked by verify_invariants/2.
  """
  @behaviour Bilimbi.Base.Database.SchemaContract

  alias Bilimbi.Base.Database.SchemaVerifier
  alias Ecto.Adapters.SQL

  @impl true
  def tables do
    [
      %{
        name: "people_connector_connections",
        columns: %{
          "enabled" => %{default: {:boolean, false}, type: :boolean, nullable: false},
          "id" => %{
            default: {:sequence, "people_connector_connections_id_seq"},
            type: :bigint,
            nullable: false
          },
          "inserted_at" => %{default: nil, type: {:timestamp, 0}, nullable: false},
          "platform_company_id" => %{default: nil, type: :bigint, nullable: false},
          "provider_contract_version" => %{default: nil, type: {:varchar, 20}, nullable: false},
          "provider_id" => %{default: nil, type: {:varchar, 100}, nullable: false},
          "tenant_id" => %{default: nil, type: :bigint, nullable: false},
          "updated_at" => %{default: nil, type: {:timestamp, 0}, nullable: false},
          "workforce_company_id" => %{default: nil, type: :bigint, nullable: false},
          "workforce_source_id" => %{default: nil, type: {:varchar, 100}, nullable: false}
        },
        indexes: %{
          "people_connector_connections_pkey" => %{where: nil, columns: ["id"], unique: true},
          "people_connector_connections_platform_company_unique" => %{
            where: nil,
            columns: ["platform_company_id"],
            unique: true
          },
          "people_connector_connections_workforce_company_unique" => %{
            where: nil,
            columns: ["tenant_id", "workforce_source_id", "workforce_company_id"],
            unique: true
          }
        },
        foreign_keys: %{},
        checks: %{}
      },
      %{
        name: "people_connector_sync_checkpoints",
        columns: %{
          "as_of_at" => %{default: nil, type: {:timestamp, 6}, nullable: false},
          "connection_id" => %{default: nil, type: :bigint, nullable: false},
          "id" => %{
            default: {:sequence, "people_connector_sync_checkpoints_id_seq"},
            type: :bigint,
            nullable: false
          },
          "inserted_at" => %{default: nil, type: {:timestamp, 0}, nullable: false},
          "resume_cursor" => %{default: nil, type: {:varchar, 1000}, nullable: true},
          "tenant_id" => %{default: nil, type: :bigint, nullable: false},
          "updated_at" => %{default: nil, type: {:timestamp, 0}, nullable: false},
          "version" => %{default: nil, type: :bigint, nullable: false}
        },
        indexes: %{
          "people_connector_sync_checkpoints_connection_unique" => %{
            where: nil,
            columns: ["connection_id"],
            unique: true
          },
          "people_connector_sync_checkpoints_pkey" => %{where: nil, columns: ["id"], unique: true}
        },
        foreign_keys: %{
          "people_connector_sync_checkpoints_connection_id_fkey" => %{
            columns: ["connection_id"],
            references: {"people_connector_connections", ["id"]},
            on_delete: :cascade,
            on_update: :nothing
          }
        },
        checks: %{
          "people_connector_sync_checkpoints_version" => %{expression: "CHECK (version > 0)"}
        }
      },
      %{
        name: "people_connector_sync_runs",
        columns: %{
          "applied" => %{default: {:integer, 0}, type: :integer, nullable: false},
          "as_of_at" => %{default: nil, type: {:timestamp, 6}, nullable: true},
          "checkpoint_version" => %{default: nil, type: :bigint, nullable: true},
          "connection_id" => %{default: nil, type: :bigint, nullable: false},
          "deactivated" => %{default: {:integer, 0}, type: :integer, nullable: false},
          "finished_at" => %{default: nil, type: {:timestamp, 6}, nullable: true},
          "id" => %{
            default: {:sequence, "people_connector_sync_runs_id_seq"},
            type: :bigint,
            nullable: false
          },
          "idempotency_key" => %{default: nil, type: {:varchar, 100}, nullable: false},
          "inserted_at" => %{default: nil, type: {:timestamp, 0}, nullable: false},
          "pass" => %{default: nil, type: {:varchar, 20}, nullable: false},
          "platform_company_id" => %{default: nil, type: :bigint, nullable: false},
          "provider_id" => %{default: nil, type: {:varchar, 100}, nullable: false},
          "reason" => %{default: nil, type: {:varchar, 60}, nullable: true},
          "refused" => %{default: {:integer, 0}, type: :integer, nullable: false},
          "started_at" => %{default: nil, type: {:timestamp, 6}, nullable: false},
          "state" => %{default: nil, type: {:varchar, 20}, nullable: false},
          "superseded" => %{default: {:integer, 0}, type: :integer, nullable: false},
          "tenant_id" => %{default: nil, type: :bigint, nullable: false},
          "unchanged" => %{default: {:integer, 0}, type: :integer, nullable: false},
          "updated_at" => %{default: nil, type: {:timestamp, 0}, nullable: false}
        },
        indexes: %{
          "people_connector_sync_runs_idempotency_unique" => %{
            where: nil,
            columns: ["connection_id", "idempotency_key"],
            unique: true
          },
          "people_connector_sync_runs_one_running" => %{
            where: "state::text='running'::text",
            columns: ["connection_id"],
            unique: true
          },
          "people_connector_sync_runs_pkey" => %{where: nil, columns: ["id"], unique: true},
          "people_connector_sync_runs_retention" => %{
            where: nil,
            columns: ["connection_id", "finished_at"],
            unique: false
          }
        },
        foreign_keys: %{
          "people_connector_sync_runs_connection_id_fkey" => %{
            columns: ["connection_id"],
            references: {"people_connector_connections", ["id"]},
            on_delete: :cascade,
            on_update: :nothing
          }
        },
        checks: %{
          "people_connector_sync_runs_pass" => %{
            expression:
              "CHECK (pass::text = ANY (ARRAY['bootstrap'::character varying, 'incremental'::character varying]::text[]))"
          },
          "people_connector_sync_runs_state" => %{
            expression:
              "CHECK (state::text = ANY (ARRAY['running'::character varying, 'succeeded'::character varying, 'stale'::character varying, 'unavailable'::character varying, 'refused'::character varying, 'failed'::character varying, 'unknown'::character varying]::text[]))"
          }
        }
      },
      %{
        name: "people_connector_workforce_records",
        columns: %{
          "active" => %{default: nil, type: :boolean, nullable: false},
          "assignments" => %{default: {:string, "[]"}, type: :jsonb, nullable: false},
          "assignments_incomplete" => %{default: nil, type: :boolean, nullable: true},
          "code" => %{default: nil, type: {:varchar, 100}, nullable: false},
          "connection_id" => %{default: nil, type: :bigint, nullable: false},
          "content_hash" => %{default: nil, type: {:varchar, 64}, nullable: false},
          "deactivated_at" => %{default: nil, type: {:timestamp, 6}, nullable: true},
          "email" => %{default: nil, type: {:varchar, 255}, nullable: true},
          "id" => %{
            default: {:sequence, "people_connector_workforce_records_id_seq"},
            type: :bigint,
            nullable: false
          },
          "inserted_at" => %{default: nil, type: {:timestamp, 0}, nullable: false},
          "kind" => %{default: nil, type: {:varchar, 20}, nullable: false},
          "name" => %{default: nil, type: {:varchar, 255}, nullable: false},
          "observed_at" => %{default: nil, type: {:timestamp, 6}, nullable: false},
          "parent_stable_id" => %{default: nil, type: {:varchar, 100}, nullable: true},
          "source_id" => %{default: nil, type: {:varchar, 100}, nullable: false},
          "stable_id" => %{default: nil, type: {:varchar, 100}, nullable: false},
          "supervisor_stable_id" => %{default: nil, type: {:varchar, 100}, nullable: true},
          "tenant_id" => %{default: nil, type: :bigint, nullable: false},
          "updated_at" => %{default: nil, type: {:timestamp, 0}, nullable: false},
          "vacant" => %{default: nil, type: :boolean, nullable: true},
          "version" => %{default: nil, type: :integer, nullable: true},
          "workforce_company_id" => %{default: nil, type: :bigint, nullable: false}
        },
        indexes: %{
          "people_connector_workforce_records_identity_unique" => %{
            where: nil,
            columns: ["connection_id", "kind", "source_id", "stable_id"],
            unique: true
          },
          "people_connector_workforce_records_pkey" => %{
            where: nil,
            columns: ["id"],
            unique: true
          }
        },
        foreign_keys: %{
          "people_connector_workforce_records_connection_id_fkey" => %{
            columns: ["connection_id"],
            references: {"people_connector_connections", ["id"]},
            on_delete: :cascade,
            on_update: :nothing
          }
        },
        checks: %{
          "people_connector_workforce_records_kind" => %{
            expression:
              "CHECK (kind::text = ANY (ARRAY['company'::character varying, 'employee'::character varying, 'position'::character varying]::text[]))"
          }
        }
      },
      %{
        name: "people_connector_reconciliation_issues",
        columns: %{
          "connection_id" => %{default: nil, type: :bigint, nullable: false},
          "first_seen_at" => %{default: nil, type: {:timestamp, 6}, nullable: false},
          "id" => %{
            default: {:sequence, "people_connector_reconciliation_issues_id_seq"},
            type: :bigint,
            nullable: false
          },
          "inserted_at" => %{default: nil, type: {:timestamp, 0}, nullable: false},
          "issue_key" => %{default: nil, type: {:varchar, 200}, nullable: false},
          "kind" => %{default: nil, type: {:varchar, 40}, nullable: false},
          "last_seen_at" => %{default: nil, type: {:timestamp, 6}, nullable: false},
          "occurrences" => %{default: {:integer, 1}, type: :integer, nullable: false},
          "reason" => %{default: nil, type: {:varchar, 60}, nullable: false},
          "record_kind" => %{default: nil, type: {:varchar, 20}, nullable: true},
          "resolved_at" => %{default: nil, type: {:timestamp, 6}, nullable: true},
          "severity" => %{default: nil, type: {:varchar, 10}, nullable: false},
          "stable_id" => %{default: nil, type: {:varchar, 100}, nullable: true},
          "status" => %{default: nil, type: {:varchar, 10}, nullable: false},
          "tenant_id" => %{default: nil, type: :bigint, nullable: false},
          "updated_at" => %{default: nil, type: {:timestamp, 0}, nullable: false}
        },
        indexes: %{
          "people_connector_reconciliation_issues_key_unique" => %{
            where: nil,
            columns: ["connection_id", "issue_key"],
            unique: true
          },
          "people_connector_reconciliation_issues_pkey" => %{
            where: nil,
            columns: ["id"],
            unique: true
          }
        },
        foreign_keys: %{
          "people_connector_reconciliation_issues_connection_id_fkey" => %{
            columns: ["connection_id"],
            references: {"people_connector_connections", ["id"]},
            on_delete: :cascade,
            on_update: :nothing
          }
        },
        checks: %{
          "people_connector_reconciliation_issues_status" => %{
            expression:
              "CHECK ((status::text = ANY (ARRAY['open'::character varying, 'resolved'::character varying]::text[])) AND (severity::text = ANY (ARRAY['warning'::character varying, 'error'::character varying]::text[])))"
          }
        }
      },
      %{
        name: "people_connector_webhook_deliveries",
        columns: %{
          "body_hash" => %{default: nil, type: {:varchar, 64}, nullable: false},
          "connection_id" => %{default: nil, type: :bigint, nullable: false},
          "delivery_hash" => %{default: nil, type: {:varchar, 64}, nullable: false},
          "id" => %{
            default: {:sequence, "people_connector_webhook_deliveries_id_seq"},
            type: :bigint,
            nullable: false
          },
          "received_at" => %{default: nil, type: {:timestamp, 6}, nullable: false},
          "tenant_id" => %{default: nil, type: :bigint, nullable: false}
        },
        indexes: %{
          "people_connector_webhook_deliveries_identity_unique" => %{
            where: nil,
            columns: ["connection_id", "delivery_hash"],
            unique: true
          },
          "people_connector_webhook_deliveries_pkey" => %{
            where: nil,
            columns: ["id"],
            unique: true
          },
          "people_connector_webhook_deliveries_retention" => %{
            where: nil,
            columns: ["connection_id", "received_at"],
            unique: false
          }
        },
        foreign_keys: %{
          "people_connector_webhook_deliveries_connection_id_fkey" => %{
            columns: ["connection_id"],
            references: {"people_connector_connections", ["id"]},
            on_delete: :cascade,
            on_update: :nothing
          }
        },
        checks: %{}
      },
      %{
        name: "people_connector_webhook_nonces",
        columns: %{
          "connection_id" => %{default: nil, type: :bigint, nullable: false},
          "id" => %{
            default: {:sequence, "people_connector_webhook_nonces_id_seq"},
            type: :bigint,
            nullable: false
          },
          "nonce_hash" => %{default: nil, type: {:varchar, 64}, nullable: false},
          "received_at" => %{default: nil, type: {:timestamp, 6}, nullable: false},
          "tenant_id" => %{default: nil, type: :bigint, nullable: false}
        },
        indexes: %{
          "people_connector_webhook_nonces_identity_unique" => %{
            where: nil,
            columns: ["connection_id", "nonce_hash"],
            unique: true
          },
          "people_connector_webhook_nonces_pkey" => %{where: nil, columns: ["id"], unique: true},
          "people_connector_webhook_nonces_retention" => %{
            where: nil,
            columns: ["connection_id", "received_at"],
            unique: false
          }
        },
        foreign_keys: %{
          "people_connector_webhook_nonces_connection_id_fkey" => %{
            columns: ["connection_id"],
            references: {"people_connector_connections", ["id"]},
            on_delete: :cascade,
            on_update: :nothing
          }
        },
        checks: %{}
      },
      %{
        name: "people_connector_file_exchanges",
        columns: %{
          "artifact_id" => %{default: nil, type: :uuid, nullable: true},
          "connection_id" => %{default: nil, type: :bigint, nullable: true},
          "direction" => %{default: nil, type: {:varchar, 10}, nullable: false},
          "expires_at" => %{default: nil, type: {:timestamp, 6}, nullable: true},
          "failure_reason" => %{default: nil, type: {:varchar, 20}, nullable: true},
          "id" => %{default: nil, type: :uuid, nullable: false},
          "inserted_at" => %{default: nil, type: {:timestamp, 6}, nullable: false},
          "platform_company_id" => %{default: nil, type: :bigint, nullable: false},
          "record_count" => %{default: nil, type: :integer, nullable: false},
          "sha256" => %{default: nil, type: {:varchar, 64}, nullable: false},
          "state" => %{default: nil, type: {:varchar, 10}, nullable: false},
          "tenant_id" => %{default: nil, type: :bigint, nullable: false},
          "updated_at" => %{default: nil, type: {:timestamp, 6}, nullable: false},
          "workforce_company_id" => %{default: nil, type: :bigint, nullable: false},
          "workforce_source_id" => %{default: nil, type: {:varchar, 100}, nullable: false}
        },
        indexes: %{
          "people_connector_file_exchanges_connection_id_direction_sha256_" => %{
            where: nil,
            columns: ["connection_id", "direction", "sha256"],
            unique: false
          },
          "people_connector_file_exchanges_pending_unique" => %{
            where: "state::text='pending'::text",
            columns: ["connection_id", "direction", "sha256"],
            unique: true
          },
          "people_connector_file_exchanges_pkey" => %{where: nil, columns: ["id"], unique: true},
          "people_connector_file_exchanges_retention" => %{
            where: nil,
            columns: ["tenant_id", "platform_company_id", "inserted_at"],
            unique: false
          },
          "people_connector_file_exchanges_tenant_id_platform_company_id_i" => %{
            where: nil,
            columns: ["tenant_id", "platform_company_id"],
            unique: false
          }
        },
        foreign_keys: %{
          "people_connector_file_exchanges_connection_id_fkey" => %{
            columns: ["connection_id"],
            references: {"people_connector_connections", ["id"]},
            on_delete: :nilify_all,
            on_update: :nothing
          },
          "people_connector_file_exchanges_platform_company_id_fkey" => %{
            columns: ["platform_company_id"],
            references: {"companies", ["id"]},
            on_delete: :restrict,
            on_update: :nothing
          },
          "people_connector_file_exchanges_tenant_id_fkey" => %{
            columns: ["tenant_id"],
            references: {"tenants", ["id"]},
            on_delete: :restrict,
            on_update: :nothing
          }
        },
        checks: %{
          "people_connector_file_exchange_values" => %{
            expression:
              "CHECK ((direction::text = ANY (ARRAY['import'::character varying, 'export'::character varying]::text[])) AND (state::text = ANY (ARRAY['pending'::character varying, 'ready'::character varying, 'failed'::character varying]::text[])) AND record_count >= 0 AND workforce_company_id > 0 AND (state::text <> 'ready'::text OR artifact_id IS NOT NULL AND expires_at IS NOT NULL) AND (failure_reason IS NULL OR state::text = 'failed'::text AND failure_reason::text = 'stale'::text))"
          }
        }
      },
      %{
        name: "people_connector_retention_attempts",
        columns: %{
          "attempted_at" => %{default: nil, type: {:timestamp, 6}, nullable: false},
          "id" => %{
            default: {:sequence, "people_connector_retention_attempts_id_seq"},
            type: :bigint,
            nullable: false
          },
          "kind" => %{default: nil, type: {:varchar, 10}, nullable: false},
          "platform_company_id" => %{default: nil, type: :bigint, nullable: false},
          "record_id" => %{default: nil, type: {:varchar, 36}, nullable: false},
          "tenant_id" => %{default: nil, type: :bigint, nullable: false}
        },
        indexes: %{
          "people_connector_retention_attempts_identity" => %{
            where: nil,
            columns: ["platform_company_id", "kind", "record_id"],
            unique: true
          },
          "people_connector_retention_attempts_pkey" => %{
            where: nil,
            columns: ["id"],
            unique: true
          }
        },
        foreign_keys: %{},
        checks: %{
          "people_connector_retention_attempts_kind" => %{
            expression:
              "CHECK (kind::text = ANY (ARRAY['sync'::character varying, 'webhook'::character varying, 'nonce'::character varying, 'file'::character varying]::text[]))"
          }
        }
      }
    ]
  end

  @impl true
  def verify_invariants(repo, opts \\ []) do
    prefix = SchemaVerifier.quote_identifier!(Keyword.get(opts, :prefix, "public"))
    connections = "#{prefix}.people_connector_connections"

    # Historical runs and file/backup receipts may retain an older provider or
    # workforce mapping. Only the current projection must match that mapping.
    checks =
      for suffix <-
            ~w(sync_checkpoints sync_runs workforce_records reconciliation_issues webhook_deliveries webhook_nonces file_exchanges backups) do
        table = "people_connector_" <> suffix

        company =
          if suffix in ~w(sync_runs file_exchanges backups),
            do: " OR row.platform_company_id <> connection.platform_company_id",
            else: ""

        {"#{table}: connection ownership mismatch",
         "SELECT count(*) FROM #{prefix}.#{table} AS row JOIN #{connections} AS connection ON connection.id = row.connection_id WHERE row.tenant_id <> connection.tenant_id#{company}"}
      end

    checks =
      checks ++
        [
          {"people_connector_workforce_records: workforce mapping mismatch",
           "SELECT count(*) FROM #{prefix}.people_connector_workforce_records AS row JOIN #{connections} AS connection ON connection.id = row.connection_id WHERE row.source_id <> connection.workforce_source_id OR row.workforce_company_id <> connection.workforce_company_id"}
        ]

    # Also diagnose existing replay/mapping collisions if a deployed unique
    # index has drifted; structural verification separately detects that drift.
    identities = [
      {"connections", "platform_company_id", ""},
      {"connections", "tenant_id, workforce_source_id, workforce_company_id", ""},
      {"sync_checkpoints", "connection_id", ""},
      {"sync_runs", "connection_id, idempotency_key", ""},
      {"sync_runs", "connection_id", "WHERE state = 'running'"},
      {"workforce_records", "connection_id, kind, source_id, stable_id", ""},
      {"reconciliation_issues", "connection_id, issue_key", ""},
      {"webhook_deliveries", "connection_id, delivery_hash", ""},
      {"webhook_nonces", "connection_id, nonce_hash", ""},
      # Detached file receipts have no replay identity, matching NULL semantics
      # in the partial unique index.
      {"file_exchanges", "connection_id, direction, sha256",
       "WHERE state = 'pending' AND connection_id IS NOT NULL"},
      {"retention_attempts", "platform_company_id, kind, record_id", ""}
    ]

    checks =
      checks ++
        Enum.map(identities, fn {suffix, columns, predicate} ->
          table = "people_connector_" <> suffix

          {"#{table}: duplicate identity (#{columns})",
           "SELECT count(*) FROM (SELECT #{columns} FROM #{prefix}.#{table} #{predicate} GROUP BY #{columns} HAVING count(*) > 1) AS collisions"}
        end)

    errors =
      Enum.flat_map(checks, fn {error, query} ->
        case SQL.query!(repo, query, []).rows do
          [[0]] -> []
          _ -> [error]
        end
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end
end
