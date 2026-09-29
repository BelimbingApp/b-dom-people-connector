defmodule Bilimbi.PeopleConnector.Connector do
  @moduledoc """
  Provider-neutral Connector boundary.

  Connection storage and activation belong to a later slice. A declared
  capability is therefore still disconnected: no provider port can be used
  through this facade yet. Tenant-owned calls take a validated Tenancy scope
  and an explicit platform company ID. The People Workforce public API
  validates that company and returns its separate workforce-company ID.
  """

  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.People.Workforce
  alias Bilimbi.People.Workforce.ReadResult
  alias Bilimbi.PeopleConnector.Connector.Registry
  alias Bilimbi.PeopleConnector.Connector.Status

  @type refusal ::
          :not_found | :unsupported | :disconnected | {:not_current, ReadResult.freshness()}

  @doc "The company-scoped connection state before any connection is configured."
  @spec status(Scope.t(), term()) ::
          {:ok, Status.t()} | {:error, :not_found | {:not_current, ReadResult.freshness()}}
  def status(%Scope{} = scope, platform_company_id) do
    with {:ok, result} <- Workforce.company(scope, platform_company_id) do
      Status.from_workforce_result(result)
    end
  end

  @doc """
  Checks a provider's declaration for a direction, then refuses use
  while no company-scoped connection has been configured. An undeclared
  operation is refused even if an adapter implements the requested function.
  """
  @spec request_port(
          Scope.t(),
          term(),
          Registry.t(),
          String.t(),
          String.t(),
          :read | :write
        ) :: {:error, refusal()}
  def request_port(
        %Scope{} = scope,
        platform_company_id,
        %Registry{} = registry,
        provider_id,
        capability,
        direction
      ) do
    with {:ok, _status} <- status(scope, platform_company_id),
         :ok <- Registry.permit(registry, provider_id, capability, direction) do
      {:error, :disconnected}
    end
  end
end
