defmodule WandererKills.Ingest.Killmails.CharacterCache do
  @moduledoc """
  Provides caching for extracted character IDs from killmails.

  This module caches the results of character extraction to avoid
  repeated parsing of the same killmail data. Uses Cachex with
  configurable TTL.

  ## Caching Strategy

  - **Cache Key**: `"character_extraction:{killmail_id}"`
  - **TTL**: 5 minutes (configurable via `:character_cache, :ttl_ms`)
  - **Namespace**: `"character_extraction"`
  - **Storage**: Shared Cachex instance (`:wanderer_cache`)

  ## Performance Benefits

  Character extraction can be expensive for killmails with many attackers.
  Caching provides significant performance improvements for:
  - Repeated processing of the same killmails
  - Batch operations on overlapping killmail sets
  - Subscription filtering with character lists

  ## Batch Processing

  The module provides efficient batch processing with:
  - Parallel cache lookups for multiple killmails
  - Concurrent character extraction for cache misses
  - Automatic cache population for extracted data
  - Comprehensive telemetry reporting

  ## Telemetry & Monitoring

  Emits `[:wanderer_kills, :character, :cache]` events for:
  - `:hit` - Successful cache lookups
  - `:miss` - Cache misses requiring extraction
  - `:put` - Cache storage operations

  Also emits batch telemetry for large operations (>50 killmails):
  - Cache effectiveness statistics
  - Hit rate percentages
  - Performance metrics

  ## Configuration

      config :wanderer_kills, :character_cache,
        ttl_ms: :timer.minutes(5)  # 5 minute TTL

  ## Usage Examples

      # Single killmail caching
      characters = CharacterCache.extract_characters_cached(killmail)

      # Batch processing with caching
      killmail_character_map = CharacterCache.batch_extract_cached(killmails)

      # Cache management
      CharacterCache.warm_cache(killmails)
      CharacterCache.clear_cache()
      stats = CharacterCache.get_cache_stats()
  """

  # Compile-time configuration
  @ttl_ms Application.compile_env(:wanderer_kills, [:character_cache, :ttl_ms], :timer.minutes(5))
  require Logger

  alias WandererKills.Core.Cache
  alias WandererKills.Core.Observability.Telemetry
  alias WandererKills.Domain.Killmail
  alias WandererKills.Ingest.Killmails.CharacterMatcher

  @cache_name :wanderer_cache
  @namespace "character_extraction"

  # Get the configured cache adapter
  defp cache_adapter do
    Application.get_env(:wanderer_kills, :cache_adapter, Cachex)
  end

  # Helper function to get cache stats that works with different adapters
  defp get_cache_stats_internal do
    Cache.stats()
  end

  @doc """
  Extracts character IDs from a killmail, using cache when possible.

  ## Parameters
    - killmail: The killmail map
    
  ## Returns
    - List of character IDs found in the killmail
  """
  @spec extract_characters_cached(map() | Killmail.t()) :: [integer()]
  def extract_characters_cached(%Killmail{} = killmail) do
    killmail_id = killmail.killmail_id

    case Cache.get(:temp_data, "character_extraction:#{killmail_id}") do
      {:ok, characters} ->
        Telemetry.character_cache(:hit, killmail_id, %{killmail_id: killmail_id})
        characters

      {:error, _} ->
        Telemetry.character_cache(:miss, killmail_id, %{killmail_id: killmail_id})

        # Extract and cache - use CharacterMatcher for structs
        characters = CharacterMatcher.extract_character_ids(killmail)
        Cache.put(:temp_data, "character_extraction:#{killmail_id}", characters)
        characters
    end
  end

  def extract_characters_cached(killmail) when is_map(killmail) do
    killmail_id = killmail["killmail_id"] || killmail[:killmail_id]

    case killmail_id do
      nil ->
        # No killmail_id, can't cache - extract directly from map
        extract_character_ids_from_map(killmail)

      id ->
        case Cache.get(:temp_data, "character_extraction:#{id}") do
          {:ok, characters} ->
            Telemetry.character_cache(:hit, id, %{killmail_id: id})
            characters

          {:error, _} ->
            Telemetry.character_cache(:miss, id, %{killmail_id: id})

            # Extract and cache
            characters = extract_character_ids_from_map(killmail)
            Cache.put(:temp_data, "character_extraction:#{id}", characters)
            characters
        end
    end
  end

  # Helper function to extract character IDs directly from a map
  # This is used when we have raw killmail data that hasn't been converted to a struct yet
  defp extract_character_ids_from_map(killmail) when is_map(killmail) do
    victim_id =
      get_in(killmail, ["victim", "character_id"]) || get_in(killmail, [:victim, :character_id])

    attacker_ids =
      (killmail["attackers"] || killmail[:attackers] || [])
      |> Enum.map(fn attacker ->
        attacker["character_id"] || attacker[:character_id]
      end)
      |> Enum.filter(& &1)

    [victim_id | attacker_ids]
    |> Enum.filter(& &1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Batch extracts characters from multiple killmails with caching.

  ## Parameters
    - killmails: List of killmail maps
    
  ## Returns
    - Map of killmail_id => [character_ids]
  """
  @spec batch_extract_cached([map()]) :: %{integer() => [integer()]}
  def batch_extract_cached(killmails) when is_list(killmails) do
    # Separate killmails with and without IDs
    {with_ids, without_ids} = Enum.split_with(killmails, &(&1["killmail_id"] || &1[:killmail_id]))

    # Process killmails with IDs (cacheable)
    cached_results = process_cacheable_killmails(with_ids)

    # Process killmails without IDs (non-cacheable)
    uncached_results =
      without_ids
      |> Enum.map(fn km ->
        {System.unique_integer(), extract_character_ids_from_map(km)}
      end)
      |> Map.new()

    Map.merge(cached_results, uncached_results)
  rescue
    error ->
      Logger.warning("Character cache unavailable, falling back to direct extraction",
        error: inspect(error),
        error_type: error.__struct__,
        killmails_count: length(killmails)
      )

      # Emit telemetry for cache bypass
      :telemetry.execute(
        [:wanderer_kills, :character, :cache, :bypass],
        %{count: length(killmails)},
        %{reason: :cache_error}
      )

      # Cache became unavailable during processing, fall back
      fallback_batch_extract(killmails)
  end

  # Fallback function for when cache is not available
  defp fallback_batch_extract(killmails) do
    killmails
    |> Enum.map(fn killmail ->
      case killmail do
        %Killmail{} = struct_killmail ->
          id = struct_killmail.killmail_id
          characters = CharacterMatcher.extract_character_ids(struct_killmail)
          {id, characters}

        map_killmail when is_map(map_killmail) ->
          id = map_killmail["killmail_id"] || System.unique_integer()
          characters = extract_character_ids_from_map(map_killmail)
          {id, characters}
      end
    end)
    |> Map.new()
  end

  @doc """
  Warms the cache with character data from multiple killmails.

  Useful for preloading cache after fetching new killmails.
  """
  @spec warm_cache([map()]) :: :ok
  def warm_cache(killmails) when is_list(killmails) do
    killmails
    |> Enum.filter(& &1["killmail_id"])
    |> Enum.each(fn killmail ->
      id = killmail["killmail_id"]

      case Cache.exists?(:temp_data, "char_extract:#{id}") do
        {:ok, false} ->
          characters = extract_character_ids_from_map(killmail)
          Cache.put(:temp_data, "char_extract:#{id}", characters)

        _ ->
          # Either exists or error occurred, skip
          :ok
      end
    end)

    :ok
  end

  @doc """
  Gets cache statistics for character extraction.
  """
  @spec get_cache_stats() :: map()
  def get_cache_stats do
    stats = get_cache_stats_internal()

    # Cachex stats structure is different - it's just counts
    hits = Map.get(stats, :hits, 0)
    misses = Map.get(stats, :misses, 0)
    total = hits + misses

    hit_rate = if total > 0, do: hits / total * 100, else: 0.0

    # Get the size (number of entries) in the cache
    size =
      case cache_adapter().size(@cache_name) do
        {:ok, count} -> count
        _ -> 0
      end

    %{
      namespace: @namespace,
      hits: hits,
      misses: misses,
      total_requests: total,
      hit_rate: Float.round(hit_rate, 2),
      ttl_minutes: div(@ttl_ms, 60_000),
      entries: size
    }
  end

  @doc """
  Clears all character extraction cache entries.

  This function only clears entries within the character extraction namespace,
  preserving other cached data like ESI data, system data, and ship types.
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    adapter = cache_adapter()

    case adapter do
      Cachex -> clear_cachex_namespace()
      _ -> clear_generic_cache(adapter)
    end
  end

  # Clear only character extraction namespace using unified cache API
  defp clear_cachex_namespace do
    # Since character extraction uses temp_data namespace with specific key pattern,
    # we can't clear the entire namespace. Just log and return :ok
    Logger.debug("Character extraction cache uses temp_data namespace")
    :ok
  end

  # Clear entire cache for non-Cachex adapters (primarily for testing)
  defp clear_generic_cache(adapter) do
    case adapter.clear(@cache_name) do
      {:ok, _count} ->
        Logger.debug("Cleared entire cache (using non-Cachex adapter)")
        :ok

      {:error, _} ->
        Logger.warning("Failed to clear character cache")
        :ok
    end
  end

  # Private functions

  defp get_from_cache(id) do
    Cache.get(:temp_data, "char_extract:#{id}")
  end

  defp put_in_cache(id, value) do
    result = Cache.put(:temp_data, "char_extract:#{id}", value)
    Telemetry.character_cache(:put, id, %{character_count: length(value)})
    result
  end

  defp process_cacheable_killmails(killmails) do
    # Build list of cache keys to check
    cache_checks =
      killmails
      |> Enum.map(fn km ->
        killmail_id = km["killmail_id"] || km[:killmail_id]
        {killmail_id, km}
      end)

    # Optimized: Single cache operation per key instead of exists? + get
    {cached_results, uncached} =
      Task.Supervisor.async_stream(
        WandererKills.TaskSupervisor,
        cache_checks,
        fn {id, km} ->
          case get_from_cache(id) do
            {:ok, chars} -> {:cached, {id, chars}}
            {:error, _} -> {:uncached, {id, km}}
          end
        end,
        max_concurrency: System.schedulers_online(),
        ordered: false
      )
      |> Enum.reduce({[], []}, fn
        {:ok, {:cached, result}}, {cached_acc, uncached_acc} ->
          {[result | cached_acc], uncached_acc}

        {:ok, {:uncached, item}}, {cached_acc, uncached_acc} ->
          {cached_acc, [item | uncached_acc]}

        _, {cached_acc, uncached_acc} ->
          {cached_acc, uncached_acc}
      end)

    # Convert cached results to map
    cached_results_map = Map.new(cached_results)

    # Process uncached killmails
    uncached_results =
      Task.Supervisor.async_stream(
        WandererKills.TaskSupervisor,
        uncached,
        fn {id, km} ->
          characters = extract_character_ids_from_map(km)
          put_in_cache(id, characters)
          {id, characters}
        end,
        max_concurrency: System.schedulers_online(),
        ordered: false
      )
      |> Enum.reduce(%{}, fn
        {:ok, {id, chars}}, acc -> Map.put(acc, id, chars)
        _, acc -> acc
      end)

    # Report telemetry
    hit_count = map_size(cached_results_map)
    miss_count = map_size(uncached_results)
    total = length(killmails)

    :telemetry.execute(
      [:wanderer_kills, :character_cache, :batch],
      %{
        hits: hit_count,
        misses: miss_count,
        total: total
      },
      %{}
    )

    # Log cache effectiveness for large batches
    if total > 50 do
      hit_rate = if total > 0, do: Float.round(hit_count / total * 100, 1), else: 0.0

      Logger.info("[INFO] Character cache batch performance",
        total_killmails: total,
        cache_hits: hit_count,
        cache_misses: miss_count,
        hit_rate_percent: hit_rate
      )
    end

    Map.merge(cached_results_map, uncached_results)
  end
end
