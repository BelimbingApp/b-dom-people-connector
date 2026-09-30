defmodule Bilimbi.PeopleConnector.Connector.WritePort do
  @moduledoc "Provider-neutral write port. No writer is activated."

  @callback write(authorization :: term(), request :: term()) :: {:ok, term()} | {:error, term()}
end
