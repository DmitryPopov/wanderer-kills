defmodule WandererKills.Ingest.Killmails.BatchProcessor do
  @moduledoc """
  Compatibility layer for batch processing operations that were refactored during simplification.

  This module provides the functions expected by tests while delegating to the new
  simplified architecture components:
  - Character extraction uses CharacterMatcher
  - Subscription matching uses the index modules
  - Batch operations use UnifiedProcessor
  """

  alias WandererKills.Domain.Killmail
  alias WandererKills.Ingest.Killmails.CharacterMatcher
  alias WandererKills.Subs.CharacterIndex

  @doc """
  Extracts all unique character IDs from a list of killmails.

  Returns a MapSet of all character IDs found across all killmails.
  """
  @spec extract_all_characters([Killmail.t()]) :: MapSet.t(integer())
  def extract_all_characters(killmails) when is_list(killmails) do
    killmails
    |> Enum.flat_map(&CharacterMatcher.extract_character_ids/1)
    |> MapSet.new()
  end

  @doc """
  Finds all subscriptions interested in the given killmails based on character IDs.

  Returns a map of subscription_id to character ID sets.
  """
  @spec find_interested_subscriptions([Killmail.t()]) :: map()
  def find_interested_subscriptions(killmails) when is_list(killmails) do
    # Extract all character IDs from killmails
    character_ids =
      killmails
      |> extract_all_characters()
      |> MapSet.to_list()

    # Find subscriptions for these characters concurrently
    character_ids
    |> Task.async_stream(
      fn character_id ->
        case CharacterIndex.find_subscriptions_for_character(character_id) do
          [] -> {character_id, []}
          subscription_ids -> {character_id, subscription_ids}
        end
      end,
      max_concurrency: System.schedulers_online() * 2
    )
    |> Stream.filter(fn {:ok, {_character_id, subscription_ids}} -> subscription_ids != [] end)
    |> Enum.reduce(%{}, fn {:ok, {character_id, subscription_ids}}, acc ->
      update_subscription_character_map(subscription_ids, character_id, acc)
    end)
  end

  @doc """
  Matches killmails to subscriptions based on a subscription character map.

  Returns a map of subscription_id to list of matching killmails.
  """
  @spec match_killmails_to_subscriptions([Killmail.t()], map()) :: map()
  def match_killmails_to_subscriptions(killmails, subscription_character_map)
      when is_list(killmails) and is_map(subscription_character_map) do
    # Build a map of subscription_id to matching killmails
    Enum.reduce(subscription_character_map, %{}, fn {subscription_id, character_set}, acc ->
      matching_killmails =
        Enum.filter(killmails, fn killmail ->
          killmail_characters =
            killmail
            |> CharacterMatcher.extract_character_ids()
            |> MapSet.new()

          # Check if any killmail character is in the subscription's character set
          not MapSet.disjoint?(killmail_characters, character_set)
        end)

      case matching_killmails do
        [] -> acc
        killmails -> Map.put(acc, subscription_id, killmails)
      end
    end)
  end

  defp update_subscription_character_map(subscription_ids, character_id, acc) do
    Enum.reduce(subscription_ids, acc, fn sub_id, acc2 ->
      Map.update(acc2, sub_id, MapSet.new([character_id]), fn existing ->
        MapSet.put(existing, character_id)
      end)
    end)
  end

  @doc """
  Groups killmails by subscription based on system filtering.

  Returns a map of subscription_id to list of matching killmails.
  """
  @spec group_killmails_by_subscription([Killmail.t()], map()) :: map()
  def group_killmails_by_subscription(killmails, subscriptions)
      when is_list(killmails) and is_map(subscriptions) do
    # Group killmails by the subscriptions that are interested in them
    Enum.reduce(subscriptions, %{}, fn {subscription_id, subscription_data}, acc ->
      # Get system IDs for this subscription
      system_ids = Map.get(subscription_data, "system_ids", [])

      # Filter killmails that match the subscription's systems
      matching_killmails =
        Enum.filter(killmails, fn killmail ->
          killmail.system_id in system_ids
        end)

      case matching_killmails do
        [] -> acc
        killmails -> Map.put(acc, subscription_id, killmails)
      end
    end)
  end
end
