defmodule Bilimbi.PeopleConnector.Connector.FileExchange.Owner do
  @moduledoc false
  @behaviour Bilimbi.Base.Artifacts.Owner

  alias Bilimbi.PeopleConnector.Connector.FileExchange

  @impl true
  def artifact_owner_id, do: "people_connector/connector"

  @impl true
  def authorize(scope, company_id, operation, reference),
    do: FileExchange.authorize_artifact(scope, company_id, operation, reference)
end
