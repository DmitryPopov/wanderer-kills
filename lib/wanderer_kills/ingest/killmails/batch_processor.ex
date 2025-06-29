defmodule WandererKills.Ingest.Killmails.BatchProcessor do
  @moduledoc """
  Provides efficient batch processing for character extraction and matching
  from multiple killmails. Optimized for high-throughput scenarios.

  ## Purpose

  This module handles the computationally expensive task of processing multiple
  killmails simultaneously, leveraging parallelism and caching to achieve
  optimal performance in high-throughput subscription filtering scenarios.

  ## Key Features

  - **Parallel Character Extraction**: Uses `Task.async_stream` with optimal concurrency
  - **Intelligent Caching**: Integrates with `CharacterCache` for performance
  - **Subscription Matching**: Efficiently matches killmails to interested subscriptions
  - **Comprehensive Telemetry**: Detailed performance monitoring for all operations

  ## Performance Optimization

  The module is designed for scenarios involving:
  - Large batches of killmails (100+ items)
  - Complex subscription sets (1000+ subscriptions)
  - Killmails with many attackers (20+ characters each)
  - High-frequency processing (multiple batches per second)

  ## Concurrency Strategy

  - **CPU-bound operations**: `System.schedulers_online()` concurrency
  - **I/O-bound operations**: `System.schedulers_online() * 2` concurrency
  - **Graceful degradation**: Continues processing even if individual tasks fail
  - **Memory efficient**: Processes results as they complete

  ## Telemetry Events

  Emits detailed telemetry for all major operations:
  - `[:wanderer_kills, :batch_processor, :extract_characters]`
  - `[:wanderer_kills, :batch_processor, :match_killmails]`
  - `[:wanderer_kills, :batch_processor, :find_subscriptions]`
  - `[:wanderer_kills, :batch_processor, :group_killmails]`

  Each event includes timing, counts, and operation metadata.

  ## Usage Patterns

      # Extract all characters from a batch
      all_characters = BatchProcessor.extract_all_characters(killmails)

      # Find subscriptions interested in killmails
      interested = BatchProcessor.find_interested_subscriptions(killmails)

      # Group killmails by subscription for delivery
      grouped = BatchProcessor.group_killmails_by_subscription(killmails, subscriptions)

      # Advanced subscription matching
      matches = BatchProcessor.match_killmails_to_subscriptions(killmails, char_map)

  ## Integration Points

  - **CharacterCache**: Automatic caching of character extraction results
  - **CharacterIndex**: Fast subscription lookups by character ID
  - **Filter**: Uses unified filtering logic for system/character matching
  - **Telemetry**: Comprehensive performance monitoring and alerting
  """

  require Logger

  alias WandererKills.Domain.Killmail
  alias WandererKills.Ingest.Killmails.{CharacterCache, CharacterMatcher}
  alias WandererKills.Subs.Subscriptions.{CharacterIndex, Filter}

  @type killmail :: Killmail.t()
  @type character_id :: integer()
  @type subscription_id :: String.t()

  @doc """
  Extracts all unique character IDs from a batch of killmails.

  This function is optimized to process multiple killmails efficiently
  by extracting character IDs in a single pass.

  ## Parameters
    - killmails: List of killmail structs
    
  ## Returns
    - MapSet of all unique character IDs found
  """
  @spec extract_all_characters([Killmail.t()]) :: MapSet.t(character_id())
  def extract_all_characters(killmails) when is_list(killmails) do
    start_time = System.monotonic_time()
    killmail_count = length(killmails)

    result =
      Task.Supervisor.async_stream(
        WandererKills.TaskSupervisor,
        killmails,
        &extract_characters_from_killmail_cached/1,
        max_concurrency: System.schedulers_online() * 2,
        ordered: false
      )
      |> Enum.reduce(MapSet.new(), fn
        {:ok, characters}, acc -> MapSet.union(acc, characters)
        {:exit, _reason}, acc -> acc
      end)

    duration = System.monotonic_time() - start_time
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)

    :telemetry.execute(
      [:wanderer_kills, :batch_processor, :extract_characters],
      %{
        duration: duration_ms,
        killmail_count: killmail_count,
        character_count: MapSet.size(result)
      },
      %{
        operation: :extract_all_characters
      }
    )

    result
  end

  @doc """
  Finds all killmails that match any of the given character subscriptions.

  This function efficiently matches multiple killmails against multiple
  character subscriptions using the CharacterIndex.

  ## Parameters
    - killmails: List of killmail structs
    - subscription_character_map: Map of subscription_id => [character_ids]
    
  ## Returns
    - Map of subscription_id => [matching_killmails]
  """
  @spec match_killmails_to_subscriptions([Killmail.t()], map()) :: map()
  def match_killmails_to_subscriptions(killmails, subscription_character_map)
      when is_list(killmails) and is_map(subscription_character_map) do
    start_time = System.monotonic_time()
    killmail_count = length(killmails)
    subscription_count = map_size(subscription_character_map)

    # Extract all characters from killmails once (using cache)
    killmail_characters = build_killmail_character_map_cached(killmails)

    # Build the result map
    result =
      Task.Supervisor.async_stream(
        WandererKills.TaskSupervisor,
        subscription_character_map,
        fn {subscription_id, character_ids} ->
          matching_killmails =
            find_matching_killmails(
              killmails,
              killmail_characters,
              MapSet.new(character_ids)
            )

          {subscription_id, matching_killmails}
        end,
        max_concurrency: System.schedulers_online(),
        ordered: false
      )
      |> Enum.reduce(%{}, fn
        {:ok, {subscription_id, killmails}}, acc ->
          if killmails != [] do
            Map.put(acc, subscription_id, killmails)
          else
            acc
          end

        {:exit, _reason}, acc ->
          acc
      end)

    duration = System.monotonic_time() - start_time
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)
    total_matches = result |> Map.values() |> Enum.map(&length/1) |> Enum.sum()

    :telemetry.execute(
      [:wanderer_kills, :batch_processor, :match_killmails],
      %{
        duration: duration_ms,
        killmail_count: killmail_count,
        subscription_count: subscription_count,
        match_count: total_matches,
        matched_subscription_count: map_size(result)
      },
      %{
        operation: :match_killmails_to_subscriptions
      }
    )

    result
  end

  @doc """
  Efficiently finds all subscriptions interested in killmails from a batch.

  Uses the CharacterIndex to quickly identify relevant subscriptions.

  ## Parameters
    - killmails: List of killmail structs
    
  ## Returns
    - Map of killmail_id => [subscription_ids]
  """
  @spec find_interested_subscriptions([Killmail.t()]) :: map()
  def find_interested_subscriptions(killmails) when is_list(killmails) do
    start_time = System.monotonic_time()
    killmail_count = length(killmails)

    result =
      Task.Supervisor.async_stream(
        WandererKills.TaskSupervisor,
        killmails,
        fn killmail ->
          character_ids = extract_characters_from_killmail_cached(killmail) |> MapSet.to_list()
          subscription_ids = CharacterIndex.find_subscriptions_for_entities(character_ids)
          {get_killmail_id(killmail), subscription_ids}
        end,
        max_concurrency: System.schedulers_online() * 2,
        ordered: false
      )
      |> Enum.reduce(%{}, fn
        {:ok, {killmail_id, subscription_ids}}, acc ->
          if subscription_ids != [] do
            Map.put(acc, killmail_id, subscription_ids)
          else
            acc
          end

        {:exit, _reason}, acc ->
          acc
      end)

    duration = System.monotonic_time() - start_time
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)
    total_subscriptions = result |> Map.values() |> Enum.map(&length/1) |> Enum.sum()

    :telemetry.execute(
      [:wanderer_kills, :batch_processor, :find_subscriptions],
      %{
        duration: duration_ms,
        killmail_count: killmail_count,
        matched_killmail_count: map_size(result),
        total_subscription_matches: total_subscriptions
      },
      %{
        operation: :find_interested_subscriptions
      }
    )

    result
  end

  @doc """
  Groups killmails by the subscriptions interested in them.

  This is useful for batch webhook notifications.

  ## Parameters
    - killmails: List of killmail structs
    - subscriptions: Map of subscription_id => subscription_data
    
  ## Returns
    - Map of subscription_id => [killmails]
  """
  @spec group_killmails_by_subscription([Killmail.t()], map()) :: map()
  def group_killmails_by_subscription(killmails, subscriptions)
      when is_list(killmails) and is_map(subscriptions) do
    start_time = System.monotonic_time()
    killmail_count = length(killmails)
    subscription_count = map_size(subscriptions)

    # Use proper filtering that handles both systems and characters
    result =
      Task.Supervisor.async_stream(
        WandererKills.TaskSupervisor,
        subscriptions,
        fn {subscription_id, subscription_data} ->
          matching_killmails = Filter.filter_killmails(killmails, subscription_data)
          {subscription_id, matching_killmails}
        end,
        max_concurrency: System.schedulers_online(),
        ordered: false
      )
      |> Enum.reduce(%{}, fn
        {:ok, {subscription_id, matching_killmails}}, acc ->
          if matching_killmails != [] do
            Map.put(acc, subscription_id, matching_killmails)
          else
            acc
          end

        {:exit, _reason}, acc ->
          acc
      end)

    duration = System.monotonic_time() - start_time
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)
    total_grouped_killmails = result |> Map.values() |> Enum.map(&length/1) |> Enum.sum()

    :telemetry.execute(
      [:wanderer_kills, :batch_processor, :group_killmails],
      %{
        duration: duration_ms,
        killmail_count: killmail_count,
        subscription_count: subscription_count,
        grouped_subscription_count: map_size(result),
        total_grouped_killmails: total_grouped_killmails
      },
      %{
        operation: :group_killmails_by_subscription
      }
    )

    result
  end

  # Private functions

  defp extract_characters_from_killmail_cached(%Killmail{} = killmail) do
    MapSet.new(CharacterCache.extract_characters_cached(killmail))
  rescue
    error ->
      # Cache error (ArgumentError, ETS errors, etc.), fall back to direct extraction
      Logger.debug("Character cache extraction failed, using fallback",
        error: inspect(error),
        killmail_id: killmail.killmail_id
      )

      MapSet.new(CharacterMatcher.extract_character_ids(killmail))
  catch
    :exit, reason ->
      # Handle ETS table crashes or process exits
      Logger.debug("Character cache process error, using fallback",
        reason: inspect(reason),
        killmail_id: killmail.killmail_id
      )

      MapSet.new(CharacterMatcher.extract_character_ids(killmail))
  end

  defp build_killmail_character_map_cached(killmails) do
    # Use batch extraction with caching for better performance
    CharacterCache.batch_extract_cached(killmails)
    |> Map.new(fn {killmail_id, characters} ->
      {killmail_id, MapSet.new(characters)}
    end)
  rescue
    ArgumentError ->
      # Cache not available, fall back to direct extraction
      killmails
      |> Map.new(fn killmail ->
        killmail_id = get_killmail_id(killmail)
        characters = CharacterMatcher.extract_character_ids(killmail)
        {killmail_id, MapSet.new(characters)}
      end)
  end

  defp find_matching_killmails(killmails, killmail_characters, character_set) do
    {valid_killmails, invalid_killmails} =
      killmails
      |> Enum.split_with(fn killmail ->
        killmail_id = get_killmail_id(killmail)
        killmail_id != nil and Map.has_key?(killmail_characters, killmail_id)
      end)

    # Log warning if we found killmails without valid IDs
    invalid_count = length(invalid_killmails)

    if invalid_count > 0 do
      require Logger

      Logger.warning("Skipping killmails without valid killmail_id in batch processing",
        invalid_count: invalid_count,
        total_count: length(killmails)
      )
    end

    # Filter valid killmails by character matching
    valid_killmails
    |> Enum.filter(fn killmail ->
      killmail_chars = Map.get(killmail_characters, get_killmail_id(killmail), MapSet.new())
      not MapSet.disjoint?(killmail_chars, character_set)
    end)
  end

  # Helper function to get killmail_id from struct
  defp get_killmail_id(%Killmail{killmail_id: id}), do: id
end
