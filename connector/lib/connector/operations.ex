defmodule Bilimbi.PeopleConnector.Connector.Operations do
  @moduledoc false
  alias Bilimbi.Base.{Audit, Authz, Repo}
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.PeopleConnector.Connector

  def authorize(%Scope{} = scope, company) do
    with {:ok, actor} <- Authz.scope_actor(scope),
         {:ok, target} <-
           Company.authorize_company_target(actor, company, Connector.manage_capability()) do
      {:ok, target.id}
    else
      {:error, :no_authenticated_actor} -> {:error, :unauthorized}
      error -> error
    end
  end

  def audit!(scope, company, event, payload) do
    actor = Scope.actor(scope)

    case Audit.record_action(scope, %{
           company_id: company,
           actor_type: "user",
           actor_id: actor.user_id,
           impersonator_id: actor.impersonator_id,
           occurred_at: NaiveDateTime.utc_now(),
           event: event,
           payload: payload
         }) do
      {:ok, _} -> :ok
      _ -> Repo.rollback(:audit_unavailable)
    end
  end

  # Each row has its own transaction. PostgreSQL errors must roll back before
  # processing the next row; exception text never enters results or audit data.
  def transaction(fun) do
    Repo.transaction(fun)
  rescue
    _ in [Ecto.ConstraintError, Ecto.InvalidChangesetError, Postgrex.Error] ->
      {:error, :record_unavailable}
  end
end
