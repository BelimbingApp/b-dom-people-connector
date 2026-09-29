defmodule Bilimbi.PeopleConnector.Connector.SchemaContract do
  @moduledoc "Fresh Bilimbi connection schema."
  @behaviour Bilimbi.Base.Database.SchemaContract

  @table "people_connector_connections"

  def migration_version, do: 20_260_930_200_101

  @impl true
  def tables do
    [
      %{
        name: @table,
        columns: %{
          "id" => column(:bigint, false, {:sequence, "#{@table}_id_seq"}),
          "tenant_id" => column(:bigint, false),
          "platform_company_id" => column(:bigint, false),
          "provider_id" => column({:varchar, 100}, false),
          "provider_contract_version" => column({:varchar, 20}, false),
          "workforce_source_id" => column({:varchar, 100}, false),
          "workforce_company_id" => column(:bigint, false),
          "enabled" => column(:boolean, false, {:boolean, false}),
          "inserted_at" => column({:timestamp, 0}, false),
          "updated_at" => column({:timestamp, 0}, false)
        },
        indexes: %{
          "#{@table}_pkey" => index(["id"], true),
          "#{@table}_platform_company_unique" => index(["platform_company_id"], true),
          "#{@table}_workforce_company_unique" =>
            index(["tenant_id", "workforce_source_id", "workforce_company_id"], true)
        },
        foreign_keys: %{}
      }
    ]
  end

  defp column(type, nullable, default \\ nil),
    do: %{type: type, nullable: nullable, default: default}

  defp index(columns, unique), do: %{columns: columns, unique: unique, where: nil}
end
