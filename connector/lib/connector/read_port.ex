defmodule Bilimbi.PeopleConnector.Connector.ReadPort do
  @moduledoc """
  Neutral read port for directory synchronisation.

  The Connector calls it only with a `PortAuthorization` it issued after
  checking actor, company mapping, the provider's declaration and the
  enabled connection. An adapter returns one `Page` per `PortRequest`, or an
  error. The error is recorded only as a fixed reason code; adapter text is
  never stored.
  """

  alias Bilimbi.PeopleConnector.Connector.Page
  alias Bilimbi.PeopleConnector.Connector.PortAuthorization
  alias Bilimbi.PeopleConnector.Connector.PortRequest

  @callback read(PortAuthorization.t(), PortRequest.t()) :: {:ok, Page.t()} | {:error, term()}
end
