defmodule WandererKills.Core.Observability.Monitoring do
  @moduledoc """
  Consolidated monitoring and observability for the WandererKills application.

  This module consolidates functionality from monitoring.ex, unified_status.ex, and parts
  of statistics.ex into a single observability interface. It provides:

  - System health monitoring and status reporting
  - Unified status aggregation and periodic reporting
  - Statistical calculations and aggregations
  - Telemetry measurements and periodic data gathering
  - System resource monitoring
  - Parser statistics tracking

  ## Features

  - Cache health monitoring and metrics collection
  - Application health status and uptime tracking
  - Periodic status reporting with comprehensive system overview
  - System metrics collection (memory, CPU, processes)
  - API and WebSocket performance tracking
  - Statistical calculations for rates, percentages, and aggregations

  ## Usage

  ```elixir
  # Start the monitoring GenServer
  {:ok, pid} = Monitoring.start_link([])

  # Check overall health
  {:ok, health} = Monitoring.check_health()

  # Get unified status report
  status = Monitoring.get_unified_status()

  # Force immediate status report
  Monitoring.report_status_now()

  # Get stats for a specific cache
  {:ok, stats} = Monitoring.get_cache_stats(:wanderer_cache)
  ```
  """

  use GenServer
  require Logger
  alias WandererKills.Core.Cache
  alias WandererKills.Core.EtsOwner
  alias WandererKills.Core.Observability.{Health, Metrics}

  @health_check_interval :timer.minutes(5)
  @summary_interval :timer.minutes(5)

  @typedoc "Internal server state"
  @type state :: %{
          interval_ms: pos_integer(),
          last_report_at: DateTime.t(),
          parser_stats: map()
        }

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ============================================================================
  # Unified Status Functions (from unified_status.ex)
  # ============================================================================

  @doc """
  Generates and logs a comprehensive status report immediately (asynchronous).

  Note: This function uses GenServer.cast which is asynchronous and does not 
  guarantee message delivery. Use report_status_now_sync/1 if you need 
  synchronous delivery with timeout.
  """
  @spec report_status_now() :: :ok
  def report_status_now do
    GenServer.cast(__MODULE__, :report_now)
  end

  @doc """
  Generates and logs a comprehensive status report immediately (synchronous).

  This ensures the message is received and handled, but may block the caller.
  """
  @spec report_status_now_sync(timeout()) :: :ok
  def report_status_now_sync(timeout \\ 5000) do
    GenServer.call(__MODULE__, :report_now, timeout)
  end

  @doc """
  Gets the current unified status of all subsystems.
  """
  @spec get_unified_status() :: map()
  def get_unified_status do
    GenServer.call(__MODULE__, :get_unified_status, 5000)
  rescue
    error in [ErlangError] ->
      if match?({:timeout, _}, error.original) do
        # Return empty status on timeout
        %{
          system: %{uptime_seconds: 0},
          websocket: %{},
          processing: %{
            redisq_received: 0,
            redisq_last_killmail_ago_seconds: nil,
            processing_lag_seconds: 0
          }
        }
      else
        reraise error, __STACKTRACE__
      end
  end

  @doc """
  Performs a comprehensive health check of the application.

  Returns a map with health status for each cache and overall application status,
  including version, uptime, and timestamp information.

  ## Returns
  - `{:ok, health_map}` - Complete health status
  - `{:error, reason}` - If health check fails entirely

  ## Example

  ```elixir
  {:ok, health} = check_health()
  # %{
  #   healthy: true,
  #   timestamp: "2024-01-01T12:00:00Z",
  #   version: "1.0.0",
  #   uptime_seconds: 3600,
  #   caches: [
  #     %{name: :wanderer_cache, healthy: true, status: "ok"}
  #   ]
  # }
  ```
  """
  @spec check_health() :: {:ok, map()} | {:error, term()}
  def check_health do
    # Delegate to the new consolidated Health module
    Health.check_health()
  end

  @doc """
  Gets comprehensive metrics for all monitored caches and application stats.

  Returns cache statistics and application metrics that can be used for
  monitoring, alerting, and performance analysis.

  ## Returns
  - `{:ok, metrics_map}` - Metrics for all caches and app stats
  - `{:error, reason}` - If metrics collection fails

  ## Example

  ```elixir
  {:ok, metrics} = get_metrics()
  # %{
  #   timestamp: "2024-01-01T12:00:00Z",
  #   uptime_seconds: 3600,
  #   caches: [
  #     %{name: :wanderer_cache, size: 1000, hit_rate: 0.85, miss_rate: 0.15}
  #   ]
  # }
  ```
  """
  @spec get_metrics() :: {:ok, map()} | {:error, term()}
  def get_metrics do
    # Delegate to the new consolidated Health module
    Health.get_metrics()
  end

  @doc """
  Get telemetry data for all monitored caches.

  This is an alias for `get_metrics/0` as telemetry and metrics
  are essentially the same data in this context.

  ## Returns
  - `{:ok, telemetry_map}` - Telemetry data for all caches
  - `{:error, reason}` - If telemetry collection fails
  """
  @spec get_telemetry() :: {:ok, map()} | {:error, term()}
  def get_telemetry do
    get_metrics()
  end

  @doc """
  Get statistics for a specific cache.

  ## Parameters
  - `cache_name` - The name of the cache to get stats for

  ## Returns
  - `{:ok, stats}` - Cache statistics map
  - `{:error, reason}` - If stats collection fails

  ## Example

  ```elixir
  {:ok, stats} = get_cache_stats(:wanderer_cache)
  # %{hit_rate: 0.85, size: 1000, evictions: 10, ...}
  ```
  """
  @spec get_cache_stats(atom()) :: {:ok, map()} | {:error, term()}
  def get_cache_stats(cache_name) do
    GenServer.call(__MODULE__, {:get_cache_stats, cache_name})
  end

  # Parser statistics functions

  @doc """
  Increments the count of successfully stored killmails.
  Updates internal state and delegates to the unified Metrics module.
  """
  @spec increment_stored() :: :ok
  def increment_stored do
    GenServer.cast(__MODULE__, {:increment, :stored})
  end

  @doc """
  Increments the count of skipped killmails (too old).
  Updates internal state and delegates to the unified Metrics module.
  """
  @spec increment_skipped() :: :ok
  def increment_skipped do
    GenServer.cast(__MODULE__, {:increment, :skipped})
  end

  @doc """
  Increments the count of failed killmail parsing attempts.
  Updates internal state and delegates to the unified Metrics module.
  """
  @spec increment_failed() :: :ok
  def increment_failed do
    GenServer.cast(__MODULE__, {:increment, :failed})
  end

  @doc """
  Gets the current parsing statistics.
  """
  @spec get_parser_stats() :: {:ok, map()} | {:error, term()}
  def get_parser_stats do
    GenServer.call(__MODULE__, :get_parser_stats)
  end

  @doc """
  Resets all parser statistics counters to zero.
  """
  @spec reset_parser_stats() :: :ok
  def reset_parser_stats do
    GenServer.call(__MODULE__, :reset_parser_stats)
  end

  # Telemetry measurement functions (called by TelemetryPoller)

  @doc """
  Measures HTTP request metrics for telemetry.

  This function is called by TelemetryPoller to emit HTTP request metrics.
  """
  @spec measure_http_requests() :: :ok
  def measure_http_requests do
    :telemetry.execute(
      [:wanderer_kills, :system, :http_requests],
      %{count: :erlang.statistics(:reductions) |> elem(0)},
      %{}
    )
  end

  @doc """
  Measures cache operation metrics for telemetry.

  This function is called by TelemetryPoller to emit cache operation metrics.
  """
  @spec measure_cache_operations() :: :ok
  def measure_cache_operations do
    cache_metrics = Cache.size()

    :telemetry.execute(
      [:wanderer_kills, :system, :cache_operations],
      %{total_cache_size: cache_metrics},
      %{}
    )
  end

  @doc """
  Measures fetch operation metrics for telemetry.

  This function is called by TelemetryPoller to emit fetch operation metrics.
  """
  @spec measure_fetch_operations() :: :ok
  def measure_fetch_operations do
    process_count = :erlang.system_info(:process_count)

    :telemetry.execute(
      [:wanderer_kills, :system, :fetch_operations],
      %{process_count: process_count},
      %{}
    )
  end

  @doc """
  Measures system resource metrics for telemetry.

  This function emits comprehensive system metrics including memory and CPU usage.
  """
  @spec measure_system_resources() :: :ok
  def measure_system_resources do
    memory_info = :erlang.memory()

    :telemetry.execute(
      [:wanderer_kills, :system, :memory],
      %{
        total_memory: memory_info[:total],
        process_memory: memory_info[:processes],
        atom_memory: memory_info[:atom],
        binary_memory: memory_info[:binary]
      },
      %{}
    )

    # Process and scheduler metrics
    :telemetry.execute(
      [:wanderer_kills, :system, :cpu],
      %{
        process_count: :erlang.system_info(:process_count),
        port_count: :erlang.system_info(:port_count),
        schedulers: :erlang.system_info(:schedulers),
        run_queue: :erlang.statistics(:run_queue)
      },
      %{}
    )
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Logger.info("[Monitoring] Starting unified monitoring with periodic health checks")

    # Start periodic health checks if not disabled in opts
    if !Keyword.get(opts, :disable_periodic_checks, false) do
      schedule_health_check()
    end

    # Schedule parser stats summary
    schedule_parser_summary()

    state = %{
      parser_stats: %{
        stored: 0,
        skipped: 0,
        failed: 0,
        total_processed: 0,
        last_reset: DateTime.utc_now()
      }
    }

    {:ok, state}
  end

  # Health and metrics checks now delegated to Health module
  # Keeping these for backward compatibility if called directly
  @impl true
  def handle_call(:check_health, _from, state) do
    result = Health.check_health()
    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    result = Health.get_metrics()
    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_cache_stats, cache_name}, _from, state) do
    stats = get_cache_stats_internal(cache_name)
    {:reply, stats, state}
  end

  @impl true
  def handle_call(:get_parser_stats, _from, state) do
    {:reply, {:ok, state.parser_stats}, state}
  end

  @impl true
  def handle_call(:reset_parser_stats, _from, state) do
    new_parser_stats = %{
      stored: 0,
      skipped: 0,
      failed: 0,
      total_processed: 0,
      last_reset: DateTime.utc_now()
    }

    new_state = %{state | parser_stats: new_parser_stats}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_unified_status, _from, state) do
    # Build unified status structure expected by Dashboard
    unified_status = build_unified_status(state)
    {:reply, unified_status, state}
  end

  @impl true
  def handle_call(:report_now, _from, state) do
    # Generate and log comprehensive status report immediately
    unified_status = build_unified_status(state)
    log_status_report(unified_status)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:increment, key}, state) when key in [:stored, :skipped, :failed] do
    Logger.debug("[Monitoring] GenServer handle_cast increment #{key}")
    current_stats = state.parser_stats

    new_stats =
      current_stats
      |> Map.update!(key, &(&1 + 1))
      |> Map.update!(:total_processed, &(&1 + 1))

    # Update unified metrics after successfully updating internal state
    case key do
      :stored -> Metrics.increment_stored()
      :skipped -> Metrics.increment_skipped()
      :failed -> Metrics.increment_failed()
    end

    Logger.debug("[Monitoring] Updated parser_stats: #{inspect(new_stats)}")
    new_state = %{state | parser_stats: new_stats}
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:check_health, state) do
    Logger.debug("[Monitoring] Running periodic health check")
    # Delegate to Health module for consistency
    _health = Health.check_health()
    schedule_health_check()
    {:noreply, state}
  end

  @impl true
  def handle_info(:log_parser_summary, state) do
    stats = state.parser_stats

    # Store parser stats in ETS for unified status reporter
    if :ets.info(EtsOwner.wanderer_kills_stats_table()) != :undefined do
      :ets.insert(EtsOwner.wanderer_kills_stats_table(), {:parser_stats, stats})
    end

    # Note: Summary logging now handled by UnifiedStatus module
    # Only log if there's significant error activity
    if stats.failed > 10 do
      Logger.warning(
        "[Parser] High error rate detected",
        parser_errors: stats.failed,
        parser_total_processed: stats.total_processed
      )
    end

    # Emit telemetry for the summary
    :telemetry.execute(
      [:wanderer_kills, :parser, :summary],
      %{stored: stats.stored, skipped: stats.skipped, failed: stats.failed},
      %{}
    )

    # Reset counters after summary
    new_parser_stats = %{
      stored: 0,
      skipped: 0,
      failed: 0,
      total_processed: 0,
      last_reset: DateTime.utc_now()
    }

    schedule_parser_summary()
    new_state = %{state | parser_stats: new_parser_stats}
    {:noreply, new_state}
  end

  # Private helper functions

  defp schedule_health_check do
    Process.send_after(self(), :check_health, @health_check_interval)
  end

  defp schedule_parser_summary do
    Process.send_after(self(), :log_parser_summary, @summary_interval)
  end

  @spec log_status_report(map()) :: :ok
  defp log_status_report(unified_status) do
    system_info = format_system_status(unified_status)
    websocket_info = format_websocket_status(unified_status)
    processing_info = format_processing_status(unified_status)
    storage_info = format_storage_status(unified_status)
    api_info = format_api_status(unified_status)
    parser_info = format_parser_status(unified_status)

    Logger.info("""
    [Monitoring] Status Report:
    #{system_info}
    #{websocket_info}
    #{processing_info}
    #{storage_info}
    #{api_info}
    #{parser_info}
    """)
  end

  defp format_system_status(unified_status) do
    memory = get_in(unified_status, [:system, :memory_mb]) || "N/A"
    processes = get_in(unified_status, [:system, :process_count]) || "N/A"
    "System - Memory: #{memory}MB, Processes: #{processes}"
  end

  defp format_websocket_status(unified_status) do
    active = get_in(unified_status, [:websocket, :active_connections]) || 0
    total = get_in(unified_status, [:websocket, :total_connections]) || 0
    "WebSocket - Active: #{active}, Total: #{total}"
  end

  defp format_processing_status(unified_status) do
    queued = get_in(unified_status, [:processing, :queued]) || 0
    processing = get_in(unified_status, [:processing, :processing]) || 0
    "Processing - Queued: #{queued}, Processing: #{processing}"
  end

  defp format_storage_status(unified_status) do
    cached = get_in(unified_status, [:storage, :cached_items]) || 0
    storage = get_in(unified_status, [:storage, :total_storage_mb]) || "N/A"
    "Storage - Cached: #{cached}, Total Storage: #{storage}MB"
  end

  defp format_api_status(unified_status) do
    requests_per_min = get_in(unified_status, [:api, :requests_per_minute]) || 0
    avg_response = get_in(unified_status, [:api, :avg_response_time]) || "N/A"
    "API - Requests/min: #{requests_per_min}, Avg Response: #{avg_response}ms"
  end

  defp format_parser_status(unified_status) do
    stored = get_in(unified_status.parser_stats, [:stored]) || 0
    skipped = get_in(unified_status.parser_stats, [:skipped]) || 0
    failed = get_in(unified_status.parser_stats, [:failed]) || 0
    "Parser - Stored: #{stored}, Skipped: #{skipped}, Failed: #{failed}"
  end

  # Health and metrics building functions removed - now delegated to Health module

  @spec build_unified_status(state()) :: map()
  defp build_unified_status(state) do
    # Get system info
    system_info = get_system_info()

    # Get websocket stats from ETS
    websocket_stats = get_websocket_stats()

    # Get processing stats from ETS
    processing_stats = get_processing_stats()

    # Get storage stats from ETS tables
    storage_stats = get_storage_stats()

    # Get API stats from ETS
    api_stats = get_api_stats()

    # Get SSE stats from ETS
    sse_stats = get_sse_stats()

    %{
      system:
        Map.merge(system_info, %{
          uptime_seconds: get_uptime_seconds()
        }),
      websocket: websocket_stats,
      processing: processing_stats,
      storage: storage_stats,
      api: api_stats,
      sse: sse_stats,
      parser_stats: state.parser_stats
    }
  end

  @spec get_websocket_stats() :: map()
  defp get_websocket_stats do
    # Try to get stats from ETS
    case :ets.lookup(EtsOwner.wanderer_kills_stats_table(), :websocket_stats) do
      [{:websocket_stats, stats}] ->
        stats

      _ ->
        %{
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
          connections: %{
            active: 0,
            total_connected: 0,
            total_disconnected: 0
          },
          subscriptions: %{
            active: 0,
            total_systems: 0,
            total_added: 0,
            total_removed: 0,
            total_characters: 0
          },
          kills_sent: %{
            total: 0,
            preload: 0,
            realtime: 0
          }
        }
    end
  end

  @spec get_processing_stats() :: map()
  defp get_processing_stats do
    # Try to get RedisQ stats from ETS
    redisq_stats =
      case :ets.lookup(EtsOwner.wanderer_kills_stats_table(), :redisq_stats) do
        [{:redisq_stats, stats}] -> stats
        _ -> %{}
      end

    # Calculate processing metrics
    redisq_received = Map.get(redisq_stats, :total_kills_received, 0)
    last_kill_at = Map.get(redisq_stats, :last_kill_received_at)

    last_killmail_ago_seconds =
      if last_kill_at do
        System.system_time(:second) - last_kill_at
      else
        # Never received
        999_999
      end

    %{
      redisq_received: redisq_received,
      redisq_last_killmail_ago_seconds: last_killmail_ago_seconds,
      # Not currently tracked
      processing_lag_seconds: 0
    }
  end

  @spec get_system_info() :: map()
  defp get_system_info do
    memory_info = :erlang.memory()

    %{
      memory: %{
        total: memory_info[:total],
        processes: memory_info[:processes],
        atom: memory_info[:atom],
        binary: memory_info[:binary]
      },
      processes: %{
        count: :erlang.system_info(:process_count),
        limit: :erlang.system_info(:process_limit)
      },
      ports: %{
        count: :erlang.system_info(:port_count),
        limit: :erlang.system_info(:port_limit)
      },
      schedulers: :erlang.system_info(:schedulers),
      run_queue: :erlang.statistics(:run_queue),
      ets_tables: length(:ets.all())
    }
  rescue
    error ->
      Logger.warning("Failed to collect system info: #{inspect(error)}")
      %{error: "System info collection failed"}
  end

  defp get_uptime_seconds do
    :erlang.statistics(:wall_clock)
    |> elem(0)
    |> div(1000)
  end

  @spec get_cache_stats_internal(atom()) :: map()
  defp get_cache_stats_internal(_cache_name) do
    # Use unified cache API which already includes size in stats
    Cache.stats()
  rescue
    error ->
      Logger.warning("Failed to get cache stats", error: inspect(error))
      %{}
  end

  # Helper functions removed - now part of Health module

  @spec get_storage_stats() :: map()
  defp get_storage_stats do
    # Get counts from ETS tables
    killmails_count = try_ets_info(:killmails, :size, 0)
    systems_count = try_ets_info(:system_killmails, :size, 0)

    %{
      killmails_count: killmails_count,
      systems_count: systems_count
    }
  end

  @spec get_api_stats() :: map()
  defp get_api_stats do
    # Try to get API stats from ETS
    zkb_stats =
      case :ets.lookup(EtsOwner.wanderer_kills_stats_table(), :zkb_api_stats) do
        [{:zkb_api_stats, stats}] ->
          stats

        _ ->
          %{
            total_requests: 0,
            requests_per_minute: 0,
            error_count: 0,
            avg_duration_ms: 0
          }
      end

    esi_stats =
      case :ets.lookup(EtsOwner.wanderer_kills_stats_table(), :esi_api_stats) do
        [{:esi_api_stats, stats}] ->
          stats

        _ ->
          %{
            total_requests: 0,
            requests_per_minute: 0,
            error_count: 0,
            avg_duration_ms: 0
          }
      end

    %{
      zkillboard: zkb_stats,
      esi: esi_stats
    }
  end

  @spec get_sse_stats() :: map()
  defp get_sse_stats do
    # Try to get SSE stats from ETS
    case :ets.lookup(EtsOwner.wanderer_kills_stats_table(), :sse_stats) do
      [{:sse_stats, stats}] ->
        stats

      _ ->
        %{
          events_sent_total: 0,
          connections_active: 0
        }
    end
  end

  defp try_ets_info(table, key, default) do
    case :ets.info(table) do
      :undefined -> default
      info -> Keyword.get(info, key, default)
    end
  end
end
