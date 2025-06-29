defmodule WandererKills.Core.Observability.UnifiedStatus do
  @moduledoc """
  Periodically aggregates metrics from *all* Wanderer Kills subsystems
  (API, pipeline, WebSocket, cache, etc.) into a single structured snapshot
  and logs an easy-to-read banner every `@report_interval_ms`.

      iex> WandererKills.Core.Observability.UnifiedStatus.report_now()
      :ok
  """

  use GenServer
  require Logger

  alias WandererKills.Core.Cache
  alias WandererKills.Core.EtsOwner
  alias WandererKills.Core.Observability.{ApiTracker, WebSocketStats}
  alias WandererKills.Ingest.RateLimiter

  @report_interval_ms 5 * 60 * 1_000

  @default_api_metrics %{
    requests_per_minute: 0,
    total_requests: 0,
    error_count: 0,
    avg_duration_ms: 0
  }

  @typedoc "Internal server state"
  @type state :: %__MODULE__{
          interval_ms: pos_integer(),
          last_report_at: DateTime.t()
        }
  defstruct interval_ms: @report_interval_ms, last_report_at: DateTime.utc_now()

  # ────────────────────────────  Public API  ────────────────────────────

  @spec start_link(GenServer.options()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec report_now() :: :ok
  def report_now, do: GenServer.cast(__MODULE__, :report_now)

  @spec get_status() :: map()
  def get_status, do: GenServer.call(__MODULE__, :get_status)

  # ────────────────────────────  GenServer  ─────────────────────────────

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @report_interval_ms)
    {:ok, %__MODULE__{interval_ms: interval}, {:continue, :schedule_report}}
  end

  @impl GenServer
  def handle_continue(:schedule_report, %__MODULE__{interval_ms: interval} = st) do
    schedule_next_report(interval)
    Logger.info("[UnifiedStatus] started (interval: #{interval / 1_000}s)")
    {:noreply, st}
  end

  @impl GenServer
  def handle_info(:generate_report, %__MODULE__{} = st) do
    generate_and_log_report(st)
    schedule_next_report(st.interval_ms)
    {:noreply, %{st | last_report_at: DateTime.utc_now()}}
  end

  @impl GenServer
  def handle_cast(:report_now, %__MODULE__{} = st) do
    generate_and_log_report(st)
    {:noreply, %{st | last_report_at: DateTime.utc_now()}}
  end

  @impl GenServer
  def handle_call(:get_status, _from, %__MODULE__{} = st) do
    {:reply, collect_all_metrics(), st}
  end

  # ────────────────────────────  Internals  ─────────────────────────────

  ## Scheduling

  defp schedule_next_report(interval_ms),
    do: Process.send_after(self(), :generate_report, interval_ms)

  ## Report generation

  defp generate_and_log_report(%__MODULE__{last_report_at: last} = _st) do
    metrics = collect_all_metrics()
    summary_mins = Float.round(DateTime.diff(DateTime.utc_now(), last, :second) / 60, 1)

    Logger.info(format_status_report(metrics, summary_mins), log_metadata(metrics))
  end

  defp log_metadata(metrics) do
    [
      api_zkb_rpm: get_in(metrics, [:api, :zkillboard, :requests_per_minute]),
      api_esi_rpm: get_in(metrics, [:api, :esi, :requests_per_minute]),
      killmails_stored: get_in(metrics, [:processing, :parser_stored]),
      websocket_connections: get_in(metrics, [:websocket, :connections_active]),
      sse_connections: get_in(metrics, [:sse, :connections_active]),
      cache_hit_rate: get_in(metrics, [:cache, :hit_rate]),
      cache_efficiency: get_in(metrics, [:cache, :cache_efficiency]),
      memory_mb: get_in(metrics, [:system, :memory_mb]),
      processing_lag: get_in(metrics, [:processing, :processing_lag_seconds]),
      parser_success_rate: get_in(metrics, [:processing, :parser_success_rate]),
      webhook_success_rate: get_in(metrics, [:preload, :webhook_success_rate])
    ]
  end

  ## Master collector

  defp collect_all_metrics do
    %{
      api: collect_api_metrics(),
      processing: collect_processing_metrics(),
      websocket: collect_websocket_metrics(),
      sse: collect_sse_metrics(),
      storage: collect_storage_metrics(),
      cache: collect_cache_metrics(),
      system: collect_system_metrics(),
      preload: collect_preload_metrics(),
      rate_limits: collect_rate_limit_status()
    }
  end

  # ────────────────────────────  Collectors  ────────────────────────────

  ### API

  defp collect_api_metrics do
    api_stats =
      safe_apply(ApiTracker, :get_stats, [], %{zkillboard: %{}, esi: %{}})

    %{
      zkillboard: enhance_api_metrics(Map.get(api_stats, :zkillboard, %{})),
      esi: enhance_api_metrics(Map.get(api_stats, :esi, %{}))
    }
  end

  defp enhance_api_metrics(stats) do
    enhanced = Map.merge(@default_api_metrics, stats)

    # Add calculated metrics
    enhanced
    |> Map.put(:error_rate, calculate_error_rate(enhanced))
    |> Map.put(:p95_duration_ms, Map.get(stats, :p95_duration_ms, enhanced.avg_duration_ms * 2))
    |> Map.put(:p99_duration_ms, Map.get(stats, :p99_duration_ms, enhanced.avg_duration_ms * 3))
  end

  defp calculate_error_rate(%{error_count: errors, total_requests: total}) when total > 0 do
    Float.round(errors / total * 100, 2)
  end

  defp calculate_error_rate(_), do: 0.0

  ### Processing

  defp collect_processing_metrics do
    redisq_stats = ets_get(EtsOwner.wanderer_kills_stats_table(), :redisq_stats, %{})
    parser_stats = ets_get(EtsOwner.wanderer_kills_stats_table(), :parser_stats, %{})

    redisq_received = Map.get(redisq_stats, :kills_received, 0)
    redisq_errors = Map.get(redisq_stats, :errors, 0)
    parser_stored = Map.get(parser_stats, :stored, 0)
    parser_failed = Map.get(parser_stats, :failed, 0)

    %{
      # RedisQ metrics
      redisq_received: redisq_received,
      redisq_older: Map.get(redisq_stats, :kills_older, 0),
      redisq_skipped: Map.get(redisq_stats, :kills_skipped, 0),
      redisq_errors: redisq_errors,
      redisq_error_rate: error_rate(redisq_errors, redisq_received),
      redisq_systems: redisq_stats |> Map.get(:active_systems, MapSet.new()) |> MapSet.size(),
      redisq_last_killmail_ago_seconds: seconds_since_last_killmail(redisq_stats),
      # Parser metrics
      parser_stored: parser_stored,
      parser_skipped: Map.get(parser_stats, :skipped, 0),
      parser_failed: parser_failed,
      parser_success_rate: success_rate(parser_stored, parser_failed),
      # Processing lag
      processing_lag_seconds: Map.get(redisq_stats, :processing_lag_seconds, 0)
    }
  end

  defp seconds_since_last_killmail(stats) do
    case Map.get(stats, :last_kill_received_at) do
      nil -> 999_999
      timestamp -> System.system_time(:second) - timestamp
    end
  end

  defp error_rate(errors, total) when total > 0, do: Float.round(errors / total * 100, 2)
  defp error_rate(_, _), do: 0.0

  defp success_rate(success, failed) do
    total = success + failed
    if total > 0, do: Float.round(success / total * 100, 1), else: 0.0
  end

  ### WebSocket

  defp collect_websocket_metrics do
    stats =
      ets_get(EtsOwner.wanderer_kills_stats_table(), :websocket_stats, nil) ||
        safe_apply(WebSocketStats, :get_stats, [], :unavailable)

    case stats do
      {:ok, s} -> format_ws_metrics(s)
      %{connections: _} = s -> format_ws_metrics(s)
      _ -> default_websocket_metrics()
    end
  end

  defp format_ws_metrics(stats) do
    %{
      connections_active: get_in(stats, [:connections, :active]) || 0,
      connections_total: get_in(stats, [:connections, :total_connected]) || 0,
      subscriptions_active: get_in(stats, [:subscriptions, :active]) || 0,
      subscriptions_systems: get_in(stats, [:subscriptions, :total_systems]) || 0,
      subscriptions_characters: get_in(stats, [:subscriptions, :total_characters]) || 0,
      kills_sent_realtime: get_in(stats, [:kills_sent, :realtime]) || 0,
      kills_sent_preload: get_in(stats, [:kills_sent, :preload]) || 0,
      kills_sent_total: get_in(stats, [:kills_sent, :total]) || 0
    }
  end

  defp default_websocket_metrics, do: format_ws_metrics(%{})

  ### Storage

  defp collect_storage_metrics do
    killmails = safe_ets_info(:killmails, :size)
    systems = safe_ets_info(:system_killmails, :size)

    %{
      killmails_count: killmails,
      systems_count: systems,
      # crude but cheap – 200B/killmail
      memory_mb: Float.round(killmails * 200 / 1_048_576, 1)
    }
  end

  ### Cache

  defp collect_cache_metrics do
    case Cache.stats() do
      {:ok, stats} ->
        size = Map.get(stats, :size, 0)
        hits = Map.get(stats, :hits, 0)
        misses = Map.get(stats, :misses, 0)
        evictions = Map.get(stats, :evictions, 0)
        expirations = Map.get(stats, :expirations, 0)

        %{
          size: size,
          memory_mb: Float.round(Map.get(stats, :memory_bytes, size * 1024) / 1_048_576, 1),
          hit_rate: hit_rate(hits, misses),
          miss_rate: hit_rate(misses, hits),
          evictions: evictions,
          expirations: expirations,
          # Actionable metrics
          eviction_rate: eviction_rate(evictions, size),
          cache_efficiency: cache_efficiency(hits, misses, evictions),
          operations_total: hits + misses,
          operations_per_minute: calculate_per_minute_rate(hits + misses)
        }

      _ ->
        %{
          size: 0,
          memory_mb: 0.0,
          hit_rate: 0.0,
          miss_rate: 0.0,
          evictions: 0,
          expirations: 0,
          eviction_rate: 0.0,
          cache_efficiency: 0.0,
          operations_total: 0,
          operations_per_minute: 0
        }
    end
  end

  defp eviction_rate(evictions, size) when size > 0, do: Float.round(evictions / size * 100, 1)
  defp eviction_rate(_, _), do: 0.0

  defp cache_efficiency(hits, misses, evictions) do
    total_ops = hits + misses

    if total_ops > 0 do
      # Efficiency is hits minus penalty for evictions
      efficiency = (hits - evictions * 0.5) / total_ops
      Float.round(max(0.0, efficiency) * 100, 1)
    else
      0.0
    end
  end

  defp calculate_per_minute_rate(count) do
    # Assumes 5-minute intervals
    round(count / 5)
  end

  ### System

  defp collect_system_metrics do
    m = :erlang.memory()
    proc_count = :erlang.system_info(:process_count)
    port_count = length(:erlang.ports())

    %{
      memory_mb: Float.round(m[:total] / 1_048_576, 1),
      memory_binary_mb: Float.round(m[:binary] / 1_048_576, 1),
      memory_processes_mb: Float.round(m[:processes] / 1_048_576, 1),
      memory_ets_mb: Float.round(m[:ets] / 1_048_576, 1),
      process_count: proc_count,
      port_count: port_count,
      scheduler_usage: scheduler_usage(),
      reductions_per_second: reductions_rate(),
      gc_runs: gc_stats(),
      uptime_hours: uptime_hours(),
      uptime_seconds: uptime_seconds()
    }
  end

  defp reductions_rate do
    {_, reds} = :erlang.statistics(:reductions)
    # Very rough estimate - would need to track over time for accuracy
    round(reds / max(1, uptime_seconds()))
  end

  defp gc_stats do
    {gc_count, _, _} = :erlang.statistics(:garbage_collection)
    gc_count
  end

  defp uptime_seconds do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    div(uptime_ms, 1000)
  end

  defp uptime_hours do
    Float.round(uptime_seconds() / 3600, 1)
  end

  defp scheduler_usage do
    schedulers = :erlang.system_info(:schedulers) |> max(1)
    queue = :erlang.statistics(:run_queue)

    Float.round(queue / schedulers * 100, 1)
  end

  ### Preload and Subscriptions

  defp collect_preload_metrics do
    # Get subscription manager stats if available
    sub_stats = safe_apply(WandererKills.Subs.SubscriptionManager, :get_stats, [], %{})

    # Get telemetry metrics for webhook/preload tracking
    telemetry_metrics =
      safe_apply(WandererKills.Core.Observability.TelemetryMetrics, :get_metrics, [], %{})

    # Count active supervised tasks (simplified approach)
    active_tasks = count_active_preload_tasks()

    %{
      # Preload task metrics
      active_tasks: active_tasks,
      completed_tasks: Map.get(telemetry_metrics, :preload_tasks_completed, 0),
      failed_tasks: Map.get(telemetry_metrics, :preload_tasks_failed, 0),
      total_delivered: Map.get(telemetry_metrics, :kills_delivered, 0),
      # Webhook metrics from telemetry
      webhooks_sent: Map.get(telemetry_metrics, :webhooks_sent, 0),
      webhooks_failed: Map.get(telemetry_metrics, :webhooks_failed, 0),
      webhook_success_rate: webhook_success_rate(telemetry_metrics),
      # Subscription metrics
      total_subscriptions:
        Map.get(sub_stats, :http_subscription_count, 0) +
          Map.get(sub_stats, :websocket_subscription_count, 0),
      active_webhooks: Map.get(sub_stats, :http_subscription_count, 0)
    }
  end

  defp count_active_preload_tasks do
    case Process.whereis(WandererKills.Core.Support.SupervisedTask.TaskSupervisor) do
      nil ->
        0

      supervisor_pid ->
        children = Supervisor.which_children(supervisor_pid)

        Enum.count(children, fn {_, pid, _, _} ->
          is_pid(pid) and Process.alive?(pid)
        end)
    end
  rescue
    _ -> 0
  end

  defp webhook_success_rate(%{webhooks_sent: sent, webhooks_failed: failed}) when sent > 0 do
    Float.round((sent - failed) / sent * 100, 1)
  end

  defp webhook_success_rate(%{sent: sent, failed: failed}) when sent > 0 do
    Float.round((sent - failed) / sent * 100, 1)
  end

  defp webhook_success_rate(_), do: 0.0

  ### Rate limits

  defp collect_rate_limit_status do
    %{
      zkillboard:
        format_bucket(safe_apply(RateLimiter, :get_bucket_state, [:zkillboard], :na), 10),
      esi: format_bucket(safe_apply(RateLimiter, :get_bucket_state, [:esi], :na), 100)
    }
  end

  defp format_bucket(%{tokens: t, capacity: c}, _), do: %{available: round(t), capacity: c}
  defp format_bucket(:na, capacity), do: %{available: 0, capacity: capacity}

  ### SSE

  defp collect_sse_metrics do
    # Get telemetry metrics for SSE event tracking
    telemetry_metrics =
      safe_apply(WandererKills.Core.Observability.TelemetryMetrics, :get_metrics, [], %{})

    # Extract SSE-specific telemetry metrics
    sse_telemetry = Map.get(telemetry_metrics, :sse, %{})

    # Get connection and event counts from telemetry
    connections_started = Map.get(telemetry_metrics, :sse_connections_started, 0)
    events_sent_total = Map.get(telemetry_metrics, :sse_events_sent, 0)

    %{
      # Connection metrics
      connections_total: connections_started,
      # Event metrics
      events_sent_total: events_sent_total,
      events_killmails: Map.get(sse_telemetry, :killmail_events, 0),
      events_heartbeats: Map.get(sse_telemetry, :heartbeat_events, 0),
      events_errors: Map.get(sse_telemetry, :error_events, 0),
      # Calculated metrics
      events_per_connection:
        if(connections_started > 0,
          do: Float.round(events_sent_total / connections_started, 1),
          else: 0.0
        )
    }
  end

  # ────────────────────────────  Utilities  ─────────────────────────────

  defp safe_apply(mod, fun, args, default) do
    cond do
      not Code.ensure_loaded?(mod) ->
        default

      not function_exported?(mod, fun, length(args)) ->
        default

      true ->
        try do
          apply(mod, fun, args)
        rescue
          _ -> default
        catch
          _, _ -> default
        end
    end
  end

  defp ets_get(tab, key, default) do
    case :ets.lookup(tab, key) do
      [{^key, val}] -> val
      _ -> default
    end
  end

  defp safe_ets_info(tab, field) do
    case :ets.info(tab, field) do
      :undefined -> 0
      n when is_integer(n) -> n
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp hit_rate(part, whole) do
    total = part + whole
    if total > 0, do: Float.round(part / total * 100, 1), else: 0.0
  end

  ## Pretty banner builder

  defp format_status_report(m, mins) do
    """
    ═══════════════════════════════════════════════════════════════════════
                     [STATUS] WANDERER KILLS STATUS (#{format_duration(mins)})
    ═══════════════════════════════════════════════════════════════════════

    [API] API Performance
    ─────────────────────────────────────────────────────────────────────
      zkillboard    #{format_metric(m.api.zkillboard.requests_per_minute, "rpm", 8)} │ #{format_metric(format_number(m.api.zkillboard.total_requests), "total", 12)} │ #{format_metric(m.api.zkillboard.error_rate, "% err", 10)}
                    Latency: #{format_latency_line(m.api.zkillboard)}

      ESI           #{format_metric(m.api.esi.requests_per_minute, "rpm", 8)} │ #{format_metric(format_number(m.api.esi.total_requests), "total", 12)} │ #{format_metric(m.api.esi.error_rate, "% err", 10)}
                    Latency: #{format_latency_line(m.api.esi)}

      Rate Limits   ZKB: #{format_rate_limit(m.rate_limits.zkillboard)}  │  ESI: #{format_rate_limit(m.rate_limits.esi)}

    [PROCESSING] Processing Pipeline
    ─────────────────────────────────────────────────────────────────────
      RedisQ        #{format_metric(format_number(m.processing.redisq_received), "received", 12)} │ #{format_metric(m.processing.redisq_systems, "systems", 10)} │ Last: #{format_duration_short(m.processing.redisq_last_killmail_ago_seconds)} ago
                    #{format_metric(m.processing.redisq_older, "old", 12)} │ #{format_metric(m.processing.redisq_skipped, "skipped", 10)} │ Error rate: #{m.processing.redisq_error_rate}%

      Parser        #{format_metric(format_number(m.processing.parser_stored), "stored", 12)} │ #{format_metric(m.processing.parser_failed, "failed", 10)} │ Success: #{m.processing.parser_success_rate}%
                    Skip: #{m.processing.parser_skipped} │ Process lag: #{m.processing.processing_lag_seconds}s

    [WEBSOCKET] WebSocket & Delivery
    ─────────────────────────────────────────────────────────────────────
      Connections   #{format_metric(m.websocket.connections_active, "active", 8)} / #{format_metric(m.websocket.connections_total, "total")}
      Subscriptions #{format_metric(m.websocket.subscriptions_active, "active", 8)} │ #{format_metric(m.websocket.subscriptions_systems, "systems", 10)} │ #{format_metric(m.websocket.subscriptions_characters, "characters")}
      Kills Sent    #{format_metric(format_number(m.websocket.kills_sent_total), "total", 8)} │ #{format_metric(m.websocket.kills_sent_realtime, "real-time", 12)} │ #{format_metric(m.websocket.kills_sent_preload, "preload")}

    [SSE] Server-Sent Events Streaming
    ─────────────────────────────────────────────────────────────────────
      Connections   #{format_metric(m.sse.connections_total, "total", 8)}
      Events Sent   #{format_metric(format_number(m.sse.events_sent_total), "total", 8)} │ #{format_metric(m.sse.events_killmails, "killmails", 12)} │ #{format_metric(m.sse.events_heartbeats, "heartbeats")}
      Performance   #{format_metric(m.sse.events_per_connection, "events/conn", 15)} │ #{format_metric(m.sse.events_errors, "errors")}

    [STORAGE] Storage & Cache
    ─────────────────────────────────────────────────────────────────────
      Killmails     #{format_metric(format_number(m.storage.killmails_count), "entries", 12)} │ #{format_metric(m.storage.systems_count, "systems", 10)} │ ~#{m.storage.memory_mb} MB

      Cache Stats   #{format_metric(format_number(m.cache.size), "entries", 12)} │ #{format_metric(m.cache.memory_mb, "MB", 10)}
                    Hit rate: #{m.cache.hit_rate}% │ Efficiency: #{m.cache.cache_efficiency}% │ Evictions: #{m.cache.eviction_rate}%
                    Operations: #{m.cache.operations_per_minute}/min │ Total: #{format_number(m.cache.operations_total)}

    [PRELOAD] Preload & Webhooks
    ─────────────────────────────────────────────────────────────────────
      Tasks         #{format_metric(m.preload.active_tasks, "active", 8)} │ #{format_metric(m.preload.completed_tasks, "completed", 12)} │ #{format_metric(m.preload.failed_tasks, "failed")}
      Delivery      #{format_metric(format_number(m.preload.total_delivered), "kills", 8)} │ #{format_metric(m.preload.total_subscriptions, "subs", 12)} │ #{format_metric(m.preload.active_webhooks, "webhooks")}
      Webhooks      #{format_metric(m.preload.webhooks_sent, "sent", 8)} │ #{format_metric(m.preload.webhooks_failed, "failed", 12)} │ Success: #{m.preload.webhook_success_rate}%

    [SYSTEM] System Resources
    ─────────────────────────────────────────────────────────────────────
      Memory        Total: #{format_metric(m.system.memory_mb, "MB", 8)} │ Binary: #{m.system.memory_binary_mb} MB │ Process: #{m.system.memory_processes_mb} MB │ ETS: #{m.system.memory_ets_mb} MB
      Processes     #{format_metric(format_number(m.system.process_count), "procs", 8)} │ #{format_metric(m.system.port_count, "ports", 8)} │ GC runs: #{format_number(m.system.gc_runs)}
      Performance   CPU: #{m.system.scheduler_usage}% │ Reductions: #{format_number(m.system.reductions_per_second)}/s │ Uptime: #{m.system.uptime_hours}h

    ═══════════════════════════════════════════════════════════════════════
    """
  end

  defp format_metric(value, label, width \\ 15) do
    formatted = "#{value} #{label}"
    String.pad_trailing(formatted, width)
  end

  defp format_latency_line(api_stats) do
    avg = format_ms(api_stats.avg_duration_ms)
    p95 = format_ms(api_stats.p95_duration_ms)
    p99 = format_ms(api_stats.p99_duration_ms)
    "avg #{avg} │ p95 #{p95} │ p99 #{p99}"
  end

  defp format_ms(ms) when is_float(ms), do: "#{Float.round(ms, 1)}ms"
  defp format_ms(ms), do: "#{ms}ms"

  defp format_rate_limit(%{available: avail, capacity: cap}) do
    utilization = round((cap - avail) / cap * 100)

    color =
      cond do
        utilization > 80 -> "HIGH"
        utilization > 50 -> "MED"
        true -> "LOW"
      end

    "#{color} #{avail}/#{cap}"
  end

  defp format_duration(mins) when is_float(mins), do: "#{Float.round(mins, 1)} min"

  defp format_duration_short(seconds) when seconds < 60, do: "#{seconds}s"

  defp format_duration_short(seconds) when seconds < 3600 do
    mins = div(seconds, 60)
    "#{mins}m"
  end

  defp format_duration_short(seconds) do
    hours = div(seconds, 3600)
    "#{hours}h"
  end

  defp format_number(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000.0, 1)} M"
  defp format_number(n) when n >= 1_000, do: "#{Float.round(n / 1_000.0, 1)} k"
  defp format_number(n) when is_integer(n), do: Integer.to_string(n)
  defp format_number(n) when is_float(n), do: Float.to_string(n)
  defp format_number(_), do: "0"
end
