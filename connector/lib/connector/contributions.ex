defmodule Bilimbi.PeopleConnector.Connector.Contributions do
  @moduledoc false

  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  @impl true
  def contributions do
    %{
      settings: %{
        definitions:
          Map.merge(Map.merge(retention_definitions(), backup_definitions()), %{
            "people-connector.files.enabled" => %{
              type: :boolean,
              scopes: [:company],
              default: false
            },
            "people-connector.files.json_enabled" => %{
              type: :boolean,
              scopes: [:company],
              default: true
            },
            "people-connector.files.max_bytes" => %{
              type: :integer,
              scopes: [:company],
              default: 1_048_576,
              minimum: 1,
              maximum: 10_485_760
            },
            "people-connector.files.max_records" => %{
              type: :integer,
              scopes: [:company],
              default: 1000,
              minimum: 1,
              maximum: 100_000
            },
            "people-connector.files.stale_minutes" => %{
              type: :integer,
              scopes: [:company],
              default: 15,
              minimum: 1,
              maximum: 1440
            },
            # Written only through the Connector facade and its connections page,
            # so it is not editable on the generic settings screen and has no
            # reveal path.
            "people-connector.webhook.secret" => %{
              type: :string,
              scopes: [:company],
              default: nil,
              nullable: true,
              encrypted: true
            },
            "people-connector.webhook.enabled" => %{
              type: :boolean,
              scopes: [:company],
              default: false
            },
            "people-connector.webhook.max_skew_seconds" => %{
              type: :integer,
              scopes: [:company],
              default: 300,
              minimum: 1,
              maximum: 86_400
            },
            "people-connector.connection.credential" => %{
              type: :string,
              scopes: [:company],
              default: nil,
              nullable: true,
              encrypted: true
            },
            # Synchronisation policy, edited per company on the connections page.
            "people-connector.sync.page_limit" => %{
              type: :integer,
              scopes: [:company],
              default: 250,
              minimum: 1,
              maximum: 1000,
              label: "Synchronisation page size",
              help: "Most directory records the provider returns on one page.",
              capability: "people-connector.connections.manage"
            },
            "people-connector.sync.max_age_minutes" => %{
              type: :integer,
              scopes: [:company],
              default: 1440,
              minimum: 5,
              maximum: 43_200,
              label: "Synchronised data maximum age",
              help:
                "Minutes after the last completed pass before synchronised records are stale.",
              capability: "people-connector.connections.manage"
            },
            "people-connector.sync.run_timeout_minutes" => %{
              type: :integer,
              scopes: [:company],
              default: 30,
              minimum: 1,
              maximum: 1440,
              label: "Synchronisation run timeout",
              help: "Minutes a pass may run before its outcome is recorded as unknown.",
              capability: "people-connector.connections.manage"
            }
          }),
        runtime_claims: []
      },
      authz: %{
        domains: %{"people-connector" => "People integrations"},
        capabilities: [
          "people-connector.connections.view",
          "people-connector.connections.manage"
        ]
      },
      menu: [
        %{
          id: "admin.system.integrations.people-connections",
          label: "People connections",
          parent: "admin.system.integrations",
          route: "/integrations/people/connections",
          capability: "people-connector.connections.view",
          order: 50
        }
      ]
    }
  end

  defp backup_definitions do
    Map.new(Bilimbi.PeopleConnector.Connector.Backup.fields(), fn {field,
                                                                   {key, default, min, max}} ->
      {key,
       %{
         type: :integer,
         scopes: [:company],
         default: default,
         minimum: min,
         maximum: max,
         label: backup_label(field),
         capability: "people-connector.connections.manage"
       }}
    end)
  end

  defp backup_label(:retention_days), do: "Backup retention (days)"
  defp backup_label(:preview_minutes), do: "Restore preview validity (minutes)"

  defp retention_definitions do
    Map.new(Bilimbi.PeopleConnector.Connector.Retention.fields(), fn {field,
                                                                      {key, default, min, max}} ->
      {key,
       %{
         type: :integer,
         scopes: [:company],
         default: default,
         nullable: is_nil(default),
         minimum: min,
         maximum: max,
         label: retention_label(field),
         capability: "people-connector.connections.manage"
       }}
    end)
  end

  defp retention_label(:sync_days), do: "Sync run retention (days)"
  defp retention_label(:webhook_days), do: "Webhook delivery retention (days)"
  defp retention_label(:file_days), do: "File receipt retention (days)"
  defp retention_label(:batch_size), do: "Retention batch size per record type"
  defp retention_label(:retry_minutes), do: "Retention retry delay (minutes)"
end
