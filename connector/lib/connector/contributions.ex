defmodule Bilimbi.PeopleConnector.Connector.Contributions do
  @moduledoc false

  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  @impl true
  def contributions do
    %{
      settings: %{
        definitions: %{
          # Written only through the Connector facade and its connections page,
          # so it is not editable on the generic settings screen and has no
          # reveal path.
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
