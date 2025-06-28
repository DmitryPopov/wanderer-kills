defmodule WandererKills.Debug.ConnectionAnalyzer do
  @moduledoc """
  Diagnostic tool to analyze WebSocket connection leaks
  """

  alias WandererKills.Core.Observability.WebSocketStats
  alias WandererKills.Subs.{SubscriptionManager, SubscriptionWorker}

  def analyze_connections do
    IO.puts("\n=== WebSocket Connection Analysis ===\n")

    # Get WebSocket stats with error handling
    stats =
      case WebSocketStats.get_stats() do
        {:ok, stats} ->
          stats

        {:error, reason} ->
          IO.puts("WARNING: Failed to get WebSocket stats: #{inspect(reason)}")
          %{connections: %{active: 0, total_connected: 0, total_disconnected: 0}}
      end

    IO.puts("WebSocket Stats:")
    IO.puts("  Active connections (counter): #{stats.connections.active}")
    IO.puts("  Total connected: #{stats.connections.total_connected}")
    IO.puts("  Total disconnected: #{stats.connections.total_disconnected}")

    IO.puts(
      "  Connection leak: #{stats.connections.total_connected - stats.connections.total_disconnected}"
    )

    # Get all subscriptions with error handling
    subscriptions =
      try do
        SubscriptionManager.list_subscriptions()
      rescue
        e ->
          IO.puts("WARNING: Failed to list subscriptions: #{inspect(e)}")
          []
      end

    websocket_subs = Enum.filter(subscriptions, &(&1["socket_pid"] != nil))

    IO.puts("\nSubscription Analysis:")
    IO.puts("  Total subscriptions: #{length(subscriptions)}")
    IO.puts("  WebSocket subscriptions: #{length(websocket_subs)}")

    # Check socket processes
    alive_sockets =
      websocket_subs
      |> Enum.map(& &1["socket_pid"])
      |> Enum.filter(&Process.alive?/1)

    IO.puts("  Alive socket processes: #{length(alive_sockets)}")
    IO.puts("  Dead socket processes: #{length(websocket_subs) - length(alive_sockets)}")

    # Check subscription workers with error handling
    worker_pids =
      subscriptions
      |> Enum.map(fn sub ->
        try do
          case SubscriptionWorker.lookup_subscription(sub["id"]) do
            {:ok, pid} -> pid
            :error -> nil
          end
        rescue
          _ -> nil
        end
      end)
      |> Enum.filter(& &1)

    IO.puts("\nSubscription Workers:")
    IO.puts("  Active workers: #{length(worker_pids)}")

    # Get Phoenix channel processes
    channel_processes = find_channel_processes()

    IO.puts("\nChannel Processes:")
    IO.puts("  Active channel processes: #{length(channel_processes)}")

    # Memory usage by process type
    IO.puts("\nMemory Usage by Process Type:")
    analyze_process_memory()

    # Dead subscription details
    if length(websocket_subs) > length(alive_sockets) do
      IO.puts("\nDead WebSocket Subscriptions:")

      websocket_subs
      |> Enum.filter(fn sub -> not Process.alive?(sub["socket_pid"]) end)
      |> Enum.each(&print_dead_subscription/1)
    end

    :ok
  end

  defp analyze_process_memory do
    processes = Process.list()

    memory_by_type =
      processes
      |> Enum.map(fn pid ->
        case Process.info(pid, [:memory, :current_function, :dictionary]) do
          nil ->
            nil

          info ->
            memory = Keyword.get(info, :memory, 0)
            type = identify_process_type(info)
            {type, memory}
        end
      end)
      |> Enum.filter(& &1)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {type, memories} ->
        total = Enum.sum(memories)
        count = length(memories)
        avg = if count > 0, do: div(total, count), else: 0
        {type, %{total: total, count: count, avg: avg}}
      end)
      |> Enum.sort_by(fn {_, stats} -> -stats.total end)
      |> Enum.take(10)

    Enum.each(memory_by_type, fn {type, stats} ->
      IO.puts(
        "  #{type}: #{format_bytes(stats.total)} (#{stats.count} processes, avg: #{format_bytes(stats.avg)})"
      )
    end)
  end

  defp identify_process_type(info) do
    dict = Keyword.get(info, :dictionary, [])
    current = Keyword.get(info, :current_function, {nil, nil, nil})

    cond do
      has_initial_call?(dict, WandererKillsWeb.KillmailChannel) -> "KillmailChannel"
      has_initial_call?(dict, WandererKills.Subs.SubscriptionWorker) -> "SubscriptionWorker"
      has_initial_call?(dict, Phoenix.Channel.Server) -> "Phoenix.Channel"
      has_initial_call?(dict, WandererKills.Storage.KillmailStore) -> "KillmailStore"
      elem(current, 0) == :gen_server -> "GenServer"
      elem(current, 0) == :supervisor -> "Supervisor"
      true -> "Other"
    end
  end

  defp has_initial_call?(dict, module) do
    Enum.any?(dict, fn
      {:"$initial_call", {^module, _, _}} -> true
      _ -> false
    end)
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 2)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1024 / 1024, 2)} MB"

  defp print_dead_subscription(sub) do
    IO.puts(
      "  ID: #{sub["id"]}, User: #{sub["user_id"]}, Systems: #{length(sub["system_ids"] || [])}"
    )
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
        |> has_killmail_channel_initial_call?()
    end
  end

  defp has_killmail_channel_initial_call?(dictionary) do
    Enum.any?(dictionary, fn
      {:"$initial_call", {WandererKillsWeb.KillmailChannel, _, _}} -> true
      _ -> false
    end)
  end
end
