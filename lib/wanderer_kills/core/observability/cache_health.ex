defmodule WandererKills.Core.Observability.CacheHealth do
  @moduledoc """
  Health check implementation for cache systems.

  This module provides comprehensive health checking for all cache
  instances in the application, including size, connectivity, and
  performance metrics.
  """

  require Logger
  alias WandererKills.Core.Cache
  alias WandererKills.Core.Observability.HealthCheckBehaviour
  alias WandererKills.Core.Support.Clock

  @behaviour HealthCheckBehaviour

  @impl true
  def check_health(opts \\ []) do
    config = Keyword.merge(default_config(), opts)
    cache_names = Keyword.get(config, :cache_names)

    cache_checks = Enum.map(cache_names, &check_cache_health/1)
    all_healthy = Enum.all?(cache_checks, & &1.healthy)

    %{
      healthy: all_healthy,
      status: if(all_healthy, do: "ok", else: "error"),
      details: %{
        component: "cache_system",
        caches: cache_checks,
        total_caches: length(cache_names),
        healthy_caches: Enum.count(cache_checks, fn cache_check -> cache_check.healthy end)
      },
      timestamp: Clock.now_iso8601()
    }
  end

  @impl true
  def get_metrics(opts \\ []) do
    config = Keyword.merge(default_config(), opts)
    cache_names = Keyword.get(config, :cache_names)

    cache_metrics = Enum.map(cache_names, &get_cache_metrics/1)

    %{
      component: "cache_system",
      timestamp: Clock.now_iso8601(),
      metrics: %{
        total_caches: length(cache_names),
        caches: cache_metrics,
        aggregate: calculate_aggregate_metrics(cache_metrics)
      }
    }
  end

  @impl true
  def default_config do
    cache_names = [
      # Single unified cache instance
      :wanderer_cache
    ]

    [
      cache_names: cache_names,
      timeout_ms: 5_000
    ]
  end

  # Private helper functions

  @spec check_cache_health(atom()) :: %{healthy: boolean(), name: atom(), status: String.t()}
  defp check_cache_health(cache_name) do
    case Cache.health() do
      {:ok, health} ->
        Map.put(health, :name, cache_name)
    end
  rescue
    error ->
      Logger.warning("Cache health check failed for #{cache_name}: #{inspect(error)}")

      %{
        healthy: false,
        name: cache_name,
        status: "unavailable",
        error: inspect(error)
      }
  end

  @spec get_cache_metrics(atom()) :: map()
  defp get_cache_metrics(cache_name) do
    base_metrics = %{name: cache_name}

    try do
      # Get size directly first, as it's more reliable
      cache_size =
        case Cache.size() do
          {:ok, size} -> size
          _ -> 0
        end

      case Cache.stats() do
        {:ok, stats} ->
          Map.merge(base_metrics, %{
            size: cache_size,
            hit_rate: Map.get(stats, :hit_rate, 0.0),
            miss_rate: Map.get(stats, :miss_rate, 0.0),
            eviction_count: Map.get(stats, :eviction_count, 0),
            expiration_count: Map.get(stats, :expiration_count, 0),
            update_count: Map.get(stats, :update_count, 0)
          })

        {:error, reason} ->
          Map.merge(base_metrics, %{
            error: "Unable to retrieve stats",
            reason: inspect(reason)
          })
      end
    rescue
      error ->
        Map.merge(base_metrics, %{
          error: "Stats collection failed",
          reason: inspect(error)
        })
    end
  end

  @spec calculate_aggregate_metrics([map()]) :: map()
  defp calculate_aggregate_metrics(cache_metrics) do
    valid_metrics = Enum.reject(cache_metrics, &Map.has_key?(&1, :error))

    if Enum.empty?(valid_metrics) do
      %{error: "No valid cache metrics available"}
    else
      %{
        total_size: Enum.sum(Enum.map(valid_metrics, &Map.get(&1, :size, 0))),
        average_hit_rate: calculate_average_hit_rate(valid_metrics),
        total_evictions: Enum.sum(Enum.map(valid_metrics, &Map.get(&1, :eviction_count, 0))),
        total_expirations: Enum.sum(Enum.map(valid_metrics, &Map.get(&1, :expiration_count, 0)))
      }
    end
  end

  @spec calculate_average_hit_rate([map()]) :: float()
  defp calculate_average_hit_rate(valid_metrics) do
    hit_rates = Enum.map(valid_metrics, &Map.get(&1, :hit_rate, 0.0))

    case hit_rates do
      [] -> 0.0
      rates -> Enum.sum(rates) / length(rates)
    end
  end
end
