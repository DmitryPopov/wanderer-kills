defmodule WandererKills.SSE.Broadcaster do
  @moduledoc """
  SSE-specific broadcaster that formats messages for the sse_phoenix_pubsub library.

  The sse_phoenix_pubsub library expects messages in a specific format:
  {pubsub_name, data} where data must be a string or list of strings.
  """

  require Logger

  @pubsub_name WandererKills.PubSub

  @doc """
  Broadcasts a killmail to SSE subscribers with proper formatting.
  """
  @spec broadcast_killmail(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_killmail(topic, killmail_map) when is_map(killmail_map) do
    # Convert the killmail map to JSON string for SSE
    case Jason.encode(killmail_map) do
      {:ok, json_data} ->
        # SSE library expects {pubsub_name, data} format
        message = {@pubsub_name, json_data}

        Logger.debug("Broadcasting SSE message to topic: #{topic}",
          message_format: inspect(message)
        )

        Phoenix.PubSub.broadcast(@pubsub_name, topic, message)

      {:error, reason} ->
        Logger.error("Failed to encode killmail for SSE broadcast",
          reason: reason,
          killmail_id: killmail_map["killmail_id"]
        )

        {:error, reason}
    end
  end

  @doc """
  Broadcasts multiple killmails to SSE subscribers.
  """
  @spec broadcast_killmails(String.t(), [map()]) :: :ok | {:error, [term()]}
  def broadcast_killmails(topic, killmails) when is_list(killmails) do
    results =
      Enum.map(killmails, fn killmail ->
        case broadcast_killmail(topic, killmail) do
          :ok -> {:ok, killmail}
          {:error, reason} -> {:error, {reason, killmail}}
        end
      end)

    errors =
      Enum.filter(results, fn
        {:error, _} -> true
        _ -> false
      end)

    case errors do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  @doc """
  Broadcasts a test message to SSE subscribers.
  """
  @spec broadcast_test_message(String.t()) :: :ok | {:error, term()}
  def broadcast_test_message(topic) do
    test_data = %{
      type: "test",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      message: "SSE test broadcast"
    }

    case Jason.encode(test_data) do
      {:ok, json_data} ->
        message = {@pubsub_name, json_data}
        Phoenix.PubSub.broadcast(@pubsub_name, topic, message)
        Logger.info("Sent SSE test message to topic: #{topic}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to encode test message", reason: reason)
        {:error, reason}
    end
  end
end
