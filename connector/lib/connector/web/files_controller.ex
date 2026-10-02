defmodule Bilimbi.PeopleConnector.Connector.Web.FilesController do
  @moduledoc false
  use Phoenix.Controller, formats: [:html]
  import Plug.Conn
  alias Bilimbi.PeopleConnector.Connector.FileExchange

  def download(conn, %{"company_id" => company, "id" => id}) do
    with {company_id, ""} when company_id > 0 <- Integer.parse(company),
         {:ok, %{bytes: bytes}} <-
           FileExchange.download(conn.assigns.current_scope.scope, company_id, id) do
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-disposition", "attachment; filename=people-directory.json")
      |> put_resp_content_type("application/json")
      |> send_resp(200, bytes)
    else
      _ -> send_resp(conn, 404, "File unavailable")
    end
  end
end
