defmodule Bilimbi.PeopleConnector.NativePeopleAdapter do
  @moduledoc """
  Read-port adapter that serves the co-located native People provider from the
  People Workforce public API.

  It answers only what the provider declares: the company and its employees as
  directory reads. It has no writer, no single sign-on and no transport, and it
  never reads People tables. It trusts nothing but the `PortAuthorization` the
  Connector issued, and refuses one that names another provider, another
  capability, a foreign workforce source, or a workforce company that People
  does not map to the authorized platform company.

  People has no change feed, so a `:changes` pass returns the same full
  snapshot as a `:bootstrap` pass and every page is marked `snapshot: true`;
  the Connector then deactivates leavers on any pass.

  Every page of one pass shares the watermark minted on its first page, which
  rides in the page cursor; the cursor also records the last key emitted
  (the company is key 0, an employee its native ID), so pages stay stable
  while the workforce changes underneath a pass. A stale or unavailable
  Workforce result becomes an empty page carrying that freshness, which the
  Connector treats as a stopped pass. Errors are fixed atoms; Workforce text is
  never passed on.
  """

  @behaviour Bilimbi.PeopleConnector.Connector.ReadPort

  alias Bilimbi.People.Workforce
  alias Bilimbi.People.Workforce.Company, as: WorkforceCompany
  alias Bilimbi.People.Workforce.Employee, as: WorkforceEmployee
  alias Bilimbi.People.Workforce.ReadResult
  alias Bilimbi.PeopleConnector.Connector.Page
  alias Bilimbi.PeopleConnector.Connector.PortAuthorization
  alias Bilimbi.PeopleConnector.Connector.PortRequest
  alias Bilimbi.PeopleConnector.Connector.Providers
  alias Bilimbi.PeopleConnector.Connector.WorkforceRecord

  @capability "employee_directory"

  @type refusal ::
          :invalid_authorization
          | :invalid_request
          | :invalid_cursor
          | :not_found
          | :mapping_mismatch
          | :unexpected_result

  @impl true
  @spec read(PortAuthorization.t(), PortRequest.t()) :: {:ok, Page.t()} | {:error, refusal()}
  def read(authorization, request) do
    with :ok <- check_authorization(authorization),
         {:ok, limit} <- check_request(request),
         {:ok, as_of, after_key} <- decode_cursor(request.cursor),
         {:ok, company_result} <-
           Workforce.company(authorization.scope, authorization.platform_company_id),
         {:ok, employee_result} <-
           Workforce.employees(authorization.scope, authorization.platform_company_id) do
      page(authorization, limit, as_of, after_key, company_result, employee_result)
    end
  end

  defp page(authorization, limit, as_of, after_key, company_result, employee_result) do
    case {ReadResult.require_current(company_result), ReadResult.require_current(employee_result)} do
      {{:ok, %WorkforceCompany{} = company}, {:ok, employees}} when is_list(employees) ->
        build_page(authorization, limit, as_of, after_key, company, employees)

      {{:error, {:not_current, freshness}}, _} ->
        {:ok, not_current(as_of, freshness)}

      {_, {:error, {:not_current, freshness}}} ->
        {:ok, not_current(as_of, freshness)}

      _ ->
        {:error, :unexpected_result}
    end
  end

  defp build_page(authorization, limit, as_of, after_key, company, employees) do
    if mapped?(authorization, company) and Enum.all?(employees, &mapped?(authorization, &1)) do
      entries =
        [{0, record(company, as_of)}] ++
          Enum.map(employees, &{employee_key(&1), record(&1, as_of)})

      remaining =
        entries |> Enum.filter(fn {key, _} -> key > after_key end) |> Enum.sort_by(&elem(&1, 0))

      {taken, rest} = Enum.split(remaining, limit)

      next_cursor =
        if rest == [], do: nil, else: encode_cursor(as_of, taken |> List.last() |> elem(0))

      {:ok,
       %Page{
         entries: Enum.map(taken, &elem(&1, 1)),
         next_cursor: next_cursor,
         resume_cursor: DateTime.to_iso8601(as_of),
         as_of: as_of,
         snapshot: true
       }}
    else
      {:error, :mapping_mismatch}
    end
  end

  defp not_current(as_of, freshness),
    do: %Page{entries: [], as_of: as_of || now(), freshness: freshness}

  defp mapped?(authorization, %{
         platform_company_id: platform_id,
         workforce_company_id: workforce_id
       }),
       do:
         platform_id == authorization.platform_company_id and
           workforce_id == authorization.workforce_company_id

  defp record(%WorkforceCompany{} = company, as_of) do
    %WorkforceRecord{
      kind: :company,
      source_id: company.reference.source_id,
      stable_id: company.reference.stable_id,
      workforce_company_id: company.workforce_company_id,
      name: company.name,
      code: company.code,
      observed_at: as_of
    }
  end

  defp record(%WorkforceEmployee{} = employee, as_of) do
    %WorkforceRecord{
      kind: :employee,
      source_id: employee.reference.source_id,
      stable_id: employee.reference.stable_id,
      workforce_company_id: employee.workforce_company_id,
      name: employee.display_name,
      code: employee.employee_number,
      email: employee.email,
      supervisor_stable_id:
        employee.supervisor_reference && employee.supervisor_reference.stable_id,
      observed_at: as_of
    }
  end

  defp employee_key(%WorkforceEmployee{reference: %{stable_id: stable_id}}),
    do: String.to_integer(stable_id)

  defp check_authorization(%PortAuthorization{
         direction: :read,
         capability: @capability,
         provider_id: provider_id,
         workforce_source_id: source_id,
         platform_company_id: platform_id,
         workforce_company_id: workforce_id
       }) do
    if provider_id == Providers.native_id() and source_id == Workforce.source_id() and
         is_integer(platform_id) and platform_id > 0 and workforce_id == platform_id,
       do: :ok,
       else: {:error, :invalid_authorization}
  end

  defp check_authorization(_authorization), do: {:error, :invalid_authorization}

  defp check_request(%PortRequest{pass: pass, limit: limit, since: since})
       when pass in [:bootstrap, :changes] and is_integer(limit) and limit > 0 and
              (is_nil(since) or is_binary(since)),
       do: {:ok, limit}

  defp check_request(_request), do: {:error, :invalid_request}

  defp decode_cursor(nil), do: {:ok, now(), -1}

  defp decode_cursor(cursor) when is_binary(cursor) do
    with ["v1", usec, key] <- String.split(cursor, ":"),
         {usec, ""} <- Integer.parse(usec),
         {key, ""} <- Integer.parse(key),
         true <- key >= 0,
         {:ok, as_of} <- DateTime.from_unix(usec, :microsecond) do
      {:ok, as_of, key}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp decode_cursor(_cursor), do: {:error, :invalid_cursor}

  defp encode_cursor(as_of, key),
    do: "v1:#{DateTime.to_unix(as_of, :microsecond)}:#{key}"

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
