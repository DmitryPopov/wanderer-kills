defmodule WandererKillsWeb.PageController do
  @moduledoc """
  Controller for the home page displaying service information and status.
  """
  use WandererKillsWeb, :controller
  require Logger

  alias WandererKills.Dashboard
  alias WandererKillsWeb.PageHTML

  def index(conn, _params) do
    case Dashboard.get_dashboard_data() do
      {:ok, data} ->
        html = PageHTML.index(data)

        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, html)

      {:error, reason} ->
        Logger.error("Failed to load dashboard data: #{reason}")

        conn
        |> put_status(500)
        |> json(%{error: "Internal server error", message: "Failed to load status page"})
    end
  end
end
