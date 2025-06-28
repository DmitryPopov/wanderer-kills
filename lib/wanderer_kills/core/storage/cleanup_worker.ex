defmodule WandererKills.Core.Storage.CleanupWorker do
  @moduledoc """
  Periodic cleanup worker for KillmailStore ETS tables.

  This GenServer runs periodic cleanup of old data based on configured TTLs:
  - killmails: 2 days (reduced from 7 days)
  - system_killmails: 2 days (cleaned with killmails)
  - system_kill_counts: Cleaned when system has no killmails
  - system_fetch_timestamps: 12 hours (reduced from 1 day)
  - killmail_events: 2 days (reduced from 7 days)
  - client_offsets: 1 day (reduced from 3 days)

  The cleanup interval can be configured via:
  ```
  config :wanderer_kills, :storage,
    gc_interval_ms: 3_600_000  # 1 hour default
  ```
  """

  use GenServer
  require Logger

  alias WandererKills.Core.Storage.KillmailStore

  @default_interval_ms :timer.hours(1)
  @default_cleanup_timeout_ms :timer.minutes(5)

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the cleanup worker.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Triggers an immediate cleanup.

  The timeout can be configured via:
  ```
  config :wanderer_kills, :storage,
    cleanup_timeout_ms: 300_000  # 5 minutes default
  ```
  """
  def cleanup_now do
    timeout = get_cleanup_timeout()
    GenServer.call(__MODULE__, :cleanup_now, timeout)
  end

  @doc """
  Gets the current cleanup statistics.
  """
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    Logger.info("[CleanupWorker] Starting storage cleanup worker")

    # Get configured interval or use default
    interval = get_cleanup_interval()

    # Schedule first cleanup and track when it will run
    next_cleanup_at = schedule_cleanup(interval)

    state = %{
      interval: interval,
      last_cleanup: nil,
      last_stats: nil,
      total_cleanups: 0,
      next_cleanup_at: next_cleanup_at
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:cleanup_now, _from, state) do
    Logger.info("[CleanupWorker] Manual cleanup triggered")

    case perform_cleanup() do
      {:ok, stats} ->
        new_state = %{
          state
          | last_cleanup: DateTime.utc_now(),
            last_stats: stats,
            total_cleanups: state.total_cleanups + 1
        }

        {:reply, {:ok, stats}, new_state}

      {:error, reason} = error ->
        Logger.error("[CleanupWorker] Cleanup failed", error: reason)
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = %{
      last_cleanup: state.last_cleanup,
      last_stats: state.last_stats,
      total_cleanups: state.total_cleanups,
      next_cleanup_in: calculate_next_cleanup_time(state.next_cleanup_at),
      interval_ms: state.interval
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:perform_cleanup, state) do
    Logger.debug("[CleanupWorker] Starting scheduled cleanup")

    # Perform cleanup
    stats =
      case perform_cleanup() do
        {:ok, cleanup_stats} ->
          Logger.debug("[CleanupWorker] Cleanup completed", cleanup_stats)
          cleanup_stats

        {:error, reason} ->
          Logger.error("[CleanupWorker] Cleanup failed", error: reason)
          nil
      end

    # Schedule next cleanup and track when it will run
    next_cleanup_at = schedule_cleanup(state.interval)

    # Update state
    new_state = %{
      state
      | last_cleanup: DateTime.utc_now(),
        last_stats: stats,
        total_cleanups: state.total_cleanups + 1,
        next_cleanup_at: next_cleanup_at
    }

    {:noreply, new_state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp get_cleanup_interval do
    Application.get_env(:wanderer_kills, :storage, [])
    |> Keyword.get(:gc_interval_ms, @default_interval_ms)
  end

  defp get_cleanup_timeout do
    Application.get_env(:wanderer_kills, :storage, [])
    |> Keyword.get(:cleanup_timeout_ms, @default_cleanup_timeout_ms)
  end

  defp schedule_cleanup(interval) do
    Process.send_after(self(), :perform_cleanup, interval)
    DateTime.add(DateTime.utc_now(), interval, :millisecond)
  end

  defp perform_cleanup do
    try do
      KillmailStore.cleanup_old_data()
    rescue
      e ->
        {:error, Exception.format(:error, e, __STACKTRACE__)}
    end
  end

  defp calculate_next_cleanup_time(nil) do
    # No cleanup scheduled yet
    0
  end

  defp calculate_next_cleanup_time(next_cleanup_at) do
    # Calculate milliseconds remaining until next cleanup
    now = DateTime.utc_now()
    diff = DateTime.diff(next_cleanup_at, now, :millisecond)

    # Return 0 if the cleanup time has passed (shouldn't happen normally)
    max(0, diff)
  end
end
