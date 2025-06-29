defmodule WandererKills.Subs.Subscriptions.Broadcaster do
  @moduledoc """
  Handles PubSub broadcasting for killmail subscriptions.

  This module centralizes all broadcasting logic for killmail updates,
  ensuring consistent message formatting and topic management.
  """

  require Logger

  alias WandererKills.Core.Support.PubSubTopics

  @pubsub_name WandererKills.PubSub

  @doc """
  Broadcasts a killmail update to all relevant PubSub topics.

  ## Parameters
  - `system_id` - The system ID for the kills
  - `kills` - List of killmail data

  ## Topics broadcasted to:
  - System-specific topic for the given system_id
  - All systems topic
  - WebSocket statistics topic
  """
  @spec broadcast_killmail_update(integer(), list(map())) :: :ok
  def broadcast_killmail_update(system_id, kills) do
    message = %{
      type: :killmail_update,
      system_id: system_id,
      kills: kills,
      timestamp: DateTime.utc_now()
    }

    Logger.debug("=== BROADCASTER SENDING ===",
      system_id: system_id,
      kills_count: length(kills),
      message: inspect(message)
    )

    # Broadcast to system-specific topic
    system_topic = PubSubTopics.system_topic(system_id)
    Logger.debug("Broadcasting to system topic: #{system_topic}")
    :ok = Phoenix.PubSub.broadcast(@pubsub_name, system_topic, message)

    # Broadcast to detailed system topic as well
    detailed_topic = PubSubTopics.system_detailed_topic(system_id)
    Logger.debug("Broadcasting to detailed topic: #{detailed_topic}")
    :ok = Phoenix.PubSub.broadcast(@pubsub_name, detailed_topic, message)

    # Broadcast to all systems topic
    all_systems_topic = PubSubTopics.all_systems_topic()
    Logger.debug("Broadcasting to all systems topic: #{all_systems_topic}")
    :ok = Phoenix.PubSub.broadcast(@pubsub_name, all_systems_topic, message)

    # Also broadcast SSE-formatted messages for SSE subscribers
    broadcast_sse_messages(system_id, kills)

    # Broadcast to character-specific topics
    broadcast_to_character_topics(kills)

    log_broadcast(system_id, kills)
    :ok
  end

  @doc """
  Broadcasts a killmail count update to all relevant PubSub topics.

  ## Parameters
  - `system_id` - The system ID for the count
  - `count` - Number of killmails
  """
  @spec broadcast_killmail_count(integer(), integer()) :: :ok
  def broadcast_killmail_count(system_id, count) do
    message = %{
      type: :killmail_count_update,
      system_id: system_id,
      count: count,
      timestamp: DateTime.utc_now()
    }

    # Broadcast to system-specific topic
    system_topic = PubSubTopics.system_topic(system_id)
    :ok = Phoenix.PubSub.broadcast(@pubsub_name, system_topic, message)

    # Broadcast to detailed system topic as well
    detailed_topic = PubSubTopics.system_detailed_topic(system_id)
    :ok = Phoenix.PubSub.broadcast(@pubsub_name, detailed_topic, message)

    Logger.debug("Broadcasted killmail count update system_id=#{system_id} count=#{count}")

    :ok
  end

  @doc """
  Gets the PubSub name used for broadcasting.
  """
  @spec pubsub_name() :: atom()
  def pubsub_name, do: @pubsub_name

  # Private Functions

  defp broadcast_sse_messages(system_id, kills) do
    alias WandererKills.SSE.Broadcaster, as: SSEBroadcaster

    # Broadcast to system topic
    system_topic = PubSubTopics.system_topic(system_id)
    system_result = SSEBroadcaster.broadcast_killmails(system_topic, kills)

    # Broadcast to all systems topic
    all_systems_topic = PubSubTopics.all_systems_topic()
    all_systems_result = SSEBroadcaster.broadcast_killmails(all_systems_topic, kills)

    # Handle errors
    handle_broadcast_errors(system_topic, system_result)
    handle_broadcast_errors(all_systems_topic, all_systems_result)

    :ok
  end

  defp handle_broadcast_errors(topic, {:error, errors}) do
    Enum.each(errors, fn {:error, {reason, killmail}} ->
      killmail_id = Map.get(killmail, "killmail_id", "unknown")

      Logger.error("[Broadcaster] Failed to broadcast killmail",
        topic: topic,
        killmail_id: killmail_id,
        reason: inspect(reason)
      )
    end)
  end

  defp handle_broadcast_errors(_topic, :ok), do: :ok

  defp broadcast_to_character_topics(kills) do
    # Broadcast each killmail to the relevant character topics
    Enum.each(kills, fn kill ->
      # Extract character IDs from this killmail (victim and attackers)
      character_ids = extract_character_ids_from_map(kill)

      # Broadcast to each character's topic
      Enum.each(character_ids, fn char_id ->
        character_topic = "zkb:character:#{char_id}"

        # Send the individual killmail to the character topic
        message = {:killmail, kill}
        :ok = Phoenix.PubSub.broadcast(@pubsub_name, character_topic, message)

        Logger.debug("Broadcasted to character topic",
          topic: character_topic,
          killmail_id: Map.get(kill, "killmail_id"),
          character_id: char_id
        )
      end)
    end)

    :ok
  end

  defp extract_character_ids_from_map(killmail) when is_map(killmail) do
    # Extract victim character ID
    victim_id = get_in(killmail, ["victim", "character_id"])

    # Extract attacker character IDs
    attackers = Map.get(killmail, "attackers", [])

    attacker_ids =
      Enum.map(attackers, fn attacker ->
        Map.get(attacker, "character_id")
      end)

    # Combine and filter out nils
    [victim_id | attacker_ids]
    |> Enum.filter(& &1)
    |> Enum.uniq()
  end

  defp log_broadcast(system_id, kills) do
    case kills do
      [] ->
        Logger.debug(fn -> "Broadcasted empty killmail update system_id=#{system_id}" end)

      kills ->
        Logger.debug(fn ->
          "Broadcasted killmail update system_id=#{system_id} kill_count=#{length(kills)} topics=[zkb:system:#{system_id}, zkb:system:#{system_id}:detailed, zkb:all_systems]"
        end)
    end
  end
end
