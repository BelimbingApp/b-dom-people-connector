defmodule Bilimbi.PeopleConnector.Connector.Page do
  @moduledoc """
  One page an adapter returns for a `PortRequest`.

  `entries` holds `WorkforceRecord` values, and on a `:changes` pass also
  `Deactivation` values. `next_cursor` is nil on the last page of a pass.
  `resume_cursor` is what the next `:changes` pass presents as `since`; the
  last page's value is kept. `as_of` is the provider watermark for the page.
  `freshness` uses the People Workforce vocabulary: a stale or unavailable
  page stops the pass before anything is applied.
  """

  alias Bilimbi.People.Workforce.ReadResult

  @enforce_keys [:entries, :as_of]
  defstruct [:entries, :next_cursor, :resume_cursor, :as_of, freshness: :current]

  @type t :: %__MODULE__{
          entries: list(),
          next_cursor: String.t() | nil,
          resume_cursor: String.t() | nil,
          as_of: DateTime.t(),
          freshness: ReadResult.freshness()
        }
end
