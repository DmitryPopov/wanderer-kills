defmodule WandererKills.Core.Storage.MemoryMonitor do
  @moduledoc """
  Monitors ETS memory usage and triggers cleanup when thresholds are exceeded.

  This GenServer periodically checks memory usage and can trigger emergency
  cleanup when memory exceeds configured thresholds.
  """

  use GenServer
  require Logger

  alias WandererKills.Core.Storage.CleanupWorker

  # Default check interval if not configured
  @default_check_interval :timer.seconds(30)

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get current memory statistics
  """
  def get_memory_stats do
    GenServer.call(__MODULE__, :get_memory_stats)
  end

  @doc """
  Manually trigger memory check
  """
  def check_memory_now do
    GenServer.cast(__MODULE__, :check_memory)
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Get all configuration from storage config
    storage_config = Application.get_env(:wanderer_kills, :storage, [])

    # Memory thresholds
    memory_threshold_mb = Keyword.get(storage_config, :memory_threshold_mb, 1000)
    emergency_threshold_mb = Keyword.get(storage_config, :emergency_threshold_mb, 1500)

    # Check interval
    check_interval_ms =
      Keyword.get(storage_config, :memory_check_interval_ms, @default_check_interval)

    # Emergency cleanup thresholds
    emergency_killmail_threshold =
      Keyword.get(storage_config, :emergency_killmail_threshold, 50_000)

    emergency_removal_percentage = Keyword.get(storage_config, :emergency_removal_percentage, 25)

    Logger.info("[MemoryMonitor] Starting ETS memory monitor",
      memory_threshold_mb: memory_threshold_mb,
      emergency_threshold_mb: emergency_threshold_mb,
      check_interval_ms: check_interval_ms,
      emergency_killmail_threshold: emergency_killmail_threshold,
      emergency_removal_percentage: emergency_removal_percentage
    )

    # Schedule first check
    schedule_check(check_interval_ms)

    state = %{
      last_check: nil,
      last_cleanup: nil,
      cleanup_count: 0,
      emergency_cleanup_count: 0,
      memory_threshold_mb: memory_threshold_mb,
      emergency_threshold_mb: emergency_threshold_mb,
      check_interval_ms: check_interval_ms,
      emergency_killmail_threshold: emergency_killmail_threshold,
      emergency_removal_percentage: emergency_removal_percentage
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_memory_stats, _from, state) do
    stats = calculate_memory_stats()

    response =
      Map.merge(stats, %{
        last_check: state.last_check,
        last_cleanup: state.last_cleanup,
        cleanup_count: state.cleanup_count,
        emergency_cleanup_count: state.emergency_cleanup_count
      })

    {:reply, response, state}
  end

  @impl true
  def handle_cast(:check_memory, state) do
    new_state = perform_memory_check(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:scheduled_check, state) do
    new_state = perform_memory_check(state)
    schedule_check(state.check_interval_ms)
    {:noreply, new_state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp schedule_check(interval_ms) do
    Process.send_after(self(), :scheduled_check, interval_ms)
  end

  defp perform_memory_check(state) do
    stats = calculate_memory_stats()

    Logger.debug("[MemoryMonitor] Memory check",
      ets_memory_mb: stats.ets_memory_mb,
      killmail_count: stats.killmail_count,
      threshold_mb: state.memory_threshold_mb
    )

    new_state = %{state | last_check: DateTime.utc_now()}

    cond do
      stats.ets_memory_mb > state.emergency_threshold_mb ->
        Logger.warning("[MemoryMonitor] Emergency memory threshold exceeded!",
          ets_memory_mb: stats.ets_memory_mb,
          threshold_mb: state.emergency_threshold_mb
        )

        perform_emergency_cleanup(new_state)

      stats.ets_memory_mb > state.memory_threshold_mb ->
        Logger.warning("[MemoryMonitor] Memory threshold exceeded",
          ets_memory_mb: stats.ets_memory_mb,
          threshold_mb: state.memory_threshold_mb
        )

        perform_standard_cleanup(new_state)

      true ->
        new_state
    end
  end

  defp calculate_memory_stats do
    # Get table-specific memory
    tables = [
      {:killmails, :ets.info(:killmails, :memory) || 0},
      {:system_killmails, :ets.info(:system_killmails, :memory) || 0},
      {:system_kill_counts, :ets.info(:system_kill_counts, :memory) || 0},
      {:system_fetch_timestamps, :ets.info(:system_fetch_timestamps, :memory) || 0},
      {:killmail_events, :ets.info(:killmail_events, :memory) || 0},
      {:client_offsets, :ets.info(:client_offsets, :memory) || 0}
    ]

    total_ets_memory = Enum.reduce(tables, 0, fn {_name, memory}, acc -> acc + memory end)

    # Get entry counts
    killmail_count = :ets.info(:killmails, :size) || 0

    %{
      ets_memory_mb:
        Float.round(total_ets_memory * :erlang.system_info(:wordsize) / 1024 / 1024, 2),
      killmail_count: killmail_count,
      table_memory:
        Enum.map(tables, fn {name, memory} ->
          {name, Float.round(memory * :erlang.system_info(:wordsize) / 1024 / 1024, 2)}
        end)
        |> Enum.into(%{})
    }
  end

  defp perform_standard_cleanup(state) do
    Logger.info("[MemoryMonitor] Triggering standard memory cleanup")

    # Trigger immediate cleanup
    case CleanupWorker.cleanup_now() do
      {:ok, stats} ->
        Logger.info("[MemoryMonitor] Standard cleanup completed", stats)

      {:error, reason} ->
        Logger.error("[MemoryMonitor] Standard cleanup failed", error: reason)
    end

    %{state | last_cleanup: DateTime.utc_now(), cleanup_count: state.cleanup_count + 1}
  end

  defp perform_emergency_cleanup(state) do
    Logger.warning("[MemoryMonitor] Triggering EMERGENCY memory cleanup")

    # First do standard cleanup
    CleanupWorker.cleanup_now()

    # Then do more aggressive cleanup - reduce TTL temporarily
    emergency_cleanup_old_killmails(state)

    # Force garbage collection
    :erlang.garbage_collect()

    %{
      state
      | last_cleanup: DateTime.utc_now(),
        cleanup_count: state.cleanup_count + 1,
        emergency_cleanup_count: state.emergency_cleanup_count + 1
    }
  end

  defp emergency_cleanup_old_killmails(state) do
    # WARNING: Emergency cleanup performs direct ETS table manipulation without
    # coordination with other processes. While individual ETS operations are atomic,
    # the multi-step cleanup process (deleting from multiple tables) may cause
    # temporary inconsistencies. Other processes may observe partially cleaned data.
    # This is acceptable in emergency situations where memory pressure requires
    # immediate action to prevent system failure.

    try do
      Logger.warning("[MemoryMonitor] Emergency cleanup - removing killmails older than 12 hours")

      # For emergency cleanup, we'll just trigger multiple standard cleanups
      # and let KillmailStore handle the details

      # First cleanup
      CleanupWorker.cleanup_now()

      # Get current killmail count
      before_count = :ets.info(:killmails, :size) || 0

      # If still too many, remove oldest percentage of killmails
      if before_count > state.emergency_killmail_threshold do
        removal_count = div(before_count * state.emergency_removal_percentage, 100)
        remove_oldest_killmails(removal_count)
      end

      after_count = :ets.info(:killmails, :size) || 0
      removed = before_count - after_count

      Logger.warning("[MemoryMonitor] Emergency cleanup removed #{removed} killmails")
    rescue
      error ->
        Logger.error("[MemoryMonitor] Emergency cleanup failed", error: inspect(error))
    end
  end

  defp remove_oldest_killmails(target_removal_count) do
    # Use a more efficient approach to find the oldest N killmails
    # without sorting the entire dataset
    oldest_killmails = find_oldest_killmails(target_removal_count)

    # Extract just the killmail IDs for batch removal
    killmail_ids_to_remove = Enum.map(oldest_killmails, fn {id, _} -> id end)

    # Batch remove from killmails table
    Enum.each(killmail_ids_to_remove, fn killmail_id ->
      :ets.delete(:killmails, killmail_id)
    end)

    # Batch remove from system indexes
    batch_remove_from_system_indexes(killmail_ids_to_remove)
  end

  defp find_oldest_killmails(target_count) do
    # Use a max-heap (gb_sets) to efficiently find the oldest N killmails
    # gb_sets stores elements in order, so we can use it as a heap
    initial_acc = %{
      heap: :gb_sets.new(),
      count: 0,
      target: target_count
    }

    result =
      :ets.foldl(
        fn {id, data}, acc ->
          timestamp = extract_timestamp(data)
          add_to_heap(acc, id, timestamp)
        end,
        initial_acc,
        :killmails
      )

    # Convert heap to expected list format [{id, timestamp}, ...]
    heap_to_list(result.heap)
  end

  defp extract_timestamp(data) do
    case data do
      %{killmail_time: time} -> time
      %{"killmail_time" => time} -> time
      # Fallback
      _ -> DateTime.utc_now()
    end
  end

  defp add_to_heap(%{heap: heap, count: count, target: target} = acc, id, timestamp) do
    # Convert DateTime to Unix timestamp for comparison
    unix_timestamp = DateTime.to_unix(timestamp, :microsecond)

    cond do
      count < target ->
        add_to_heap_below_target(acc, unix_timestamp, id, timestamp)

      :gb_sets.is_empty(heap) ->
        # Shouldn't happen, but handle empty heap case
        acc

      true ->
        replace_if_older(acc, unix_timestamp, id, timestamp)
    end
  end

  defp add_to_heap_below_target(acc, unix_timestamp, id, timestamp) do
    # Haven't reached target yet, just add to heap
    # Store as {unix_timestamp, id, original_timestamp} so gb_sets orders by unix timestamp
    new_heap = :gb_sets.add({unix_timestamp, id, timestamp}, acc.heap)
    %{acc | heap: new_heap, count: acc.count + 1}
  end

  defp replace_if_older(%{heap: heap} = acc, unix_timestamp, id, timestamp) do
    {max_unix_ts, max_id, max_timestamp} = :gb_sets.largest(heap)

    if unix_timestamp < max_unix_ts do
      # Current timestamp is older than the max, so replace
      new_heap =
        :gb_sets.add(
          {unix_timestamp, id, timestamp},
          :gb_sets.delete_any({max_unix_ts, max_id, max_timestamp}, heap)
        )

      %{acc | heap: new_heap}
    else
      # Current timestamp is newer or equal, keep current heap
      acc
    end
  end

  defp heap_to_list(heap) do
    # Convert gb_sets to list and transform to expected format
    :gb_sets.to_list(heap)
    |> Enum.map(fn {_unix_ts, id, timestamp} -> {id, timestamp} end)
  end

  defp batch_remove_from_system_indexes(killmail_ids_to_remove) do
    # Convert to MapSet for O(1) membership checking
    ids_set = MapSet.new(killmail_ids_to_remove)

    # Process each system entry only once
    :ets.foldl(
      fn {system_id, killmail_ids}, _acc ->
        process_system_entry(system_id, killmail_ids, ids_set)
      end,
      nil,
      :system_killmails
    )
  end

  defp process_system_entry(system_id, killmail_ids, ids_to_remove) do
    # Check if this system has any of the killmails we're removing
    new_ids = Enum.reject(killmail_ids, &MapSet.member?(ids_to_remove, &1))

    if length(new_ids) != length(killmail_ids) do
      update_system_killmails_table(system_id, new_ids)
    end
  end

  defp update_system_killmails_table(system_id, new_ids) do
    # Only update if we actually removed something
    if new_ids == [] do
      :ets.delete(:system_killmails, system_id)
    else
      :ets.insert(:system_killmails, {system_id, new_ids})
    end
  end
end
