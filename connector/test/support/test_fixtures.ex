defmodule Bilimbi.PeopleConnector.Connector.TestFixtures do
  @moduledoc false

  alias Bilimbi.Base.Repo
  alias Ecto.Adapters.SQL

  # Mirrors the owned migration so tests run without the shared migrated schema.
  def create_connection_tables! do
    SQL.query!(
      Repo,
      """
      CREATE TEMPORARY TABLE IF NOT EXISTS people_connector_connections (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL,
        platform_company_id bigint NOT NULL, provider_id varchar(100) NOT NULL,
        provider_contract_version varchar(20) NOT NULL,
        workforce_source_id varchar(100) NOT NULL, workforce_company_id bigint NOT NULL,
        enabled boolean NOT NULL DEFAULT false,
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CONSTRAINT people_connector_connections_platform_company_unique
          UNIQUE (platform_company_id),
        CONSTRAINT people_connector_connections_workforce_company_unique
          UNIQUE (tenant_id, workforce_source_id, workforce_company_id)
      ) ON COMMIT PRESERVE ROWS
      """,
      []
    )
  end

  @doc "Stores a row directly, as an earlier mapping or another company's claim would."
  def insert_connection!(attributes) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    SQL.query!(
      Repo,
      """
      INSERT INTO people_connector_connections
        (tenant_id, platform_company_id, provider_id, provider_contract_version,
         workforce_source_id, workforce_company_id, enabled, inserted_at, updated_at)
      VALUES ($1, $2, $3, '1.0.0', 'people/native', $4, $5, $6, $6)
      """,
      [
        Map.fetch!(attributes, :tenant_id),
        Map.fetch!(attributes, :platform_company_id),
        Map.get(attributes, :provider_id, "people.native"),
        Map.fetch!(attributes, :workforce_company_id),
        Map.get(attributes, :enabled, false),
        now
      ]
    )
  end
end
