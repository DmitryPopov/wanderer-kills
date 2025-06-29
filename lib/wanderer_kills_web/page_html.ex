defmodule WandererKillsWeb.PageHTML do
  @moduledoc """
  HTML generation module for the dashboard page.

  Contains functions for rendering the dashboard HTML with proper separation
  of concerns from the controller logic.
  """

  alias WandererKills.Utils

  @doc """
  Generates the complete HTML for the dashboard index page.
  """
  def index(data) do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>WandererKills - Real-time EVE Online Killmail Service</title>
      <link rel="stylesheet" href="/css/dashboard.css" />
    </head>
    <body>
      <div class="container">
        #{header_section(data)}
        #{stats_section(data)}
        #{health_section(data)}
        #{endpoints_section()}
        #{footer_section(data)}
      </div>
    </body>
    </html>
    """
  end

  defp header_section(%{version: version}) do
    """
    <header class="header">
      <h1>WandererKills</h1>
      <p>Real-time EVE Online Killmail Data Service</p>
      <span class="version-badge">v#{version}</span>
    </header>
    """
  end

  defp stats_section(%{status: status, websocket_stats: websocket_stats, uptime: uptime}) do
    """
    <div class="stats-grid">
      <div class="stat-card">
        <h3>Uptime</h3>
        <div class="value">#{uptime}</div>
      </div>
      <div class="stat-card">
        <h3>Total Killmails</h3>
        <div class="value">#{format_number(Utils.safe_get(status, [:storage, :killmails_count]))}</div>
      </div>
      <div class="stat-card">
        <h3>Active Systems</h3>
        <div class="value">#{format_number(Utils.safe_get(status, [:storage, :systems_count]))}</div>
      </div>
      <div class="stat-card">
        <h3>WebSocket Connections</h3>
        <div class="value">#{format_number(Utils.safe_get(websocket_stats, [:connections, :active]))}</div>
      </div>
    </div>
    """
  end

  defp health_section(%{
         health: health,
         status: status,
         websocket_stats: websocket_stats,
         ets_stats: ets_stats,
         redisq_stats: redisq_stats
       }) do
    """
    <div class="health-grid">
      #{application_health_card(health)}
      #{cache_health_card(health, status)}
      #{system_performance_card(status)}
      #{message_delivery_card(websocket_stats, status)}
      #{ets_storage_card(ets_stats)}
      #{redisq_pipeline_card(redisq_stats)}
    </div>
    """
  end

  defp application_health_card(health) do
    """
    <div class="health-card">
      <div class="health-header">
        <h3 class="health-title">Application Health</h3>
        <span class="health-status #{health_status_class(Utils.safe_get(health, [:application, :status], "healthy"))}">
          #{health_status_icon(Utils.safe_get(health, [:application, :status], "healthy"))} #{String.capitalize(normalize_status(Utils.safe_get(health, [:application, :status], "healthy")))}
        </span>
      </div>
      <div class="metrics">
        <div class="metric-row">
          <span class="metric-label">Memory Usage</span>
          <span class="metric-value">#{format_memory_mb(Utils.safe_get(health, [:application, :metrics, :memory_mb]))} MB</span>
        </div>
        <div class="metric-row">
          <span class="metric-label">Process Count</span>
          <span class="metric-value">#{format_number(Utils.safe_get(health, [:application, :metrics, :process_count]))}</span>
        </div>
        <div class="metric-row">
          <span class="metric-label">Scheduler Usage</span>
          <span class="metric-value">#{format_percentage(Utils.safe_get(health, [:application, :metrics, :scheduler_usage]))}</span>
        </div>
      </div>
    </div>
    """
  end

  defp cache_health_card(health, status) do
    """
    <div class="health-card">
      <div class="health-header">
        <h3 class="health-title">Cache Performance</h3>
        <span class="health-status #{health_status_class(Utils.safe_get(health, [:cache, :status], "healthy"))}">
          #{health_status_icon(Utils.safe_get(health, [:cache, :status], "healthy"))} #{String.capitalize(normalize_status(Utils.safe_get(health, [:cache, :status], "healthy")))}
        </span>
      </div>
      <div class="metrics">
        <div class="metric-row">
          <span class="metric-label">Hit Rate</span>
          <span class="metric-value">#{format_percentage(Utils.safe_get(health, [:cache, :metrics, :hit_rate]))}</span>
        </div>
        <div class="metric-row">
          <span class="metric-label">Total Size</span>
          <span class="metric-value">#{format_number(Utils.safe_get(health, [:cache, :metrics, :size]))} entries</span>
        </div>
        <div class="metric-row">
          <span class="metric-label">Operations/min</span>
          <span class="metric-value">#{format_number(Utils.safe_get(status, [:cache, :operations_per_minute]))}</span>
        </div>
      </div>
    </div>
    """
  end

  defp system_performance_card(status) do
    # Calculate system performance metrics from available data
    zkb_stats = Utils.safe_get(status, [:api, :zkillboard], %{})
    esi_stats = Utils.safe_get(status, [:api, :esi], %{})

    # Combine stats from both APIs
    total_api_requests =
      Utils.safe_get(zkb_stats, [:total_requests], 0) +
        Utils.safe_get(esi_stats, [:total_requests], 0)

    api_requests_per_min =
      Utils.safe_get(zkb_stats, [:requests_per_minute], 0) +
        Utils.safe_get(esi_stats, [:requests_per_minute], 0)

    api_error_count =
      Utils.safe_get(zkb_stats, [:error_count], 0) + Utils.safe_get(esi_stats, [:error_count], 0)

    # Use ESI average duration as it's typically higher
    avg_duration =
      Utils.safe_get(
        esi_stats,
        [:avg_duration_ms],
        Utils.safe_get(zkb_stats, [:avg_duration_ms], 0)
      )

    # Calculate error rate
    error_rate =
      if total_api_requests > 0 do
        (api_error_count / total_api_requests * 100) |> Float.round(1)
      else
        0.0
      end

    status_class =
      cond do
        error_rate > 5.0 -> "danger"
        error_rate > 1.0 -> "warning"
        true -> "success"
      end

    """
    <div class="health-card">
      <div class="health-header">
        <h3 class="health-title">System Performance</h3>
        <span class="health-status #{status_class}">
          📊 #{if error_rate > 5.0, do: "Degraded", else: if(error_rate > 1.0, do: "Warning", else: "Healthy")}
        </span>
      </div>
      <div class="metrics">
        <div class="metric-row">
          <span class="metric-label">API Requests/min</span>
          <span class="metric-value">#{format_number(api_requests_per_min)}</span>
        </div>
        <div class="metric-row">
          <span class="metric-label">Total Requests</span>
          <span class="metric-value">#{format_number(total_api_requests)}</span>
        </div>
        <div class="metric-row">
          <span class="metric-label">Error Rate</span>
          <span class="metric-value">#{format_percentage(error_rate)}</span>
        </div>
        <div class="metric-row">
          <span class="metric-label">Avg Response</span>
          <span class="metric-value">#{format_latency(avg_duration)}</span>
        </div>
      </div>
    </div>
    """
  end

  defp message_delivery_card(websocket_stats, status) do
    """
    <div class="health-card">
      <div class="health-header">
        <h3 class="health-title">Message Delivery</h3>
        <span class="health-status success">
          📤 Active
        </span>
      </div>
      <div class="metrics">
        <div class="metric-row">
          <span class="metric-label">WebSocket Total</span>
          <span class="metric-value">#{format_number(Utils.safe_get(websocket_stats, [:kills_sent, :total]))}</span>
        </div>
        <div class="metric-row">
          <span class="metric-label">Real-time</span>
          <span class="metric-value">#{format_number(Utils.safe_get(websocket_stats, [:kills_sent, :realtime]))}</span>
        </div>
        <div class="metric-row">
          <span class="metric-label">Preload</span>
          <span class="metric-value">#{format_number(Utils.safe_get(websocket_stats, [:kills_sent, :preload]))}</span>
        </div>
        <div class="metric-row">
          <span class="metric-label">SSE Stream</span>
          <span class="metric-value">#{format_number(Utils.safe_get(status, [:sse, :events_sent_total]))}</span>
        </div>
      </div>
    </div>
    """
  end

  defp ets_storage_card(ets_stats) do
    """
    <div class="health-card">
      <div class="health-header">
        <h3 class="health-title">ETS Storage</h3>
        <span class="health-status success">
          💾 #{Enum.count(ets_stats, & &1.available)}/#{Enum.count(ets_stats)}
        </span>
      </div>
      <div class="metrics">
        <div class="metric-row">
          <span class="metric-label">Total Records</span>
          <span class="metric-value">#{format_number(Enum.sum(Enum.map(ets_stats, & &1.size)))}</span>
        </div>
        <div class="metric-row">
          <span class="metric-label">Total Memory</span>
          <span class="metric-value">#{Float.round(Enum.sum(Enum.map(ets_stats, & &1.memory_mb)), 1)} MB</span>
        </div>
        <div class="metric-row">
          <span class="metric-label">Largest Table</span>
          <span class="metric-value">#{Enum.max_by(ets_stats, & &1.size, fn -> %{name: "N/A", size: 0} end).name}</span>
        </div>
        <div class="metric-row">
          <span class="metric-label">Active Tables</span>
          <span class="metric-value">#{Enum.count(ets_stats, & &1.available)}</span>
        </div>
      </div>
    </div>
    """
  end

  defp redisq_pipeline_card(redisq_stats) do
    """
    <div class="health-card">
      <div class="health-header">
        <h3 class="health-title">RedisQ Pipeline</h3>
        <span class="health-status #{if redisq_stats.status == "active", do: "success", else: "warning"}">
          🔄 #{String.capitalize(redisq_stats.status)}
        </span>
      </div>
      <div class="metrics">
        <div class="metric-row">
          <span class="metric-label">Total Processed</span>
          <span class="metric-value">#{format_number(redisq_stats.total_processed)}</span>
        </div>
        <div class="metric-row">
          <span class="metric-label">Processing Rate</span>
          <span class="metric-value">#{format_number(redisq_stats.processing_rate)}/min</span>
        </div>
        <div class="metric-row">
          <span class="metric-label">Queue Lag</span>
          <span class="metric-value">#{format_latency(redisq_stats.queue_lag)}</span>
        </div>
        <div class="metric-row">
          <span class="metric-label">Last Processed</span>
          <span class="metric-value">#{redisq_stats.last_processed}</span>
        </div>
      </div>
    </div>
    """
  end

  defp endpoints_section do
    """
    <div class="endpoints-section">
      <h2>API Endpoints</h2>
      <div class="endpoint-grid">
        <a href="/health" class="endpoint-link" data-tooltip="Health Check">❤️</a>
        <a href="/status" class="endpoint-link" data-tooltip="Service Status">📊</a>
        <a href="/metrics" class="endpoint-link" data-tooltip="Metrics">📈</a>
        <a href="/websocket" class="endpoint-link" data-tooltip="WebSocket Info">🔌</a>
        <a href="/api/openapi" class="endpoint-link" data-tooltip="OpenAPI Spec">📚</a>
        <a href="/api/v1/kills/stream" class="endpoint-link" data-tooltip="SSE Stream">📡</a>
      </div>
    </div>
    """
  end

  defp footer_section(%{version: version}) do
    """
    <footer class="footer">
      <p>
        WandererKills #{version} •
        <a href="https://github.com/wanderer-industries/wanderer-kills" target="_blank">GitHub</a> •
        <a href="/api/openapi">API Documentation</a>
      </p>
    </footer>
    """
  end

  # Helper functions for formatting data

  defp format_number(nil), do: "0"

  defp format_number(num) when is_number(num) do
    num
    |> round()
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_number(_), do: "0"

  defp format_percentage(nil), do: "0%"
  defp format_percentage(num) when is_float(num), do: "#{Float.round(num, 1)}%"
  defp format_percentage(num) when is_integer(num), do: "#{num}%"
  defp format_percentage(_), do: "0%"

  defp format_latency(nil), do: "N/A"
  defp format_latency(num) when is_number(num), do: "#{round(num)}ms"
  defp format_latency(_), do: "N/A"

  defp format_memory_mb(nil), do: "0"

  defp format_memory_mb(mb) when is_number(mb) do
    format_number(round(mb))
  end

  defp format_memory_mb(_), do: "0"

  defp health_status_class(status) when status in ["healthy", :healthy, "ok", :ok], do: "success"

  defp health_status_class(status) when status in ["degraded", :degraded, "warning", :warning],
    do: "warning"

  defp health_status_class(status) when status in ["unhealthy", :unhealthy, "error", :error],
    do: "danger"

  # Default to healthy
  defp health_status_class(_), do: "success"

  defp health_status_icon(status) when status in ["healthy", :healthy, "ok", :ok], do: "✓"

  defp health_status_icon(status) when status in ["degraded", :degraded, "warning", :warning],
    do: "!"

  defp health_status_icon(status) when status in ["unhealthy", :unhealthy, "error", :error],
    do: "✗"

  # Default to healthy
  defp health_status_icon(_), do: "✓"

  defp normalize_status(status) when is_atom(status), do: Atom.to_string(status)
  defp normalize_status(status) when is_binary(status), do: status
  defp normalize_status(_), do: "healthy"
end
