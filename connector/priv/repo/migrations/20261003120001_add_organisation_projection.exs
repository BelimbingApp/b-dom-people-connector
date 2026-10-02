defmodule Bilimbi.PeopleConnector.Connector.Migrations.AddOrganisationProjection do
  use Ecto.Migration

  def up do
    drop(
      constraint(:people_connector_workforce_records, :people_connector_workforce_records_kind)
    )

    create(
      constraint(:people_connector_workforce_records, :people_connector_workforce_records_kind,
        check: "kind IN ('company', 'employee', 'position')"
      )
    )

    alter table(:people_connector_workforce_records) do
      add(:parent_stable_id, :string, size: 100)
      add(:version, :integer)
      add(:vacant, :boolean)
      add(:assignments_incomplete, :boolean)
      add(:assignments, {:array, :map}, null: false, default: [])
    end
  end

  def down do
    execute("DELETE FROM people_connector_workforce_records WHERE kind = 'position'")

    alter table(:people_connector_workforce_records) do
      remove(:assignments)
      remove(:assignments_incomplete)
      remove(:vacant)
      remove(:version)
      remove(:parent_stable_id)
    end

    drop(
      constraint(:people_connector_workforce_records, :people_connector_workforce_records_kind)
    )

    create(
      constraint(:people_connector_workforce_records, :people_connector_workforce_records_kind,
        check: "kind IN ('company', 'employee')"
      )
    )
  end
end
