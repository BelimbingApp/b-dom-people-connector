defmodule Bilimbi.PeopleConnector.Connector.ReconciliationIssue do
  @moduledoc """
  Something a synchronisation pass could not apply and a person should see.

  An issue is keyed per connection, so the same problem seen again adds an
  occurrence instead of a new row, and reopens it if it was resolved. `kind`
  and `reason` are fixed codes, never provider text:

    * `record_refused` - `foreign_source`, `other_company`,
      `undeclared_capability`, `invalid_record` or `unknown_reference`, with
      the record's kind and stable ID. It resolves itself when a later pass
      applies that record.
    * `feed_refused` - `every_record_refused`; resolves on the next pass that
      moves the checkpoint.
    * `empty_bootstrap` - `no_records`: a full read returned nothing.
    * `unknown_outcome` - `no_outcome_recorded`: a pass stopped without an
      outcome.
    * `organisation_unavailable` - `provider_unavailable`: the organisation
      stream was unavailable or is no longer declared while active positions
      remain, so only the directory stream was applied; resolves on the next
      pass that reads it or finds no active position.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "people_connector_reconciliation_issues" do
    field(:tenant_id, :integer)
    field(:connection_id, :integer)
    field(:issue_key, :string)
    field(:kind, :string)
    field(:reason, :string)
    field(:severity, Ecto.Enum, values: [:warning, :error])
    field(:record_kind, :string)
    field(:stable_id, :string)
    field(:status, Ecto.Enum, values: [:open, :resolved])
    field(:occurrences, :integer, default: 1)
    field(:first_seen_at, :utc_datetime_usec)
    field(:last_seen_at, :utc_datetime_usec)
    field(:resolved_at, :utc_datetime_usec)
    timestamps(type: :naive_datetime)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(issue, changes) do
    issue
    |> change(changes)
    |> validate_required([
      :tenant_id,
      :connection_id,
      :issue_key,
      :kind,
      :reason,
      :severity,
      :status,
      :first_seen_at,
      :last_seen_at
    ])
    |> unique_constraint(:issue_key, name: :people_connector_reconciliation_issues_key_unique)
  end
end
