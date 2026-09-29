defmodule Bilimbi.PeopleConnector.Connector.Status do
  @moduledoc "A scoped connection status with both company identity axes."

  alias Bilimbi.People.Workforce.Company, as: WorkforceCompany
  alias Bilimbi.People.Workforce.ReadResult

  @enforce_keys [:state, :platform_company_id, :workforce_company_id, :provider_id]
  defstruct [:state, :platform_company_id, :workforce_company_id, :provider_id]

  @type t :: %__MODULE__{
          state: :disconnected,
          platform_company_id: pos_integer(),
          workforce_company_id: pos_integer(),
          provider_id: String.t() | nil
        }

  @doc "Rejects stale or unavailable People identity before using its company mapping."
  @spec from_workforce_result(ReadResult.t()) ::
          {:ok, t()} | {:error, :not_found | {:not_current, ReadResult.freshness()}}
  def from_workforce_result(%ReadResult{} = result) do
    case ReadResult.require_current(result) do
      {:ok, %WorkforceCompany{} = company} ->
        {:ok,
         %__MODULE__{
           state: :disconnected,
           platform_company_id: company.platform_company_id,
           workforce_company_id: company.workforce_company_id,
           provider_id: nil
         }}

      {:ok, _other} ->
        {:error, :not_found}

      {:error, {:not_current, _freshness}} = refusal ->
        refusal
    end
  end
end
