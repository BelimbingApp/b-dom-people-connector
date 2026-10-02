defmodule Bilimbi.PeopleConnector.Connector.Webhooks do
  @moduledoc """
  Signed native directory-change notifications through Bilimbi's inbound seam.

  Intake records a durable notification, never impersonates a login actor or
  invokes actor-authorized synchronisation. An operator synchronises through
  the existing connection page. Exact request bytes and all routing identities
  are authenticated before JSON decoding. A connection lock serializes nonce
  consumption, delivery deduplication and configuration changes.
  """
  import Ecto.Query

  alias Bilimbi.Base.Audit
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Settings
  alias Bilimbi.Base.Settings.Scope, as: SettingsScope
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.PeopleConnector.Connector
  alias Bilimbi.PeopleConnector.Connector.Connection
  alias Bilimbi.PeopleConnector.Connector.Providers
  alias Bilimbi.PeopleConnector.Connector.Webhooks.Delivery
  alias Bilimbi.PeopleConnector.Connector.Webhooks.Nonce

  @identifier "people-native"
  @secret "people-connector.webhook.secret"
  @enabled "people-connector.webhook.enabled"
  @skew "people-connector.webhook.max_skew_seconds"
  @headers ~w(x-people-tenant x-people-company x-people-timestamp x-people-nonce x-people-delivery x-people-signature)

  def identifier, do: @identifier
  def secret_key, do: @secret

  # Called only after the facade validates Workforce company and actor reach.
  def summary(%Scope{} = scope, company_id) do
    settings_scope = settings_scope(scope, company_id)
    connection = connection(scope, company_id)

    last =
      if connection do
        from(d in Tenancy.scope_query(Delivery, scope),
          where: d.connection_id == ^connection.id,
          order_by: [desc: d.received_at, desc: d.id],
          limit: 1
        )
        |> Repo.one()
      end

    %{
      enabled: Settings.get(@enabled, settings_scope),
      secret_stored?: Settings.overridden?(@secret, settings_scope),
      max_skew_seconds: Settings.get(@skew, settings_scope),
      last_received_at: last && last.received_at
    }
  end

  def configure(%Scope{} = scope, company_id, values) when is_map(values) do
    with :ok <- validate_settings(values) do
      Repo.transaction(fn ->
        connection = connection(scope, company_id, true)
        if is_nil(connection), do: Repo.rollback(:disconnected)
        if connection.provider_id != Providers.native_id(), do: Repo.rollback(:unsupported)
        settings_scope = settings_scope(scope, company_id)

        case Map.fetch(values, :secret) do
          {:ok, ""} -> :ok = Settings.delete(@secret, settings_scope)
          {:ok, secret} -> put!(@secret, secret, settings_scope)
          :error -> :ok
        end

        enabled = Map.get(values, :enabled, Settings.get(@enabled, settings_scope))

        if enabled and not Settings.overridden?(@secret, settings_scope),
          do: Repo.rollback(:webhook_secret_missing)

        put!(@enabled, enabled, settings_scope)

        if Map.has_key?(values, :max_skew_seconds),
          do: put!(@skew, values.max_skew_seconds, settings_scope)

        summary(scope, company_id)
      end)
    end
  end

  def configure(%Scope{}, _company_id, _values), do: {:error, :invalid_webhook_settings}

  defp validate_settings(values) do
    valid? =
      Enum.all?(values, fn
        {:enabled, value} ->
          is_boolean(value)

        {:max_skew_seconds, value} ->
          is_integer(value) and value in 1..86_400

        {:secret, ""} ->
          true

        {:secret, value} when is_binary(value) ->
          byte_size(value) in 32..4096 and String.valid?(value) and String.trim(value) != ""

        _ ->
          false
      end)

    if valid?, do: :ok, else: {:error, :invalid_webhook_settings}
  end

  def clear(%Connection{} = connection) do
    settings_scope = SettingsScope.company(connection.platform_company_id, connection.tenant_id)
    :ok = Settings.delete(@secret, settings_scope)
    :ok = Settings.delete(@enabled, settings_scope)
    :ok = Settings.delete(@skew, settings_scope)
    :ok
  end

  @doc "Inbound seam verification callback. No body parsing or durable writes here."
  def verify(%{method: "POST", body: body, headers: headers})
      when is_binary(body) and is_list(headers) do
    with {:ok, fields} <- fields(headers),
         {:ok, tenant_id} <- positive_integer(fields.tenant),
         {:ok, company_id} <- positive_integer(fields.company),
         {:ok, timestamp} <- positive_integer(fields.timestamp),
         :ok <- valid_key(fields.nonce),
         :ok <- valid_key(fields.delivery),
         {:ok, scope} <- Tenancy.scope(tenant_id),
         {:ok, %{state: :enabled, provider_id: provider}} <- Connector.status(scope, company_id),
         true <- provider == Providers.native_id(),
         settings_scope = settings_scope(scope, company_id),
         true <- Settings.get(@enabled, settings_scope),
         secret when is_binary(secret) <- Settings.get(@secret, settings_scope),
         true <-
           abs(System.system_time(:second) - timestamp) <= Settings.get(@skew, settings_scope),
         true <- byte_size(fields.signature) == 64,
         {:ok, signature} <- Base.decode16(fields.signature, case: :lower),
         expected = :crypto.mac(:hmac, :sha256, secret, signing_bytes(fields, body)),
         true <- byte_size(signature) == 32 and :crypto.hash_equals(expected, signature) do
      {:ok, %{scope: scope, company_id: company_id, fields: fields}}
    else
      _ -> {:error, :delivery_refused}
    end
  end

  def verify(_request), do: {:error, :delivery_refused}

  @doc "Inbound seam handling callback; retries require a new signed nonce."
  def handle(request, _context) do
    # Reverify inside the lock, so a rotation/disable between callbacks and a
    # caller-fabricated context cannot authorize work with obsolete credentials.
    with {:ok, context} <- verify(request) do
      case Repo.transaction(fn ->
             scope = context.scope
             company_id = context.company_id
             connection = connection(scope, company_id, true)
             if is_nil(connection), do: Repo.rollback(:delivery_refused)

             with {:ok, verified} <- verify(request),
                  {:ok, %{"event" => "directory.changed"} = payload} <- Jason.decode(request.body),
                  true <- map_size(payload) == 1 do
               receive_delivery(verified, connection, request.body)
             else
               _ -> Repo.rollback(:delivery_refused)
             end
           end) do
        {:ok, _outcome} -> :ok
        {:error, _reason} -> {:error, :delivery_refused}
      end
    end
  end

  defp receive_delivery(context, connection, body) do
    scope = context.scope
    nonce_hash = digest(context.fields.nonce)
    delivery_hash = digest(context.fields.delivery)
    body_hash = digest(body)

    nonce_query =
      from(n in Tenancy.scope_query(Nonce, scope),
        where: n.connection_id == ^connection.id and n.nonce_hash == ^nonce_hash
      )

    if Repo.exists?(nonce_query), do: Repo.rollback(:replay)

    now = DateTime.utc_now()

    %Nonce{
      tenant_id: Scope.tenant_id(scope),
      connection_id: connection.id,
      nonce_hash: nonce_hash,
      received_at: now
    }
    |> Repo.insert!()

    delivery_query =
      from(d in Tenancy.scope_query(Delivery, scope),
        where: d.connection_id == ^connection.id and d.delivery_hash == ^delivery_hash
      )

    result =
      case Repo.one(delivery_query) do
        nil ->
          %Delivery{
            tenant_id: Scope.tenant_id(scope),
            connection_id: connection.id,
            delivery_hash: delivery_hash,
            body_hash: body_hash,
            received_at: now
          }
          |> Repo.insert!()

          "received"

        %Delivery{body_hash: ^body_hash} ->
          "duplicate"

        _ ->
          Repo.rollback(:delivery_conflict)
      end

    case Audit.record_action(scope, %{
           company_id: context.company_id,
           actor_type: "guest",
           actor_id: 0,
           event: "people-connector.webhook",
           occurred_at: DateTime.to_naive(now),
           payload: %{"result" => "succeeded", "outcome" => result}
         }) do
      {:ok, _action} -> result
      {:error, _reason} -> Repo.rollback(:audit_unavailable)
    end
  end

  defp fields(headers) do
    values =
      Enum.map(@headers, fn name ->
        case for({header, value} <- headers, String.downcase(header) == name, do: value) do
          [value] when is_binary(value) -> value
          _ -> nil
        end
      end)

    case values do
      [tenant, company, timestamp, nonce, delivery, signature]
      when is_binary(tenant) and is_binary(company) and is_binary(timestamp) and
             is_binary(nonce) and is_binary(delivery) and is_binary(signature) ->
        {:ok,
         %{
           tenant: tenant,
           company: company,
           timestamp: timestamp,
           nonce: nonce,
           delivery: delivery,
           signature: signature
         }}

      _ ->
        {:error, :delivery_refused}
    end
  end

  defp signing_bytes(fields, body),
    do:
      Enum.join(
        [
          "people-native:v1",
          fields.tenant,
          fields.company,
          fields.timestamp,
          fields.nonce,
          fields.delivery
        ],
        "\n"
      ) <> "\n" <> body

  defp valid_key(value) do
    if byte_size(value) in 1..100 and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]*\z/, value),
      do: :ok,
      else: {:error, :delivery_refused}
  end

  defp positive_integer(value) do
    if byte_size(value) in 1..18 and Regex.match?(~r/\A[1-9][0-9]*\z/, value),
      do: {:ok, String.to_integer(value)},
      else: {:error, :delivery_refused}
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp settings_scope(scope, company_id),
    do: SettingsScope.company(company_id, Scope.tenant_id(scope))

  defp connection(scope, company_id, lock? \\ false) do
    query =
      from(c in Tenancy.scope_query(Connection, scope),
        where: c.platform_company_id == ^company_id
      )

    query = if lock?, do: lock(query, "FOR UPDATE"), else: query
    Repo.one(query)
  end

  defp put!(key, value, scope) do
    case Settings.put(key, value, scope) do
      {:ok, _value} -> :ok
      {:error, _reason} -> Repo.rollback(:invalid_webhook_settings)
    end
  end
end
