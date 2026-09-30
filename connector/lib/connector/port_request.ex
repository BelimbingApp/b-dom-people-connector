defmodule Bilimbi.PeopleConnector.Connector.PortRequest do
  @moduledoc """
  One page request on a read port.

  A `:bootstrap` pass asks for the provider's whole directory; `since` is nil.
  A `:changes` pass asks for changes after the resume cursor the last
  completed pass returned. `cursor` is the page cursor within this pass (nil
  for the first page) and `limit` the most entries the page may carry.
  """

  @enforce_keys [:pass, :limit]
  defstruct [:pass, :since, :cursor, :limit]

  @type t :: %__MODULE__{
          pass: :bootstrap | :changes,
          since: String.t() | nil,
          cursor: String.t() | nil,
          limit: pos_integer()
        }
end
