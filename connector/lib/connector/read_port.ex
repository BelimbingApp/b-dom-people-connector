defmodule Bilimbi.PeopleConnector.Connector.ReadPort do
  @moduledoc """
  Neutral read port for a validated tenant and explicitly mapped company axes.

  A future connection resolver will issue an authorization value only after
  checking actor, company mapping, capability and connection state. There is
  deliberately no callable adapter path in slice 1C.
  """

  @callback read(authorization :: term(), request :: term()) :: {:ok, term()} | {:error, term()}
end
