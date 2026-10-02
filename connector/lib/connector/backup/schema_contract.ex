defmodule Bilimbi.PeopleConnector.Connector.Backup.SchemaContract do
  @moduledoc "Fresh backup receipt schema, verified after its Bilimbi-only migration."
  @behaviour Bilimbi.Base.Database.SchemaContract
  def migration_version, do: 20_261_003_010_001

  @impl true
  def tables do
    [
      %{
        name: "people_connector_backups",
        columns:
          Map.new(
            [
              {"id", :uuid, false},
              {"tenant_id", :bigint, false},
              {"platform_company_id", :bigint, false},
              {"connection_id", :bigint, true},
              {"sha256", {:varchar, 64}, false},
              {"state", {:varchar, 10}, false},
              {"artifact_id", :uuid, true},
              {"expires_at", {:timestamp, 6}, false},
              {"preview_token_hash", {:varchar, 64}, true},
              {"preview_state_hash", {:varchar, 64}, true},
              # These two identifiers are login actors, not workforce employees.
              {"preview_actor_id", :bigint, true},
              {"preview_impersonator_id", :bigint, true},
              {"preview_expires_at", {:timestamp, 6}, true},
              {"recovery_generation", :integer, true},
              {"restored_at", {:timestamp, 6}, true},
              {"inserted_at", {:timestamp, 6}, false},
              {"updated_at", {:timestamp, 6}, false}
            ],
            fn {name, type, nullable} ->
              {name, %{type: type, nullable: nullable, default: nil}}
            end
          ),
        indexes: %{
          "people_connector_backups_pkey" => %{columns: ["id"], unique: true, where: nil},
          "people_connector_backups_tenant_id_platform_company_id_expires_" => %{
            columns: ["tenant_id", "platform_company_id", "expires_at"],
            unique: false,
            where: nil
          }
        },
        foreign_keys: %{
          "people_connector_backups_connection_id_fkey" => %{
            columns: ["connection_id"],
            references: {"people_connector_connections", ["id"]},
            on_delete: :nilify_all
          }
        },
        checks: %{
          "people_connector_backups_state" => %{
            expression:
              "((((state)::text = ANY ((ARRAY['pending'::character varying, 'ready'::character varying, 'failed'::character varying])::text[])) AND (((state)::text <> 'ready'::text) OR (artifact_id IS NOT NULL))))"
          }
        }
      }
    ]
  end
end
