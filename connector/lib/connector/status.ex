defmodule Bilimbi.PeopleConnector.Connector.Status do
  @moduledoc "A scoped connection status with both company identity axes."

  @enforce_keys [:state, :platform_company_id, :workforce_company_id, :provider_id]
  defstruct [:state, :platform_company_id, :workforce_company_id, :provider_id]

  @type t :: %__MODULE__{
          state: :disconnected,
          platform_company_id: pos_integer(),
          workforce_company_id: pos_integer(),
          provider_id: String.t() | nil
        }
end
