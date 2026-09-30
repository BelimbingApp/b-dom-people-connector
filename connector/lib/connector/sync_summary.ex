defmodule Bilimbi.PeopleConnector.Connector.SyncSummary do
  @moduledoc """
  A company's synchronisation state for display.

  `freshness` uses the People Workforce vocabulary: `:current`,
  `{:stale, as_of}` when the checkpoint is older than the company's maximum
  age, or `{:unavailable, :never_synchronised | :disconnected}`. `last_run`
  is the most recent `SyncRun`; a running pass past the run timeout is shown
  as `:unknown`. `open_issues` lists at most 50 open reconciliation issues,
  errors first. `policy` holds the company's synchronisation settings.
  """

  alias Bilimbi.People.Workforce.ReadResult
  alias Bilimbi.PeopleConnector.Connector.ReconciliationIssue
  alias Bilimbi.PeopleConnector.Connector.SyncRun

  @enforce_keys [:freshness, :checkpoint_version, :as_of_at, :last_run, :open_issues, :policy]
  defstruct [:freshness, :checkpoint_version, :as_of_at, :last_run, :open_issues, :policy]

  @type t :: %__MODULE__{
          freshness: ReadResult.freshness(),
          checkpoint_version: pos_integer() | nil,
          as_of_at: DateTime.t() | nil,
          last_run: SyncRun.t() | nil,
          open_issues: [ReconciliationIssue.t()],
          policy: map()
        }
end
