defmodule Bilimbi.PeopleConnector.Connector.Backup.Owner do
  @moduledoc false
  @behaviour Bilimbi.Base.Artifacts.Owner
  def artifact_owner_id, do: "people_connector/connector"

  def authorize(scope, company, operation, reference),
    do:
      Bilimbi.PeopleConnector.Connector.Backup.authorize_artifact(
        scope,
        company,
        operation,
        reference
      )
end
