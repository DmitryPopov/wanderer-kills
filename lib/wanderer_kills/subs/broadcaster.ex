defmodule WandererKills.Subs.Broadcaster do
  @moduledoc """
  Unified broadcaster replacing 4 separate broadcasters.

  Consolidates:
  - WandererKills.Subs.Subscriptions.Broadcaster
  - WandererKills.SSE.Broadcaster  

  Supports broadcasting to:
  - WebSocket subscribers
  - SSE subscribers  
  - Webhook subscribers
  """

  require Logger
  alias WandererKills.Core.Support.Utils

  @pubsub_name WandererKills.PubSub

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Broadcasts killmail updates to all subscription types.
  """
  @spec broadcast_killmail_update(integer(), [map()]) :: :ok
  def broadcast_killmail_update(system_id, kills) do
    :telemetry.execute(
      [:wanderer_kills, :broadcast, :killmail_update],
      %{kills_count: length(kills)},
      %{system_id: system_id}
    )

    # Broadcast to WebSocket subscribers
    broadcast_websocket_killmails(system_id, kills)

    # Broadcast to SSE subscribers
    broadcast_sse_killmails(system_id, kills)

    # Broadcast to character-specific topics
    broadcast_character_killmails(kills)

    Logger.debug("Broadcasting killmail update",
      system_id: system_id,
      kills_count: length(kills)
    )

    :ok
  end

  @doc """
  Broadcasts killmail count updates.
  """
  @spec broadcast_killmail_count(integer(), integer()) :: :ok
  def broadcast_killmail_count(system_id, count) do
    :telemetry.execute(
      [:wanderer_kills, :broadcast, :killmail_count],
      %{count: count},
      %{system_id: system_id}
    )

    message = %{
      type: :killmail_count_update,
      system_id: system_id,
      count: count,
      timestamp: DateTime.utc_now()
    }

    # Broadcast to WebSocket topics
    broadcast_to_topics(
      [
        Utils.system_topic(system_id),
        Utils.system_detailed_topic(system_id)
      ],
      message
    )

    Logger.debug("Broadcasting killmail count update",
      system_id: system_id,
      count: count
    )

    :ok
  end

  @doc """
  Broadcasts to specific subscription by ID.
  """
  @spec broadcast_to_subscription(String.t(), map(), atom()) :: :ok
  def broadcast_to_subscription(subscription_id, data, type) do
    topic = subscription_topic(subscription_id)

    message =
      case type do
        :websocket -> data
        :sse -> format_sse_message(data)
        :webhook -> data
      end

    Phoenix.PubSub.broadcast(@pubsub_name, topic, message)
  end

  @doc """
  Broadcasts test message (primarily for SSE).
  """
  @spec broadcast_test_message(String.t()) :: :ok | {:error, term()}
  def broadcast_test_message(topic) do
    test_data = %{
      type: "test",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      message: "Unified broadcaster test"
    }

    case format_sse_message(test_data) do
      {:ok, sse_message} ->
        Phoenix.PubSub.broadcast(@pubsub_name, topic, sse_message)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets the PubSub name.
  """
  @spec pubsub_name() :: atom()
  def pubsub_name, do: @pubsub_name

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp broadcast_websocket_killmails(system_id, kills) do
    message = %{
      type: :killmail_update,
      system_id: system_id,
      kills: kills,
      timestamp: DateTime.utc_now()
    }

    # Broadcast to WebSocket topics
    broadcast_to_topics(
      [
        Utils.system_topic(system_id),
        Utils.system_detailed_topic(system_id),
        Utils.all_systems_topic()
      ],
      message
    )
  end

  defp broadcast_sse_killmails(system_id, kills) do
    topics = [
      Utils.system_topic(system_id),
      Utils.all_systems_topic()
    ]

    Enum.each(topics, fn topic ->
      broadcast_sse_kills_to_topic(topic, kills)
    end)
  end

  defp broadcast_sse_kills_to_topic(topic, kills) do
    Enum.each(kills, fn kill ->
      case format_sse_message(kill) do
        {:ok, sse_message} ->
          Phoenix.PubSub.broadcast(@pubsub_name, topic, sse_message)
          emit_sse_telemetry(topic, "killmail")

        {:error, reason} ->
          Logger.error("Failed to format SSE message",
            reason: reason,
            killmail_id: Map.get(kill, "killmail_id")
          )
      end
    end)
  end

  defp broadcast_character_killmails(kills) do
    Enum.each(kills, fn kill ->
      character_ids = extract_character_ids(kill)

      Enum.each(character_ids, fn char_id ->
        topic = "zkb:character:#{char_id}"
        message = {:killmail, kill}
        Phoenix.PubSub.broadcast(@pubsub_name, topic, message)
      end)
    end)
  end

  defp broadcast_to_topics(topics, message) do
    Enum.each(topics, fn topic ->
      Phoenix.PubSub.broadcast(@pubsub_name, topic, message)
    end)
  end

  defp format_sse_message(data) when is_map(data) do
    case Jason.encode(data) do
      {:ok, json_data} -> {:ok, {@pubsub_name, json_data}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_character_ids(killmail) when is_map(killmail) do
    victim_id = get_in(killmail, ["victim", "character_id"])
    attackers = Map.get(killmail, "attackers", [])

    attacker_ids = Enum.map(attackers, &Map.get(&1, "character_id"))

    [victim_id | attacker_ids]
    |> Enum.filter(& &1)
    |> Enum.uniq()
  end

  defp subscription_topic(subscription_id) do
    "subscription:#{subscription_id}"
  end

  defp emit_sse_telemetry(topic, event_type) do
    connection_id =
      "broadcast_#{String.replace(topic, ":", "_")}_#{System.system_time(:millisecond)}"

    :telemetry.execute([:wanderer_kills, :sse, :event, :sent], %{count: 1}, %{
      connection_id: connection_id,
      event_type: event_type
    })
  end
end
