defmodule Bilimbi.PeopleConnector.Connector.PortAuthorization do
  @moduledoc """
  What the Connector hands an adapter after checking the actor, the company
  mapping, the provider's declaration and the enabled connection.

  Both company axes are explicit: `platform_company_id` is the Core Company
  in `scope`'s tenant and `workforce_company_id` the workforce company the
  connection records. Adapters never build one; only the Connector does.
  """

  alias Bilimbi.Base.Tenancy.Scope

  @enforce_keys [
    :scope,
    :platform_company_id,
    :workforce_source_id,
    :workforce_company_id,
    :provider_id,
    :capability
  ]
  defstruct [
    :scope,
    :platform_company_id,
    :workforce_source_id,
    :workforce_company_id,
    :provider_id,
    :capability,
    direction: :read
  ]

  @type t :: %__MODULE__{
          scope: Scope.t(),
          platform_company_id: pos_integer(),
          workforce_source_id: String.t(),
          workforce_company_id: pos_integer(),
          provider_id: String.t(),
          capability: String.t(),
          direction: :read
        }
end
