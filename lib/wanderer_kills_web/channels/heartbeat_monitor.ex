defmodule WandererKillsWeb.Channels.HeartbeatMonitor do
  @moduledoc """
  Monitors WebSocket channel processes and cleans up dead connections.

  This module tracks WebSocket connections and periodically checks if the
  underlying processes are still alive, cleaning up any dead connections
  and their associated subscriptions. Phoenix handles WebSocket timeouts
  internally, so we only need to monitor process lifecycle.
  """

  use GenServer
  require Logger

  alias WandererKills.Core.Observability.WebSocketStats
  alias WandererKills.Subs.SubscriptionManager

  @check_interval :timer.seconds(30)

  defmodule State do
    @moduledoc false
    defstruct [:connections, :check_count, :cleanup_count]
  end

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a new WebSocket connection for monitoring
  """
  def register_connection(socket_pid, user_id, subscription_id) do
    GenServer.cast(__MODULE__, {:register, socket_pid, user_id, subscription_id})
  end

  @doc """
  Unregister a connection (called on normal disconnect)
  """
  def unregister_connection(socket_pid) do
    GenServer.cast(__MODULE__, {:unregister, socket_pid})
  end

  @doc """
  Get monitoring stats
  """
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    Logger.info("[HeartbeatMonitor] Starting WebSocket heartbeat monitor")

    # Schedule first check
    schedule_check()

    state = %State{
      connections: %{},
      check_count: 0,
      cleanup_count: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:register, socket_pid, user_id, subscription_id}, state) do
    # Monitor the socket process
    Process.monitor(socket_pid)

    connection_info = %{
      user_id: user_id,
      subscription_id: subscription_id,
      registered_at: DateTime.utc_now(),
      last_heartbeat: DateTime.utc_now()
    }

    new_connections = Map.put(state.connections, socket_pid, connection_info)

    Logger.debug("[HeartbeatMonitor] Registered connection",
      socket_pid: inspect(socket_pid),
      user_id: user_id,
      subscription_id: subscription_id,
      total_connections: map_size(new_connections)
    )

    {:noreply, %{state | connections: new_connections}}
  end

  @impl true
  def handle_cast({:unregister, socket_pid}, state) do
    new_connections = Map.delete(state.connections, socket_pid)

    Logger.debug("[HeartbeatMonitor] Unregistered connection",
      socket_pid: inspect(socket_pid),
      remaining_connections: map_size(new_connections)
    )

    {:noreply, %{state | connections: new_connections}}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = %{
      monitored_connections: map_size(state.connections),
      check_count: state.check_count,
      cleanup_count: state.cleanup_count,
      connections:
        Enum.map(state.connections, fn {pid, info} ->
          %{
            pid: inspect(pid),
            user_id: info.user_id,
            subscription_id: info.subscription_id,
            alive: Process.alive?(pid),
            last_heartbeat_seconds_ago:
              DateTime.diff(DateTime.utc_now(), info.last_heartbeat, :second)
          }
        end)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:check_connections, state) do
    # Find dead connections
    # Only consider a connection dead if the process is actually dead
    # Phoenix handles WebSocket timeouts internally
    {dead_connections, alive_connections} =
      Enum.split_with(state.connections, fn {pid, _info} ->
        not Process.alive?(pid)
      end)

    # Clean up dead connections
    cleanup_count = length(dead_connections)

    if cleanup_count > 0 do
      Logger.warning("[HeartbeatMonitor] Found #{cleanup_count} dead connections")

      Enum.each(dead_connections, fn {pid, info} ->
        cleanup_dead_connection(pid, info)
      end)
    end

    # Schedule next check
    schedule_check()

    new_state = %{
      state
      | connections: Map.new(alive_connections),
        check_count: state.check_count + 1,
        cleanup_count: state.cleanup_count + cleanup_count
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case Map.get(state.connections, pid) do
      nil ->
        {:noreply, state}

      conn_info ->
        Logger.debug("[HeartbeatMonitor] Socket process died",
          socket_pid: inspect(pid),
          user_id: conn_info.user_id,
          reason: inspect(reason)
        )

        cleanup_dead_connection(pid, conn_info)
        new_connections = Map.delete(state.connections, pid)
        {:noreply, %{state | connections: new_connections}}
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp schedule_check do
    Process.send_after(self(), :check_connections, @check_interval)
  end

  defp cleanup_dead_connection(pid, conn_info) do
    Logger.info("[HeartbeatMonitor] Cleaning up dead connection",
      socket_pid: inspect(pid),
      user_id: conn_info.user_id,
      subscription_id: conn_info.subscription_id
    )

    # Remove the subscription
    if conn_info.subscription_id do
      SubscriptionManager.remove_subscription(conn_info.subscription_id)
    end

    # Update WebSocket stats
    WebSocketStats.track_connection(:disconnected, %{
      user_id: conn_info.user_id,
      reason: :heartbeat_timeout
    })

    # Try to shutdown the process gracefully if it's still alive
    if Process.alive?(pid) do
      # First attempt a gentle shutdown
      Process.exit(pid, :shutdown)

      # Give it a moment to clean up
      Process.sleep(100)

      # If still alive, force kill
      if Process.alive?(pid) do
        Logger.warning("[HeartbeatMonitor] Process didn't respond to shutdown, forcing exit",
          socket_pid: inspect(pid)
        )

        Process.exit(pid, :kill)
      end
    end
  end
end
