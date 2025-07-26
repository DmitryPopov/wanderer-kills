defmodule WandererKillsWeb.HealthController do
  @moduledoc """
  Health check and monitoring endpoints.

  Provides simple health checks, detailed status information,
  and metrics for monitoring systems.
  """

  use WandererKillsWeb, :controller
  require Logger

  alias WandererKills.Core.EtsOwner
  alias WandererKills.Core.Observability.Health
  alias WandererKills.Core.Observability.Metrics
  alias WandererKills.Core.Observability.Monitoring
  alias WandererKills.Dashboard
  alias WandererKills.Utils

  @doc """
  Simple ping endpoint for basic health checks.
  """
  @spec ping(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ping(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "pong")
  end

  @doc """
  Detailed health check with component status.
  """
  @spec health(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def health(conn, _params) do
    case Health.check_health() do
      {:ok, health_status} ->
        status_code = if health_status.healthy, do: 200, else: 503
        response = Map.put(health_status, :timestamp, DateTime.utc_now() |> DateTime.to_iso8601())

        conn
        |> put_status(status_code)
        |> json(response)

      {:error, reason} ->
        response = %{
          error: "Health check failed",
          reason: inspect(reason),
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        conn
        |> put_status(503)
        |> json(response)
    end
  end

  @doc """
  Status endpoint with detailed service information.
  """
  @spec status(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def status(conn, %{"debug" => "dashboard"}) do
    # Debug mode for dashboard data
    case Dashboard.get_dashboard_data() do
      {:ok, data} ->
        debug_response = %{
          template_values: %{
            memory_mb: Utils.safe_get(data.health, [:application, :metrics, :memory_mb]),
            process_count: Utils.safe_get(data.health, [:application, :metrics, :process_count]),
            hit_rate: Utils.safe_get(data.health, [:cache, :metrics, :hit_rate]),
            cache_size: Utils.safe_get(data.health, [:cache, :metrics, :size])
          },
          raw_health: data.health,
          unified_status: %{
            system_memory: get_in(data.status, [:system, :memory, :total]),
            system_processes: get_in(data.status, [:system, :processes, :count])
          }
        }

        json(conn, debug_response)

      {:error, reason} ->
        json(conn, %{error: reason})
    end
  end

  def status(conn, _params) do
    status = Monitoring.get_unified_status()

    # Format response similar to what Status.get_service_status() would have returned
    response = %{
      metrics: status,
      summary: build_status_summary(status),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    json(conn, response)
  end

  defp build_status_summary(metrics) do
    %{
      api_requests_per_minute: calculate_api_requests(metrics),
      active_subscriptions: get_metric(metrics, [:websocket, :connections_active], 0),
      killmails_stored: get_metric(metrics, [:processing, :redisq_received], 0),
      cache_hit_rate: get_metric(metrics, [:cache, :hit_rate], 0.0),
      memory_usage_mb: calculate_memory_usage(metrics),
      uptime_hours: calculate_uptime(metrics),
      processing_lag_seconds:
        get_metric(metrics, [:processing, :redisq_last_killmail_ago_seconds], 0),
      active_preload_tasks: get_metric(metrics, [:preload, :active_tasks], 0)
    }
  end

  defp calculate_api_requests(metrics) do
    zkb = get_metric(metrics, [:api, :zkillboard, :requests_per_minute], 0)
    esi = get_metric(metrics, [:api, :esi, :requests_per_minute], 0)
    zkb + esi
  end

  defp calculate_memory_usage(metrics) do
    metrics
    |> get_in([:system, :memory, :total])
    |> convert_bytes_to_mb()
  end

  defp calculate_uptime(metrics) do
    metrics
    |> get_in([:system, :uptime_seconds])
    |> convert_seconds_to_hours()
  end

  defp get_metric(metrics, path, default) do
    get_in(metrics, path) || default
  end

  defp convert_bytes_to_mb(nil), do: 0.0
  defp convert_bytes_to_mb(bytes), do: Float.round(bytes / 1024 / 1024, 2)

  defp convert_seconds_to_hours(nil), do: 0.0
  defp convert_seconds_to_hours(seconds), do: Float.round(seconds / 3600, 2)

  @doc """
  Metrics endpoint for monitoring systems.
  """
  @spec metrics(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def metrics(conn, _params) do
    {:ok, metrics} = Health.get_metrics()
    json(conn, metrics)
  end

  @doc """
  Test websocket tracking manually
  """
  @spec test_websocket_tracking(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def test_websocket_tracking(conn, _params) do
    # Manually call the tracking function to test it
    Metrics.track_websocket_connection(:connected, %{
      user_id: "test-user-123",
      test: true
    })

    # Wait a moment for processing
    Process.sleep(100)

    # Check the updated stats
    websocket_stats =
      case :ets.lookup(EtsOwner.wanderer_kills_stats_table(), :websocket_stats) do
        [{:websocket_stats, stats}] -> stats
        _ -> nil
      end

    json(conn, %{
      message: "Test tracking call completed",
      websocket_stats: websocket_stats
    })
  end

  @doc """
  Debug endpoint that returns the exact dashboard data structure.
  """
  @spec dashboard_debug(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def dashboard_debug(conn, _params) do
    # Get raw ETS data for websocket stats
    websocket_stats_raw =
      case :ets.lookup(EtsOwner.wanderer_kills_stats_table(), :websocket_stats) do
        [{:websocket_stats, stats}] -> stats
        _ -> nil
      end

    case Dashboard.get_dashboard_data() do
      {:ok, data} ->
        debug_response = %{
          template_data: %{
            memory_mb: Utils.safe_get(data.health, [:application, :metrics, :memory_mb]),
            process_count: Utils.safe_get(data.health, [:application, :metrics, :process_count]),
            hit_rate: Utils.safe_get(data.health, [:cache, :metrics, :hit_rate]),
            cache_size: Utils.safe_get(data.health, [:cache, :metrics, :size])
          },
          raw_health_data: data.health,
          status_data: %{
            system_memory: get_in(data.status, [:system, :memory, :total]),
            system_processes: get_in(data.status, [:system, :processes, :count])
          },
          ets_websocket_stats: websocket_stats_raw,
          dashboard_websocket_stats: data.websocket_stats
        }

        json(conn, debug_response)

      {:error, reason} ->
        json(conn, %{error: reason})
    end
  end
end
