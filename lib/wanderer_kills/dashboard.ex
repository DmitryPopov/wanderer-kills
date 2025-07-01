defmodule WandererKills.Dashboard do
  @moduledoc """
  Context module for dashboard data gathering and preparation.

  Handles fetching and formatting all data needed for the dashboard display,
  including health checks, system status, websocket statistics, ETS storage info,
  and RedisQ processing metrics.
  """

  require Logger

  alias WandererKills.Core.EtsOwner

  alias WandererKills.Core.Observability.{
    HealthChecks,
    UnifiedStatus
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

  # RedisQ reports stats every 60 seconds. We consider data stale if it's older than
  # 70 seconds to allow for some processing delay and clock drift
  @redisq_window_staleness_seconds 70

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

      # Get health information - check both application and cache
      full_health = HealthChecks.check_health(components: [:application, :cache])
      Logger.debug("Full health check result: #{inspect(full_health)}")

      # Extract health data safely
      app_health = extract_health_data(full_health, :application)
      cache_health = extract_health_data(full_health, :cache)

      health = %{
        application: app_health,
        cache: cache_health
      }

      # Get websocket stats from unified status and transform to expected structure
      raw_websocket_stats = Utils.safe_get(status, [:websocket], %{})

      # Transform flat structure to nested structure expected by HTML template
      websocket_stats = %{
        connections: %{
          active: Utils.safe_get(raw_websocket_stats, [:connections_active], 0),
          total: Utils.safe_get(raw_websocket_stats, [:connections_total], 0)
        },
        subscriptions: %{
          active: Utils.safe_get(raw_websocket_stats, [:subscriptions_active], 0),
          systems: Utils.safe_get(raw_websocket_stats, [:subscriptions_systems], 0),
          characters: Utils.safe_get(raw_websocket_stats, [:subscriptions_characters], 0)
        },
        kills_sent: %{
          total: Utils.safe_get(raw_websocket_stats, [:kills_sent_total], 0),
          realtime: Utils.safe_get(raw_websocket_stats, [:kills_sent_realtime], 0),
          preload: Utils.safe_get(raw_websocket_stats, [:kills_sent_preload], 0)
        }
      }

      # Get uptime and version safely
      uptime = format_uptime(Utils.safe_get(status, [:system, :uptime_seconds], 0))

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
      %{details: %{components: components}} when is_map(components) ->
        case Map.get(components, key) do
          %{} = health_data ->
            Logger.debug("#{key} health: #{inspect(health_data)}")
            # Extract metrics from the component data
            extract_component_metrics(health_data, key)

          _ ->
            Logger.debug("No #{key} health data found, using default")
            default_health_status()
        end

      _ ->
        Logger.debug(
          "Using default #{key} health due to unexpected format: #{inspect(full_health)}"
        )

        default_health_status()
    end
  end

  defp extract_component_metrics(health_data, :application) do
    # For application health, get the actual metrics from the health check
    case HealthChecks.get_application_metrics() do
      {:ok, %{metrics: %{system: system_metrics}}} ->
        memory_mb = calculate_memory_mb(system_metrics)

        %{
          status: Map.get(health_data, :status, "healthy"),
          metrics: %{
            memory_mb: memory_mb,
            process_count: Map.get(system_metrics, :process_count, 0),
            scheduler_usage: calculate_scheduler_usage(),
            uptime_seconds: Map.get(system_metrics, :uptime_seconds, 0)
          }
        }

      _ ->
        Logger.debug("Failed to get application metrics, using health data")
        health_data
    end
  end

  defp extract_component_metrics(health_data, :cache) do
    # For cache health, get the actual metrics from the cache health check
    case HealthChecks.get_cache_metrics() do
      {:ok, %{metrics: %{aggregate: aggregate_metrics, caches: caches}}} ->
        # Get the first cache's actual metrics since aggregate might be empty
        cache_data = List.first(caches) || %{}

        %{
          status: Map.get(health_data, :status, "healthy"),
          metrics: %{
            hit_rate:
              Map.get(cache_data, :hit_rate, Map.get(aggregate_metrics, :average_hit_rate, 0.0)),
            size: Map.get(cache_data, :size, Map.get(aggregate_metrics, :total_size, 0)),
            eviction_count: Map.get(aggregate_metrics, :total_evictions, 0),
            expiration_count: Map.get(aggregate_metrics, :total_expirations, 0)
          }
        }

      _ ->
        Logger.debug("Failed to get cache metrics, using health data")
        health_data
    end
  end

  defp calculate_memory_mb(system_metrics) do
    case Map.get(system_metrics, :memory_usage) do
      memory_usage when is_list(memory_usage) ->
        total_bytes = Keyword.get(memory_usage, :total, 0)
        Float.round(total_bytes / (1024 * 1024), 2)

      _ ->
        0
    end
  end

  defp calculate_scheduler_usage do
    try do
      # Get scheduler utilization (this is an approximation)
      run_queue = :erlang.statistics(:run_queue)
      schedulers = :erlang.system_info(:schedulers)

      # Calculate as percentage of run queue vs available schedulers
      usage = run_queue / schedulers * 100
      Float.round(min(usage, 100.0), 1)
    rescue
      _ -> 0.0
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
    # Extract RedisQ metrics from the :processing section
    total_processed = Utils.safe_get(status, [:processing, :redisq_received], 0)

    last_killmail_ago =
      Utils.safe_get(status, [:processing, :redisq_last_killmail_ago_seconds], nil)

    processing_lag = Utils.safe_get(status, [:processing, :processing_lag_seconds], 0)

    # Calculate processing rate using window-based statistics
    processing_rate = calculate_current_processing_rate(status)

    # Format last processed time
    last_processed = format_last_processed_time(last_killmail_ago)

    %{
      total_processed: total_processed,
      processing_rate: processing_rate,
      last_processed: last_processed,
      # Convert seconds to milliseconds
      queue_lag: round(processing_lag * 1000),
      status: if(total_processed > 0, do: "active", else: "idle")
    }
  end

  defp calculate_current_processing_rate(status) do
    # Get the raw RedisQ stats from ETS for more accurate rate calculation
    case :ets.info(EtsOwner.wanderer_kills_stats_table()) do
      :undefined ->
        # If ETS table is not available, fall back to simple calculation
        total = Utils.safe_get(status, [:processing, :redisq_received], 0)
        calculate_simple_rate_from_total(total)

      _ ->
        # Try to get the raw stats with window information
        calculate_rate_from_ets_stats(status)
    end
  end

  defp calculate_rate_from_ets_stats(status) do
    case :ets.lookup(EtsOwner.wanderer_kills_stats_table(), :redisq_stats) do
      [{:redisq_stats, stats}] when is_map(stats) ->
        calculate_rate_from_window_stats(stats)

      _ ->
        # No stats available, use simple calculation
        total = Utils.safe_get(status, [:processing, :redisq_received], 0)
        calculate_simple_rate_from_total(total)
    end
  end

  defp calculate_rate_from_window_stats(stats) do
    # RedisQ tracks kills_received in 60-second windows
    # Use the window stats for a more accurate current rate
    window_kills = Map.get(stats, :kills_received, 0)
    last_reset = Map.get(stats, :last_reset, DateTime.utc_now())

    # Calculate seconds since last reset
    seconds_elapsed = DateTime.diff(DateTime.utc_now(), last_reset, :second)

    if seconds_elapsed > 0 and seconds_elapsed <= @redisq_window_staleness_seconds do
      # If we have a valid window (not stale), calculate rate
      # Normalize to per-minute rate
      round(window_kills * 60 / seconds_elapsed)
    else
      # Fall back to simple calculation if window is stale
      total = Map.get(stats, :total_kills_received, 0)
      calculate_simple_rate_from_total(total)
    end
  end

  defp calculate_simple_rate_from_total(total_processed) do
    # Fallback: Simple average since startup
    uptime_minutes = max(1, div(uptime_seconds(), 60))
    round(total_processed / uptime_minutes)
  end

  defp format_last_processed_time(nil), do: "Never"

  defp format_last_processed_time(seconds_ago) when is_number(seconds_ago) do
    cond do
      seconds_ago >= 999_999 -> "Never"
      seconds_ago < 60 -> "#{round(seconds_ago)} seconds ago"
      seconds_ago < 3600 -> "#{round(seconds_ago / 60)} minutes ago"
      seconds_ago < 86_400 -> "#{round(seconds_ago / 3600)} hours ago"
      true -> "#{round(seconds_ago / 86_400)} days ago"
    end
  end

  defp format_last_processed_time(_value), do: "Unknown"

  # Returns the Erlang VM's wall clock time since start (not the specific application runtime)
  # This represents how long the BEAM VM has been running, which may be longer than
  # the actual application uptime if the VM was started before the application
  defp uptime_seconds do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    div(uptime_ms, 1000)
  end
end
