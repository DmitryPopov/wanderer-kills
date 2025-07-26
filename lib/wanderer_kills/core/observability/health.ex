defmodule WandererKills.Core.Observability.Health do
  @moduledoc """
  Consolidated health check system for WandererKills.

  This module combines the functionality of the previous health check modules,
  providing a unified interface for all health monitoring needs. It includes:

  - Health check behaviour definition
  - Component health checks (cache, application, subscriptions)
  - Health aggregation across components
  - Metrics collection

  ## Architecture

  The health system is organized into:
  - **Behaviour Definition**: Standard interface for health checks
  - **Component Checks**: Specific health checks for each subsystem
  - **Aggregation**: Combines multiple health checks into a unified status

  ## Usage

  ```elixir
  # Get comprehensive health status
  {:ok, health} = Health.check_health()

  # Check specific components
  {:ok, cache_health} = Health.check_component(:cache)

  # Get metrics
  {:ok, metrics} = Health.get_metrics()
  ```
  """

  require Logger

  alias WandererKills.Core.Cache
  alias WandererKills.Core.Support.Error
  alias WandererKills.Core.Support.Utils
  alias WandererKills.Ingest.RequestCoalescer
  alias WandererKills.Ingest.SmartRateLimiter
  alias WandererKills.Subs.CharacterIndex
  alias WandererKills.Subs.SystemIndex

  # ============================================================================
  # Type Definitions
  # ============================================================================

  @type health_status :: %{
          healthy: boolean(),
          status: String.t(),
          details: map(),
          timestamp: String.t()
        }

  @type metrics :: %{
          component: String.t(),
          timestamp: String.t(),
          metrics: map()
        }

  @type health_opts :: keyword()
  @type component :: :cache | :application | :character_subscriptions | :system_subscriptions

  # ============================================================================
  # Behaviour Definition
  # ============================================================================

  @doc """
  Behaviour for health check implementations.
  """
  @callback check_health(health_opts()) :: health_status()
  @callback get_metrics(health_opts()) :: metrics()
  @callback default_config() :: keyword()

  @optional_callbacks [default_config: 0]

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Performs a comprehensive health check of all components.

  ## Options
  - `:components` - List of specific components to check (defaults to all)
  - `:timeout` - Timeout for health checks in milliseconds (default: 5000)
  - `:include_metrics` - Whether to include metrics in the response (default: false)
  """
  @spec check_health(health_opts()) :: {:ok, map()} | {:error, Error.t()}
  def check_health(opts \\ []) do
    components = Keyword.get(opts, :components, [:cache, :application, :subscriptions])
    _timeout = Keyword.get(opts, :timeout, 5_000)

    health_results =
      components
      |> Enum.map(&check_component(&1, opts))
      |> aggregate_health_results()

    {:ok, health_results}
  rescue
    error in [ErlangError] ->
      if match?({:timeout, _}, error.original) do
        timeout_ms = Keyword.get(opts, :timeout, 5_000)
        {:error, Error.timeout_error("Health check timed out after #{timeout_ms}ms")}
      else
        reraise error, __STACKTRACE__
      end
  end

  @doc """
  Checks health of a specific component.
  """
  @spec check_component(component(), health_opts()) :: health_status()
  def check_component(component, opts \\ [])

  def check_component(:cache, _opts) do
    check_cache_health()
  end

  def check_component(:application, opts) do
    check_application_health(opts)
  end

  def check_component(:character_subscriptions, _opts) do
    check_character_subscription_health()
  end

  def check_component(:system_subscriptions, _opts) do
    check_system_subscription_health()
  end

  def check_component(:subscriptions, _opts) do
    # Combined subscription health
    char_health = check_character_subscription_health()
    sys_health = check_system_subscription_health()

    aggregate_health_results([
      {:character_subscriptions, char_health},
      {:system_subscriptions, sys_health}
    ])
  end

  @doc """
  Retrieves metrics for all components or specific ones.
  """
  @spec get_metrics(health_opts()) :: {:ok, map()} | {:error, Error.t()}
  def get_metrics(opts \\ []) do
    components = Keyword.get(opts, :components, [:cache, :application, :subscriptions])

    metrics =
      components
      |> Enum.map(&get_component_metrics(&1, opts))
      |> Enum.into(%{})

    {:ok,
     %{
       timestamp: Utils.now_iso8601(),
       components: metrics
     }}
  end

  # ============================================================================
  # Component Health Checks
  # ============================================================================

  defp check_cache_health do
    case Cache.health() do
      :ok ->
        stats = Cache.stats()

        %{
          healthy: true,
          status: "ok",
          details: %{
            size: stats[:size] || 0,
            memory_bytes: stats[:memory] || 0,
            hit_rate: calculate_hit_rate(stats),
            # Individual namespace stats not aggregated
            namespace_stats: %{}
          },
          timestamp: Utils.now_iso8601()
        }

      {:error, reason} ->
        %{
          healthy: false,
          status: "error",
          details: %{error: inspect(reason)},
          timestamp: Utils.now_iso8601()
        }
    end
  end

  defp check_application_health(opts) do
    include_process_info = Keyword.get(opts, :include_process_info, false)

    base_health = %{
      memory_mb: :erlang.memory(:total) / 1_024 / 1_024,
      process_count: length(Process.list()),
      uptime_seconds: get_uptime_seconds(),
      version: Application.spec(:wanderer_kills, :vsn) |> to_string()
    }

    details =
      if include_process_info do
        Map.merge(base_health, %{
          processes: get_process_info(),
          ets_tables: get_ets_info()
        })
      else
        base_health
      end

    %{
      healthy: true,
      status: "ok",
      details: details,
      timestamp: Utils.now_iso8601()
    }
  end

  defp check_character_subscription_health do
    stats = CharacterIndex.get_stats()
    subscription_count = stats[:subscription_count] || 0
    character_count = stats[:character_count] || 0

    %{
      healthy: true,
      status: "ok",
      details: %{
        subscription_count: subscription_count,
        character_count: character_count,
        memory_bytes: stats[:memory_bytes] || 0,
        last_update: stats[:last_update] || "never"
      },
      timestamp: Utils.now_iso8601()
    }
  rescue
    error in [ErlangError] ->
      if match?({:noproc, _}, error.original) do
        %{
          healthy: false,
          status: "error",
          details: %{error: "CharacterIndex process not running"},
          timestamp: Utils.now_iso8601()
        }
      else
        reraise error, __STACKTRACE__
      end
  end

  defp check_system_subscription_health do
    stats = SystemIndex.get_stats()
    subscription_count = stats[:subscription_count] || 0
    system_count = stats[:system_count] || 0

    %{
      healthy: true,
      status: "ok",
      details: %{
        subscription_count: subscription_count,
        system_count: system_count,
        memory_bytes: stats[:memory_bytes] || 0,
        last_update: stats[:last_update] || "never"
      },
      timestamp: Utils.now_iso8601()
    }
  rescue
    error in [ErlangError] ->
      if match?({:noproc, _}, error.original) do
        %{
          healthy: false,
          status: "error",
          details: %{error: "SystemIndex process not running"},
          timestamp: Utils.now_iso8601()
        }
      else
        reraise error, __STACKTRACE__
      end
  end

  # ============================================================================
  # Component Metrics
  # ============================================================================

  defp get_component_metrics(:cache, _opts) do
    stats = Cache.stats()

    {:cache,
     %{
       size: stats[:size] || 0,
       memory_bytes: stats[:memory] || 0,
       operations: %{
         hits: stats[:hits] || 0,
         misses: stats[:misses] || 0,
         writes: stats[:writes] || 0,
         deletes: stats[:deletes] || 0
       }
     }}
  end

  defp get_component_metrics(:application, _opts) do
    {:application,
     %{
       memory: %{
         total_mb: :erlang.memory(:total) / 1_024 / 1_024,
         processes_mb: :erlang.memory(:processes) / 1_024 / 1_024,
         ets_mb: :erlang.memory(:ets) / 1_024 / 1_024
       },
       processes: %{
         count: length(Process.list()),
         limit: :erlang.system_info(:process_limit)
       },
       schedulers: %{
         online: :erlang.system_info(:schedulers_online),
         available: :erlang.system_info(:schedulers)
       },
       rate_limiter: collect_rate_limiter_metrics()
     }}
  end

  defp get_component_metrics(:subscriptions, _opts) do
    char_stats =
      try do
        CharacterIndex.get_stats()
      rescue
        _ -> %{}
      end

    sys_stats =
      try do
        SystemIndex.get_stats()
      rescue
        _ -> %{}
      end

    {:subscriptions,
     %{
       character_subscriptions: %{
         count: char_stats[:subscription_count] || 0,
         characters: char_stats[:character_count] || 0
       },
       system_subscriptions: %{
         count: sys_stats[:subscription_count] || 0,
         systems: sys_stats[:system_count] || 0
       }
     }}
  end

  defp get_component_metrics(component, opts) do
    # Handle individual subscription types
    case component do
      :character_subscriptions ->
        metrics = get_component_metrics(:subscriptions, opts)
        {:character_subscriptions, elem(metrics, 1).character_subscriptions}

      :system_subscriptions ->
        metrics = get_component_metrics(:subscriptions, opts)
        {:system_subscriptions, elem(metrics, 1).system_subscriptions}

      _ ->
        {component, %{}}
    end
  end

  # ============================================================================
  # Health Aggregation
  # ============================================================================

  defp aggregate_health_results(results) when is_list(results) do
    # If results are tuples {component, health}, extract health
    healths =
      Enum.map(results, fn
        {_component, health} -> health
        health -> health
      end)

    all_healthy = Enum.all?(healths, & &1.healthy)

    status =
      cond do
        all_healthy -> "ok"
        Enum.any?(healths, &(&1.status == "error")) -> "error"
        true -> "degraded"
      end

    # Aggregate details
    details =
      results
      |> Enum.map(fn
        {component, health} -> {component, health.details}
        health -> {:unknown, health.details}
      end)
      |> Enum.into(%{})

    %{
      healthy: all_healthy,
      status: status,
      details: details,
      timestamp: Utils.now_iso8601()
    }
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp calculate_hit_rate(%{hits: hits, misses: misses}) when hits + misses > 0 do
    Float.round(hits / (hits + misses) * 100, 2)
  end

  defp calculate_hit_rate(_), do: 0.0

  defp get_uptime_seconds do
    {uptime, _} = :erlang.statistics(:wall_clock)
    div(uptime, 1000)
  end

  defp get_process_info do
    Process.list()
    |> Enum.map(fn pid ->
      case Process.info(pid, [:registered_name, :memory, :message_queue_len]) do
        nil ->
          nil

        info ->
          %{
            pid: inspect(pid),
            name: Keyword.get(info, :registered_name, :unnamed),
            memory_bytes: Keyword.get(info, :memory, 0),
            message_queue_len: Keyword.get(info, :message_queue_len, 0)
          }
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.memory_bytes, :desc)
    |> Enum.take(10)
  end

  defp get_ets_info do
    :ets.all()
    |> Enum.map(fn table ->
      case :ets.info(table) do
        :undefined ->
          nil

        info ->
          %{
            name: Keyword.get(info, :name, table),
            size: Keyword.get(info, :size, 0),
            memory_bytes: Keyword.get(info, :memory, 0) * :erlang.system_info(:wordsize)
          }
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.memory_bytes, :desc)
    # Top 10 ETS tables by memory
    |> Enum.take(10)
  end

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
    case SmartRateLimiter.get_stats() do
      {:ok, stats} ->
        %{
          mode: Map.get(stats, :mode, :unknown),
          esi_tokens: Map.get(stats, :esi_tokens, 0),
          zkb_tokens: Map.get(stats, :zkb_tokens, 0),
          # These fields may not exist in simple mode
          queue_size: Map.get(stats, :queue_size, 0),
          pending_requests: Map.get(stats, :pending_requests, 0),
          current_tokens: Map.get(stats, :current_tokens, 0),
          circuit_state: Map.get(stats, :circuit_state, :unknown),
          failure_count: Map.get(stats, :failure_count, 0),
          detected_window_ms: Map.get(stats, :detected_window_ms, 0)
        }

      {:error, reason} ->
        %{error: "smart_rate_limiter_unreachable", reason: inspect(reason)}

      _ ->
        %{error: "smart_rate_limiter_unreachable"}
    end
  rescue
    error in [ErlangError] ->
      if match?({:noproc, _}, error.original) do
        %{error: "smart_rate_limiter_not_running"}
      else
        %{error: "smart_rate_limiter_exit", reason: inspect(error.original)}
      end
  end

  defp collect_smart_limiter_stats(_), do: %{}

  defp collect_coalescer_stats(true) do
    case RequestCoalescer.get_stats() do
      {:ok, stats} ->
        %{
          pending_requests: Map.get(stats, :pending_requests, 0),
          total_requesters: Map.get(stats, :total_requesters, 0)
        }

      {:error, reason} ->
        %{error: "request_coalescer_unreachable", reason: inspect(reason)}

      _ ->
        %{error: "request_coalescer_unreachable"}
    end
  rescue
    error in [ErlangError] ->
      if match?({:noproc, _}, error.original) do
        %{error: "request_coalescer_not_running"}
      else
        %{error: "request_coalescer_exit", reason: inspect(error.original)}
      end
  end

  defp collect_coalescer_stats(_), do: %{}
end
