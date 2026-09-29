defmodule Bilimbi.PeopleConnector.Connector.Contributions do
  @moduledoc false

  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  @impl true
  def contributions do
    %{
      authz: %{
        domains: %{"people-connector" => "People integrations"},
        capabilities: ["people-connector.connections.view"]
      }
    }
  end
end
