defmodule WandererKills.Core.Observability.Statistics do
  @moduledoc """
  Dedicated module for statistics calculation and aggregation.

  This module consolidates statistics logic that was previously scattered
  across monitoring, batch processing, and other modules. It provides
  standardized functions for calculating various metrics and aggregations.

  ## Functions

  - Rate calculations (per minute, per hour, etc.)
  - Percentage calculations (hit rates, success rates)
  - Aggregation functions (sum, average, min, max)
  - Batch processing statistics
  - Cache performance metrics
  - Time-based statistics

  ## Usage

  ```elixir
  # Calculate hit rate percentage
  hit_rate = Statistics.calculate_hit_rate(hits: 85, total: 100)

  # Calculate processing rate per minute
  rate = Statistics.calculate_rate_per_minute(count: 1200, duration_seconds: 3600)

  # Aggregate cache statistics
  {:ok, aggregated} = Statistics.aggregate_cache_stats([cache1_stats, cache2_stats])
  ```
  """

  require Logger

  @type metric_data :: %{
          count: non_neg_integer(),
          total: non_neg_integer(),
          duration_seconds: number(),
          timestamp: DateTime.t()
        }

  @type rate_opts :: [
          period: :second | :minute | :hour | :day,
          precision: non_neg_integer()
        ]

  @type cache_stats :: %{
          hit_rate: float(),
          miss_rate: float(),
          size: non_neg_integer(),
          operations: non_neg_integer(),
          evictions: non_neg_integer()
        }

  # ============================================================================
  # Rate Calculations
  # ============================================================================

  @doc """
  Calculates a rate per specified time period.

  ## Parameters
  - `count` - Number of events/items
  - `duration_seconds` - Time period in seconds
  - `opts` - Options for period and precision

  ## Returns
  - Rate as a float for the specified period

  ## Examples

  ```elixir
  # 100 events in 60 seconds = 1.67 per second
  rate = calculate_rate(100, 60, period: :second)

  # 1200 events in 3600 seconds = 20 per minute
  rate = calculate_rate(1200, 3600, period: :minute)
  ```
  """
  @spec calculate_rate(non_neg_integer(), number(), rate_opts()) :: float()
  def calculate_rate(count, duration_seconds, opts \\ [])
      when is_integer(count) and is_number(duration_seconds) and duration_seconds > 0 do
    period = Keyword.get(opts, :period, :minute)
    precision = Keyword.get(opts, :precision, 2)

    period_multiplier =
      case period do
        :second -> 1
        :minute -> 60
        :hour -> 3600
        :day -> 86_400
      end

    rate = count * period_multiplier / duration_seconds
    Float.round(rate, precision)
  end

  @doc """
  Calculates rate per minute (convenience function).

  ## Parameters
  - `count` - Number of events
  - `duration_seconds` - Duration in seconds

  ## Returns
  - Events per minute as float
  """
  @spec calculate_rate_per_minute(non_neg_integer(), number()) :: float()
  def calculate_rate_per_minute(count, duration_seconds) do
    calculate_rate(count, duration_seconds, period: :minute)
  end

  @doc """
  Calculates rate per hour (convenience function).
  """
  @spec calculate_rate_per_hour(non_neg_integer(), number()) :: float()
  def calculate_rate_per_hour(count, duration_seconds) do
    calculate_rate(count, duration_seconds, period: :hour)
  end

  # ============================================================================
  # Percentage Calculations
  # ============================================================================

  @doc """
  Calculates a percentage with proper handling of edge cases.

  ## Parameters
  - `numerator` - Part value
  - `denominator` - Total value
  - `precision` - Decimal places (default: 2)

  ## Returns
  - Percentage as float (0.0 - 100.0)

  ## Examples

  ```elixir
  percentage = calculate_percentage(85, 100)  # 85.0
  percentage = calculate_percentage(0, 0)     # 0.0 (handles division by zero)
  ```
  """
  @spec calculate_percentage(number(), number(), non_neg_integer()) :: float()
  def calculate_percentage(numerator, denominator, precision \\ 2)
      when is_number(numerator) and is_number(denominator) do
    case denominator do
      0 -> 0.0
      _ -> Float.round(numerator / denominator * 100, precision)
    end
  end

  @doc """
  Calculates hit rate percentage from hits and total operations.

  ## Parameters
  - `hits` - Number of cache hits
  - `total` - Total number of operations

  ## Returns
  - Hit rate as percentage (0.0 - 100.0)
  """
  @spec calculate_hit_rate(non_neg_integer(), non_neg_integer()) :: float()
  def calculate_hit_rate(hits, total) do
    calculate_percentage(hits, total)
  end

  @doc """
  Calculates success rate from successful and total operations.
  """
  @spec calculate_success_rate(non_neg_integer(), non_neg_integer()) :: float()
  def calculate_success_rate(successful, total) do
    calculate_percentage(successful, total)
  end

  # ============================================================================
  # Statistical Aggregations
  # ============================================================================

  @doc """
  Calculates the average of a list of numbers.

  ## Parameters
  - `values` - List of numeric values

  ## Returns
  - `{:ok, average}` - Average as float
  - `{:error, :empty_list}` - If list is empty
  """
  @spec calculate_average([number()]) :: {:ok, float()} | {:error, :empty_list}
  def calculate_average([]), do: {:error, :empty_list}

  def calculate_average(values) when is_list(values) do
    sum = Enum.sum(values)
    count = length(values)
    {:ok, sum / count}
  end

  @doc """
  Calculates weighted average based on weights.

  ## Parameters
  - `values` - List of {value, weight} tuples

  ## Returns
  - `{:ok, weighted_average}` - Weighted average as float
  - `{:error, reason}` - If calculation fails
  """
  @spec calculate_weighted_average([{number(), number()}]) ::
          {:ok, float()} | {:error, atom()}
  def calculate_weighted_average([]), do: {:error, :empty_list}

  def calculate_weighted_average(value_weight_pairs) when is_list(value_weight_pairs) do
    {weighted_sum, total_weight} =
      Enum.reduce(value_weight_pairs, {0, 0}, fn {value, weight}, {sum, weight_sum} ->
        {sum + value * weight, weight_sum + weight}
      end)

    case total_weight do
      0 -> {:error, :zero_weight}
      _ -> {:ok, weighted_sum / total_weight}
    end
  end

  # ============================================================================
  # Batch Processing Statistics
  # ============================================================================

  @doc """
  Aggregates batch processing results into statistics.

  ## Parameters
  - `results` - List of batch processing results

  ## Returns
  - Statistics map with success/failure counts and rates
  """
  @spec aggregate_batch_results([{:ok | :error, term()}]) :: map()
  def aggregate_batch_results(results) when is_list(results) do
    {successes, failures} = Enum.split_with(results, &match?({:ok, _}, &1))

    success_count = length(successes)
    failure_count = length(failures)
    total_count = success_count + failure_count

    %{
      total: total_count,
      successes: success_count,
      failures: failure_count,
      success_rate: calculate_success_rate(success_count, total_count),
      failure_rate: calculate_percentage(failure_count, total_count)
    }
  end

  @doc """
  Calculates processing statistics for a timed operation.

  ## Parameters
  - `count` - Number of items processed
  - `duration_ms` - Duration in milliseconds

  ## Returns
  - Processing statistics map
  """
  @spec calculate_processing_stats(non_neg_integer(), number()) :: map()
  def calculate_processing_stats(count, duration_ms) when is_number(duration_ms) do
    duration_seconds = duration_ms / 1000

    %{
      count: count,
      duration_ms: duration_ms,
      duration_seconds: duration_seconds,
      items_per_second: if(duration_seconds > 0, do: count / duration_seconds, else: 0),
      items_per_minute: calculate_rate_per_minute(count, duration_seconds),
      avg_time_per_item_ms: if(count > 0, do: duration_ms / count, else: 0)
    }
  end

  # ============================================================================
  # Cache Statistics
  # ============================================================================

  @doc """
  Aggregates multiple cache statistics into combined metrics.

  ## Parameters
  - `cache_stats_list` - List of individual cache statistics maps

  ## Returns
  - `{:ok, aggregated_stats}` - Combined cache statistics
  - `{:error, reason}` - If aggregation fails
  """
  @spec aggregate_cache_stats([cache_stats()]) :: {:ok, map()} | {:error, term()}
  def aggregate_cache_stats([]), do: {:error, :empty_list}

  def aggregate_cache_stats(cache_stats_list) when is_list(cache_stats_list) do
    total_size = Enum.sum(Enum.map(cache_stats_list, &Map.get(&1, :size, 0)))
    total_operations = Enum.sum(Enum.map(cache_stats_list, &Map.get(&1, :operations, 0)))
    total_evictions = Enum.sum(Enum.map(cache_stats_list, &Map.get(&1, :evictions, 0)))

    # Calculate weighted average hit rate based on operations
    hit_rates =
      Enum.map(cache_stats_list, fn stats ->
        {Map.get(stats, :hit_rate, 0.0), Map.get(stats, :operations, 0)}
      end)

    avg_hit_rate =
      hit_rates
      |> calculate_weighted_average()
      |> case do
        {:ok, rate} -> rate
        {:error, _} -> 0.0
      end

    aggregated = %{
      total_size: total_size,
      total_operations: total_operations,
      total_evictions: total_evictions,
      average_hit_rate: avg_hit_rate,
      average_miss_rate: 100.0 - avg_hit_rate,
      cache_count: length(cache_stats_list),
      eviction_rate: calculate_percentage(total_evictions, total_operations)
    }

    {:ok, aggregated}
  rescue
    error ->
      Logger.warning("Failed to aggregate cache statistics", error: inspect(error))
      {:error, error}
  end

  @doc """
  Calculates cache efficiency metrics.

  ## Parameters
  - `cache_stats` - Individual cache statistics map

  ## Returns
  - Efficiency metrics map
  """
  @spec calculate_cache_efficiency(cache_stats()) :: map()
  def calculate_cache_efficiency(cache_stats) when is_map(cache_stats) do
    hit_rate = Map.get(cache_stats, :hit_rate, 0.0)
    size = Map.get(cache_stats, :size, 0)
    operations = Map.get(cache_stats, :operations, 0)
    evictions = Map.get(cache_stats, :evictions, 0)

    %{
      efficiency_score: calculate_efficiency_score(hit_rate, evictions, operations),
      utilization: if(operations > 0, do: size / operations, else: 0),
      churn_rate: calculate_percentage(evictions, size),
      stability: 100.0 - calculate_percentage(evictions, operations)
    }
  end

  # ============================================================================
  # Time-based Statistics
  # ============================================================================

  @doc """
  Calculates statistics over a time window.

  ## Parameters
  - `events` - List of timestamped events
  - `window_seconds` - Time window size in seconds

  ## Returns
  - Time-based statistics map
  """
  @spec calculate_time_window_stats([map()], non_neg_integer()) :: map()
  def calculate_time_window_stats(events, window_seconds) when is_list(events) do
    now = DateTime.utc_now()
    window_start = DateTime.add(now, -window_seconds, :second)

    recent_events = filter_recent_events(events, window_start)
    event_count = length(recent_events)

    %{
      window_seconds: window_seconds,
      total_events: length(events),
      recent_events: event_count,
      events_per_minute: calculate_rate_per_minute(event_count, window_seconds),
      events_per_hour: calculate_rate_per_hour(event_count, window_seconds),
      activity_percentage: calculate_percentage(event_count, length(events))
    }
  end

  # ============================================================================
  # Private Helper Functions
  # ============================================================================

  # Filters events to only include those after the given start time
  defp filter_recent_events(events, window_start) do
    Enum.filter(events, fn event ->
      event_within_window?(event, window_start)
    end)
  end

  # Checks if an event's timestamp is within the time window
  defp event_within_window?(event, window_start) do
    case Map.get(event, :timestamp) do
      nil ->
        false

      timestamp when is_binary(timestamp) ->
        case DateTime.from_iso8601(timestamp) do
          {:ok, dt, _} -> DateTime.compare(dt, window_start) != :lt
          _ -> false
        end

      %DateTime{} = dt ->
        DateTime.compare(dt, window_start) != :lt

      _ ->
        false
    end
  end

  # Calculates a cache efficiency score based on hit rate and stability
  defp calculate_efficiency_score(hit_rate, evictions, operations) do
    stability_factor =
      if operations > 0 do
        1.0 - evictions / operations
      else
        1.0
      end

    # Combine hit rate (0-100) with stability factor (0-1)
    efficiency = hit_rate / 100.0 * stability_factor * 100
    Float.round(efficiency, 2)
  end
end
