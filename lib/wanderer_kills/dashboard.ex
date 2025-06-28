defmodule WandererKills.Dashboard do
  @moduledoc """
  Context module for dashboard data gathering and preparation.

  Handles fetching and formatting all data needed for the dashboard display,
  including health checks, system status, websocket statistics, ETS storage info,
  and RedisQ processing metrics.
  """

  require Logger

  alias WandererKills.Core.Observability.{
    HealthChecks,
    UnifiedStatus,
    WebSocketStats
  }

  alias WandererKills.Utils

  @ets_tables Application.compile_env(:wanderer_kills, [:dashboard, :ets_tables], [
                {:killmails, "🗂️", "Killmails"},
                {:system_killmails, "🌌", "System Index"},
                {:system_kill_counts, "📊", "Kill Counts"},
                {:system_fetch_timestamps, "⏰", "Fetch Times"},
                {:killmail_events, "📝", "Events"},
                {:client_offsets, "🔖", "Client Offsets"},
                {:counters, "🔢", "Counters"}
              ])

  @doc """
  Gathers all dashboard data needed for display.

  Returns a map containing:
  - `:status` - Unified system status information
  - `:health` - Application and service health data
  - `:websocket_stats` - WebSocket connection and message statistics
  - `:uptime` - Formatted uptime string
  - `:version` - Application version
  - `:ets_stats` - ETS table statistics
  - `:redisq_stats` - RedisQ processing statistics

  ## Returns

  - `{:ok, data}` - Successfully gathered all dashboard data
  - `{:error, reason}` - Failed to gather data due to an error
  """
  @spec get_dashboard_data() :: {:ok, map()} | {:error, String.t()}
  def get_dashboard_data do
    try do
      # Gather all status information
      status = UnifiedStatus.get_status()

      # Get health information
      full_health = HealthChecks.check_health()
      Logger.debug("Full health check result: #{inspect(full_health)}")

      # Extract health data safely
      app_health = extract_health_data(full_health, :application)
      cache_health = extract_health_data(full_health, :cache)

      health = %{
        application: app_health,
        cache: cache_health
      }

      # Get websocket stats safely
      websocket_stats = get_websocket_stats()

      # Get uptime and version safely
      uptime = format_uptime(Utils.safe_get(status, [:uptime_seconds], 0))

      version =
        case Application.spec(:wanderer_kills, :vsn) do
          nil -> "unknown"
          vsn -> to_string(vsn)
        end

      # Get ETS storage statistics
      ets_stats = get_ets_stats()

      # Get RedisQ processing statistics
      redisq_stats = get_redisq_stats(status)

      data = %{
        status: status,
        health: health,
        websocket_stats: websocket_stats,
        uptime: uptime,
        version: version,
        ets_stats: ets_stats,
        redisq_stats: redisq_stats
      }

      {:ok, data}
    rescue
      e ->
        Logger.error("Error gathering dashboard data: #{inspect(e)} - #{inspect(__STACKTRACE__)}")
        {:error, "Failed to gather dashboard data"}
    end
  end

  # Private helper functions

  defp extract_health_data(full_health, key) do
    case full_health do
      %{checks: %{^key => health_data}} when is_map(health_data) ->
        Logger.debug("#{key} health: #{inspect(health_data)}")
        health_data

      _ ->
        Logger.debug("Using default #{key} health")
        default_health_status()
    end
  end

  defp get_websocket_stats do
    case WebSocketStats.get_stats() do
      {:ok, stats} -> stats
      _ -> %{}
    end
  end

  defp format_uptime(seconds) when is_number(seconds) do
    days = div(seconds, 86_400)
    hours = div(rem(seconds, 86_400), 3600)
    minutes = div(rem(seconds, 3600), 60)

    cond do
      days > 0 -> "#{days}d #{hours}h #{minutes}m"
      hours > 0 -> "#{hours}h #{minutes}m"
      true -> "#{minutes}m"
    end
  end

  defp format_uptime(_), do: "N/A"

  defp default_health_status do
    %{
      status: "healthy",
      metrics: %{
        memory_mb: 0,
        process_count: 0,
        scheduler_usage: 0,
        hit_rate: 0,
        size: 0
      }
    }
  end

  defp get_ets_stats do
    Enum.map(@ets_tables, fn {table, icon, name} ->
      try do
        info = :ets.info(table)
        size = Keyword.get(info, :size, 0)
        memory = Keyword.get(info, :memory, 0)
        # Convert words to bytes using dynamic word size for cross-platform compatibility
        word_size = :erlang.system_info(:wordsize)
        memory_bytes = memory * word_size
        memory_mb = Float.round(memory_bytes / (1024 * 1024), 2)

        %{
          name: name,
          icon: icon,
          table: table,
          size: size,
          memory_mb: memory_mb,
          available: true
        }
      rescue
        _ ->
          %{
            name: name,
            icon: icon,
            table: table,
            size: 0,
            memory_mb: 0,
            available: false
          }
      end
    end)
  end

  defp get_redisq_stats(status) do
    %{
      total_processed: Utils.safe_get(status, [:redisq, :total_processed], 0),
      processing_rate: Utils.safe_get(status, [:redisq, :processing_rate], 0),
      last_processed: Utils.safe_get(status, [:redisq, :last_processed_at]),
      queue_lag: Utils.safe_get(status, [:redisq, :queue_lag_ms], 0),
      status:
        if(Utils.safe_get(status, [:redisq, :total_processed], 0) > 0, do: "active", else: "idle")
    }
  end
end
