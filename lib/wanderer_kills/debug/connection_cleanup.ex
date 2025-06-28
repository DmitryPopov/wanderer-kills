defmodule WandererKills.Debug.ConnectionCleanup do
  @moduledoc """
  Tools to clean up leaked WebSocket connections and orphaned processes
  """

  alias WandererKills.Core.Observability.WebSocketStats
  alias WandererKills.Subs.SubscriptionManager
  require Logger

  @doc """
  Clean up all dead WebSocket subscriptions and reset connection counters
  """
  def cleanup_dead_connections do
    Logger.info("[ConnectionCleanup] Starting WebSocket connection cleanup")

    # Get all subscriptions
    subscriptions = SubscriptionManager.list_subscriptions()
    websocket_subs = Enum.filter(subscriptions, &(&1["socket_pid"] != nil))

    # Find and remove dead subscriptions
    dead_count =
      Enum.reduce(websocket_subs, 0, fn sub, acc ->
        socket_pid = sub["socket_pid"]

        is_alive =
          try do
            Process.alive?(socket_pid)
          rescue
            _ -> false
          end

        if is_alive do
          acc
        else
          Logger.info("[ConnectionCleanup] Removing dead subscription",
            subscription_id: sub["id"],
            user_id: sub["user_id"],
            socket_pid: inspect(socket_pid)
          )

          SubscriptionManager.remove_subscription(sub["id"])
          acc + 1
        end
      end)

    Logger.info("[ConnectionCleanup] Removed #{dead_count} dead subscriptions")

    # Reset WebSocket stats to match reality
    reset_connection_stats()

    {:ok, %{dead_subscriptions_removed: dead_count}}
  end

  @doc """
  Reset WebSocket connection statistics to match actual state
  """
  def reset_connection_stats do
    # Count actual alive WebSocket connections
    alive_count = length(get_alive_websocket_pids())

    # Get current stats
    {:ok, current_stats} = WebSocketStats.get_stats()

    # Calculate the correction needed
    correction = current_stats.connections.active - alive_count

    if correction > 0 do
      Logger.info("[ConnectionCleanup] Correcting connection count by -#{correction}")

      # Send disconnection events to correct the count
      Enum.each(1..correction, fn _ ->
        WebSocketStats.track_connection(:disconnected, %{reason: :cleanup})
      end)
    end

    Logger.info("[ConnectionCleanup] Connection stats reset complete",
      actual_connections: alive_count,
      previous_count: current_stats.connections.active,
      correction: correction
    )

    :ok
  end

  @doc """
  Kill orphaned channel processes that don't have active subscriptions
  """
  def cleanup_orphaned_channels do
    Logger.info("[ConnectionCleanup] Starting orphaned channel cleanup")

    # Get all channel processes
    channel_processes = find_channel_processes()

    # Get all alive socket PIDs from subscriptions
    alive_sockets = MapSet.new(get_alive_websocket_pids())

    # Kill channels not in alive_sockets
    killed_count =
      Enum.reduce(channel_processes, 0, fn pid, acc ->
        if MapSet.member?(alive_sockets, pid) do
          acc
        else
          Logger.info(
            "[ConnectionCleanup] Shutting down orphaned channel process: #{inspect(pid)}"
          )

          try do
            # First try graceful shutdown
            Process.exit(pid, :shutdown)
            Process.sleep(50)

            # If still alive, force kill
            if Process.alive?(pid) do
              Logger.warning(
                "[ConnectionCleanup] Process didn't respond to shutdown, forcing: #{inspect(pid)}"
              )

              Process.exit(pid, :kill)
            end

            acc + 1
          rescue
            e ->
              Logger.error("[ConnectionCleanup] Failed to shutdown process: #{inspect(pid)}",
                error: inspect(e)
              )

              acc
          end
        end
      end)

    Logger.info("[ConnectionCleanup] Killed #{killed_count} orphaned channel processes")

    {:ok, %{orphaned_channels_killed: killed_count}}
  end

  @doc """
  Perform full cleanup of all connection-related issues
  """
  def full_cleanup do
    Logger.info("[ConnectionCleanup] Starting full connection cleanup")

    # Step 1: Clean dead subscriptions
    {:ok, dead_result} = cleanup_dead_connections()

    # Step 2: Clean orphaned channels
    {:ok, orphan_result} = cleanup_orphaned_channels()

    # Step 3: Force garbage collection
    :erlang.garbage_collect()

    result = Map.merge(dead_result, orphan_result)
    Logger.info("[ConnectionCleanup] Full cleanup complete", result)

    {:ok, result}
  end

  @doc """
  Monitor connection health and auto-cleanup if needed
  """
  def start_monitoring(interval_ms \\ 60_000) do
    spawn_link(fn -> monitor_loop(interval_ms) end)
  end

  defp monitor_loop(interval_ms) do
    Process.sleep(interval_ms)

    {:ok, stats} = WebSocketStats.get_stats()
    leak_count = stats.connections.total_connected - stats.connections.total_disconnected

    if leak_count > 10 do
      Logger.warning("[ConnectionCleanup] Detected connection leak: #{leak_count} connections")
      full_cleanup()
    end

    monitor_loop(interval_ms)
  end

  defp find_channel_processes do
    Process.list()
    |> Enum.filter(&channel_process?/1)
  end

  defp channel_process?(pid) do
    case Process.info(pid, [:dictionary]) do
      nil ->
        false

      info ->
        info
        |> Keyword.get(:dictionary, [])
        |> Enum.any?(fn
          {:"$initial_call", {WandererKillsWeb.KillmailChannel, _, _}} -> true
          _ -> false
        end)
    end
  end

  defp get_alive_websocket_pids do
    try do
      SubscriptionManager.list_subscriptions()
      |> Enum.filter(&(&1["socket_pid"] != nil))
      |> Enum.map(& &1["socket_pid"])
      |> Enum.filter(fn pid ->
        try do
          Process.alive?(pid)
        rescue
          _ -> false
        end
      end)
    rescue
      _ -> []
    end
  end
end
