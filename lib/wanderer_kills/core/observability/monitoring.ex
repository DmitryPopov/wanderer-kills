defmodule WandererKills.Core.Observability.Monitoring do
  @moduledoc """
  Unified monitoring and observability for the WandererKills application.

  This module consolidates health monitoring, metrics collection, telemetry measurements,
  and instrumentation functionality into a single observability interface.

  ## Features

  - Cache health monitoring and metrics collection
  - Application health status and uptime tracking
  - Telemetry measurements and periodic data gathering
  - Unified error handling and logging
  - Periodic health checks with configurable intervals
  - System metrics collection (memory, CPU, processes)

  ## Usage

  ```elixir
  # Start the monitoring GenServer
  {:ok, pid} = Monitoring.start_link([])

  # Check overall health
  {:ok, health} = Monitoring.check_health()

  # Get metrics
  {:ok, metrics} = Monitoring.get_metrics()

  # Get stats for a specific cache
  {:ok, stats} = Monitoring.get_cache_stats(:killmails_cache)

  # Telemetry measurements (called by TelemetryPoller)
  Monitoring.measure_http_requests()
  Monitoring.measure_cache_operations()
  Monitoring.measure_fetch_operations()
  ```

  ## Cache Names

  The following cache names are monitored:
  - `:wanderer_cache` - Unified cache with namespaced keys (killmails, systems, ESI data)
  """

  use GenServer
  require Logger
  alias WandererKills.Core.Cache
  alias WandererKills.Core.EtsOwner
  alias WandererKills.Core.Observability.Metrics
  alias WandererKills.Core.Support.Clock

  @cache_names [:wanderer_cache]
  @health_check_interval :timer.minutes(5)
  @summary_interval :timer.minutes(5)

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
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
    GenServer.call(__MODULE__, :check_health)
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
    GenServer.call(__MODULE__, :get_metrics)
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
    cache_metrics =
      case Cache.size() do
        {:ok, size} -> size
        _ -> 0
      end

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

  @impl true
  def handle_call(:check_health, _from, state) do
    health = build_comprehensive_health_status()
    {:reply, {:ok, health}, state}
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    metrics = build_comprehensive_metrics()
    {:reply, {:ok, metrics}, state}
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
    _health = build_comprehensive_health_status()
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

  @spec build_comprehensive_health_status() :: map()
  defp build_comprehensive_health_status do
    cache_checks = Enum.map(@cache_names, &build_cache_health_check/1)
    sse_health = build_sse_health_check()

    all_healthy = Enum.all?(cache_checks, & &1.healthy) and sse_health.healthy

    %{
      healthy: all_healthy,
      timestamp: Clock.now_iso8601(),
      version: get_app_version(),
      uptime_seconds: get_uptime_seconds(),
      caches: cache_checks,
      sse: sse_health,
      system: get_system_info()
    }
  end

  @spec build_comprehensive_metrics() :: map()
  defp build_comprehensive_metrics do
    cache_metrics = Enum.map(@cache_names, &build_cache_metrics/1)
    sse_metrics = build_sse_metrics()

    %{
      timestamp: Clock.now_iso8601(),
      uptime_seconds: get_uptime_seconds(),
      caches: cache_metrics,
      sse: sse_metrics,
      system: get_system_info(),
      rate_limiter: collect_rate_limiter_metrics(),
      aggregate: %{
        total_cache_size: Enum.sum(Enum.map(cache_metrics, &Map.get(&1, :size, 0))),
        average_hit_rate: calculate_average_hit_rate(cache_metrics)
      }
    }
  end

  @spec build_cache_health_check(atom()) :: map()
  defp build_cache_health_check(cache_name) do
    case Cache.health() do
      {:ok, health} ->
        Map.put(health, :name, cache_name)
    end
  rescue
    error ->
      Logger.error(
        "[Monitoring] Cache health check exception for #{cache_name}: #{inspect(error)}"
      )

      %{name: cache_name, healthy: false, status: "unavailable"}
  end

  @spec build_cache_metrics(atom()) :: map()
  defp build_cache_metrics(cache_name) do
    case Cache.stats() do
      {:ok, stats} ->
        size = Map.get(stats, :size, 0)

        %{
          name: cache_name,
          size: size,
          hit_rate: Map.get(stats, :hit_rate, 0.0),
          miss_rate: Map.get(stats, :miss_rate, 0.0),
          evictions: Map.get(stats, :evictions, 0),
          operations: Map.get(stats, :operations, 0),
          memory: Map.get(stats, :memory, 0)
        }

      {:error, reason} ->
        Logger.error(
          "[Monitoring] Cache metrics collection failed for #{cache_name}: #{inspect(reason)}"
        )

        %{name: cache_name, error: "Unable to retrieve stats", reason: inspect(reason)}
    end
  end

  @spec get_cache_stats_internal(atom()) :: {:ok, map()} | {:error, term()}
  defp get_cache_stats_internal(_cache_name) do
    # Use unified cache API which already includes size in stats
    Cache.stats()
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

  @spec calculate_average_hit_rate([map()]) :: float()
  defp calculate_average_hit_rate(cache_metrics) do
    valid_metrics = Enum.reject(cache_metrics, &Map.has_key?(&1, :error))

    case valid_metrics do
      [] ->
        0.0

      metrics ->
        hit_rates = Enum.map(metrics, &Map.get(&1, :hit_rate, 0.0))
        Enum.sum(hit_rates) / length(hit_rates)
    end
  end

  defp get_app_version do
    Application.spec(:wanderer_kills, :vsn)
    |> to_string()
  rescue
    _ -> "unknown"
  end

  defp get_uptime_seconds do
    :erlang.statistics(:wall_clock)
    |> elem(0)
    |> div(1000)
  end

  @spec collect_rate_limiter_metrics() :: map()
  defp collect_rate_limiter_metrics do
    features = Application.get_env(:wanderer_kills, :features, [])

    base_metrics = %{
      smart_rate_limiting_enabled: features[:smart_rate_limiting] || false,
      request_coalescing_enabled: features[:request_coalescing] || false
    }

    smart_limiter_stats = collect_smart_limiter_stats(features[:smart_rate_limiting])
    coalescer_stats = collect_coalescer_stats(features[:request_coalescing])

    Map.merge(base_metrics, %{
      smart_rate_limiter: smart_limiter_stats,
      request_coalescer: coalescer_stats
    })
  end

  defp collect_smart_limiter_stats(true) do
    case WandererKills.Ingest.SmartRateLimiter.get_stats() do
      {:ok, stats} ->
        %{
          queue_size: stats.queue_size,
          pending_requests: stats.pending_requests,
          current_tokens: stats.current_tokens,
          circuit_state: stats.circuit_state,
          failure_count: stats.failure_count,
          detected_window_ms: stats.detected_window_ms
        }

      {:error, reason} ->
        %{error: "smart_rate_limiter_unreachable", reason: inspect(reason)}

      _ ->
        %{error: "smart_rate_limiter_unreachable"}
    end
  end

  defp collect_smart_limiter_stats(_), do: %{}

  defp collect_coalescer_stats(true) do
    case WandererKills.Ingest.RequestCoalescer.get_stats() do
      {:ok, stats} ->
        %{
          pending_requests: stats.pending_requests,
          total_requesters: stats.total_requesters
        }

      {:error, reason} ->
        %{error: "request_coalescer_unreachable", reason: inspect(reason)}

      _ ->
        %{error: "request_coalescer_unreachable"}
    end
  end

  defp collect_coalescer_stats(_), do: %{}

  @spec build_sse_health_check() :: map()
  defp build_sse_health_check do
    # SSE connections are now managed by sse_phoenix_pubsub library
    %{
      healthy: true,
      status: "managed_by_library",
      active_connections: 0,
      max_connections: 0,
      utilization: 0.0
    }
  end

  @spec build_sse_metrics() :: map()
  defp build_sse_metrics do
    # SSE connections are now managed by sse_phoenix_pubsub library
    %{
      connections_active: 0,
      connections_total: 0,
      connections_closed: 0,
      events_sent: 0,
      connections_by_ip: 0,
      manager_status: "managed_by_library"
    }
  end
end
