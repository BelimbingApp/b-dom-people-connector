defmodule Bilimbi.PeopleConnector.Connector.Contributions do
  @moduledoc false

  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  @impl true
  def contributions do
    %{
      settings: %{
        definitions: %{
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
            help: "Minutes after the last completed pass before synchronised records are stale.",
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
        },
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
end
