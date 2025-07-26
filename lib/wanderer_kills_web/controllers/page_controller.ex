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
        Logger.info("[PageController] Dashboard data structure:")

        Logger.info(
          "[PageController] - health: #{inspect(data.health, pretty: true, limit: :infinity)}"
        )

        Logger.info(
          "[PageController] - health.application.metrics: #{inspect(get_in(data, [:health, :application, :metrics]), pretty: true)}"
        )

        Logger.info(
          "[PageController] - health.cache.metrics: #{inspect(get_in(data, [:health, :cache, :metrics]), pretty: true)}"
        )

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

  # Add a debug endpoint
  def debug(conn, _params) do
    case Dashboard.get_dashboard_data() do
      {:ok, data} ->
        debug_data = %{
          health: data.health,
          app_metrics: get_in(data, [:health, :application, :metrics]),
          cache_metrics: get_in(data, [:health, :cache, :metrics]),
          memory_mb_value:
            WandererKills.Utils.safe_get(data.health, [:application, :metrics, :memory_mb]),
          process_count_value:
            WandererKills.Utils.safe_get(data.health, [:application, :metrics, :process_count]),
          hit_rate_value: WandererKills.Utils.safe_get(data.health, [:cache, :metrics, :hit_rate])
        }

        json(conn, debug_data)

      {:error, reason} ->
        json(conn, %{error: reason})
    end
  end
end
