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
