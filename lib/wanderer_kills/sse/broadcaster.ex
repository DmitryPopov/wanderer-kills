defmodule WandererKills.SSE.Broadcaster do
  @moduledoc """
  SSE-specific broadcaster that formats messages for the sse_phoenix_pubsub library.

  The sse_phoenix_pubsub library expects messages in a specific format:
  {pubsub_name, data} where data must be a string or list of strings.
  """

  require Logger

  @pubsub_name WandererKills.PubSub

  # Event type constants
  @event_type_killmail "killmail"
  @event_type_test "test"

  # Private helper to check if dev environment
  defp dev_env? do
    Application.get_env(:wanderer_kills, :env) == :dev
  end

  # Private helper to emit telemetry events
  defp emit_telemetry(topic, event_type, prefix \\ "broadcast") do
    connection_id =
      "#{prefix}_#{String.replace(topic, ":", "_")}_#{System.system_time(:millisecond)}"

    :telemetry.execute([:wanderer_kills, :sse, :event, :sent], %{count: 1}, %{
      connection_id: connection_id,
      event_type: event_type
    })
  end

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

        if dev_env?() do
          Logger.info(
            "[SSE] Broadcasting killmail to SSE subscribers - Topic: #{topic}, Killmail: #{killmail_map["killmail_id"]}, System: #{killmail_map["system_id"]}, Victim Ship: #{killmail_map["victim"]["ship_name"] || "Unknown"}"
          )
        end

        result = Phoenix.PubSub.broadcast(@pubsub_name, topic, message)

        # Track SSE event sent
        emit_telemetry(topic, @event_type_killmail)

        if dev_env?() do
          Logger.info(
            "[SSE] Killmail broadcast completed - Topic: #{topic}, Killmail: #{killmail_map["killmail_id"]}, Result: #{inspect(result)}"
          )
        end

        result

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
    if dev_env?() do
      killmail_ids = Enum.map(killmails, & &1["killmail_id"])

      Logger.info(
        "[SSE] Broadcasting batch of killmails to SSE subscribers - Topic: #{topic}, Count: #{length(killmails)}, IDs: #{inspect(killmail_ids)}"
      )
    end

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
        result = Phoenix.PubSub.broadcast(@pubsub_name, topic, message)

        # Track SSE test event sent
        emit_telemetry(topic, @event_type_test, "test_broadcast")

        if dev_env?() do
          Logger.info("[SSE] Sent test message to SSE subscribers - Topic: #{topic}")
        end

        result

      {:error, reason} ->
        Logger.error("Failed to encode test message", reason: reason)
        {:error, reason}
    end
  end
end
