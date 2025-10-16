defmodule WandererKills.Ingest.Historical.HistoricalStreamer do
  @moduledoc """
  Streams historical killmail data from zkillboard's history API.

  Fetches daily kill lists and processes them through the standard pipeline,
  ensuring full ESI enrichment and consistent formatting with real-time data.
  """

  use GenServer
  require Logger

  alias WandererKills.Core.Support.SupervisedTask
  alias WandererKills.Ingest.Killmails.{UnifiedProcessor, ZkbClient}
  alias WandererKills.Ingest.SmartRateLimiter

  @type state :: %{
          current_date: Date.t(),
          end_date: Date.t(),
          start_date: Date.t(),
          daily_queue: list({integer(), String.t()}),
          processed_count: non_neg_integer(),
          failed_count: non_neg_integer(),
          paused: boolean(),
          batch_timer: reference() | nil,
          config: map(),
          retry_count: non_neg_integer()
        }

  # Default configuration
  @default_config %{
    daily_limit: 5000,
    batch_size: 50,
    batch_interval_ms: 10_000,
    max_retries: 3,
    retry_delay_ms: 5_000
  }

  # Telemetry events
  @telemetry_prefix [:wanderer_kills, :historical_streamer]

  # Public API

  @doc """
  Starts the historical streamer process.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Pauses historical streaming.
  """
  def pause do
    GenServer.call(__MODULE__, :pause)
  end

  @doc """
  Resumes historical streaming.
  """
  def resume do
    GenServer.call(__MODULE__, :resume)
  end

  @doc """
  Gets the current streaming status.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    config = get_config()

    if config[:enabled] do
      Logger.info("Starting historical streamer", config: config)

      start_date = parse_date(config[:start_date])

      state = %{
        current_date: start_date,
        end_date: Date.utc_today(),
        start_date: start_date,
        daily_queue: [],
        processed_count: 0,
        failed_count: 0,
        paused: false,
        batch_timer: nil,
        config: Map.merge(@default_config, config),
        retry_count: 0
      }

      # Start processing after a short delay
      Process.send_after(self(), :start_daily_fetch, 1000)

      {:ok, state}
    else
      Logger.info("Historical streamer disabled")
      :ignore
    end
  end

  @impl true
  def handle_call(:pause, _from, state) do
    Logger.info("Pausing historical streamer")

    # Cancel any pending batch timer
    if state.batch_timer do
      Process.cancel_timer(state.batch_timer)
    end

    {:reply, :ok, %{state | paused: true, batch_timer: nil}}
  end

  @impl true
  def handle_call(:resume, _from, %{paused: true} = state) do
    Logger.info("Resuming historical streamer")

    # Schedule next batch if we have items in queue
    state =
      if state.daily_queue != [] do
        %{state | batch_timer: schedule_next_batch(0)}
      else
        Process.send_after(self(), :start_daily_fetch, 100)
        state
      end

    {:reply, :ok, %{state | paused: false}}
  end

  @impl true
  def handle_call(:resume, _from, state) do
    {:reply, {:error, :not_paused}, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      current_date: state.current_date,
      end_date: state.end_date,
      queue_size: length(state.daily_queue),
      processed_count: state.processed_count,
      failed_count: state.failed_count,
      paused: state.paused,
      progress_percentage: calculate_progress(state)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:start_daily_fetch, %{paused: true} = state) do
    # Skip if paused
    {:noreply, state}
  end

  @impl true
  def handle_info(:start_daily_fetch, state) do
    if Date.compare(state.current_date, state.end_date) == :gt do
      Logger.info("Historical streaming completed",
        end_date: state.end_date,
        total_processed: state.processed_count,
        total_failed: state.failed_count
      )

      {:noreply, state}
    else
      Logger.info("Fetching historical kills", date: state.current_date)

      # Start async task to fetch daily kills
      parent_pid = self()

      SupervisedTask.start_child(
        fn -> fetch_daily_kills(state.current_date, parent_pid) end,
        task_name: "fetch_daily_kills",
        metadata: %{date: state.current_date}
      )

      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:task_result, {:ok, kill_list}}, state) do
    Logger.info("Received daily kill list",
      date: state.current_date,
      count: length(kill_list)
    )

    # Apply daily limit if configured
    kill_list =
      if state.config.daily_limit > 0 do
        Enum.take(kill_list, state.config.daily_limit)
      else
        kill_list
      end

    # Update state with new queue and reset retry count on success
    state = %{state | daily_queue: kill_list, retry_count: 0}

    # Schedule first batch
    timer = schedule_next_batch(0)

    {:noreply, %{state | batch_timer: timer}}
  end

  @impl true
  def handle_info({:task_result, {:error, reason}}, state) do
    new_retry_count = state.retry_count + 1
    max_retries = state.config.max_retries

    Logger.error("Failed to fetch daily kills",
      date: state.current_date,
      error: reason,
      retry_count: new_retry_count,
      max_retries: max_retries
    )

    if new_retry_count >= max_retries do
      # Exceeded max retries, move to next day
      Logger.warning("Max retries exceeded, advancing to next day",
        date: state.current_date,
        retries: new_retry_count
      )

      Process.send_after(self(), :advance_date, state.config.retry_delay_ms)
      {:noreply, %{state | retry_count: 0}}
    else
      # Retry after delay
      Logger.info("Retrying daily fetch after delay",
        date: state.current_date,
        retry_count: new_retry_count,
        delay_ms: state.config.retry_delay_ms
      )

      Process.send_after(self(), :start_daily_fetch, state.config.retry_delay_ms)
      {:noreply, %{state | retry_count: new_retry_count}}
    end
  end

  @impl true
  def handle_info(:process_batch, %{paused: true} = state) do
    # Skip if paused
    {:noreply, %{state | batch_timer: nil}}
  end

  @impl true
  def handle_info(:process_batch, %{daily_queue: []} = state) do
    Logger.info("Daily queue exhausted, advancing to next day",
      date: state.current_date
    )

    # Move to next day
    Process.send_after(self(), :advance_date, 100)

    {:noreply, %{state | batch_timer: nil}}
  end

  @impl true
  def handle_info(:process_batch, state) do
    # Take next batch
    {batch, remaining} = Enum.split(state.daily_queue, state.config.batch_size)

    Logger.debug("Processing historical batch",
      size: length(batch),
      remaining: length(remaining)
    )

    # Process batch asynchronously
    SupervisedTask.start_child(
      fn -> process_kill_batch(batch) end,
      task_name: "process_historical_batch",
      metadata: %{
        date: state.current_date,
        batch_size: length(batch)
      }
    )

    # Schedule next batch
    timer = schedule_next_batch(state.config.batch_interval_ms)

    {:noreply, %{state | daily_queue: remaining, batch_timer: timer}}
  end

  @impl true
  def handle_info({:batch_result, {:ok, results}}, state) do
    success_count = Enum.count(results, &match?({:ok, _}, &1))
    fail_count = Enum.count(results, &match?({:error, _}, &1))

    emit_telemetry(
      :batch_processed,
      %{
        success_count: success_count,
        fail_count: fail_count
      },
      state
    )

    {:noreply,
     %{
       state
       | processed_count: state.processed_count + success_count,
         failed_count: state.failed_count + fail_count
     }}
  end

  @impl true
  def handle_info(:advance_date, state) do
    next_date = Date.add(state.current_date, 1)

    Logger.info("Advancing to next date",
      from: state.current_date,
      to: next_date
    )

    # Start fetching next day
    Process.send_after(self(), :start_daily_fetch, 100)

    # Reset retry count when advancing to a new date
    {:noreply, %{state | current_date: next_date, retry_count: 0}}
  end

  # Private functions

  defp get_config do
    base_config = Application.get_env(:wanderer_kills, :historical_streaming, %{})

    %{
      enabled: Map.get(base_config, :enabled, false),
      start_date: Map.get(base_config, :start_date, "20240101"),
      daily_limit: Map.get(base_config, :daily_limit, 5000),
      batch_size: Map.get(base_config, :batch_size, 50),
      batch_interval_ms: Map.get(base_config, :batch_interval_ms, 10_000),
      max_retries: Map.get(base_config, :max_retries, 3),
      retry_delay_ms: Map.get(base_config, :retry_delay_ms, 5_000)
    }
  end

  defp parse_date(date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} ->
        date

      {:error, _} ->
        # Try YYYYMMDD format
        with <<year::binary-4, month::binary-2, day::binary-2>> <- date_string,
             {year, ""} <- Integer.parse(year),
             {month, ""} <- Integer.parse(month),
             {day, ""} <- Integer.parse(day),
             {:ok, date} <- Date.new(year, month, day) do
          date
        else
          _ ->
            Logger.error("Invalid date format for historical streaming",
              date_string: date_string,
              expected_format: "YYYYMMDD or YYYY-MM-DD"
            )

            raise ArgumentError,
                  "Invalid date format: #{date_string}. Expected YYYYMMDD or YYYY-MM-DD"
        end
    end
  end

  defp parse_date(_invalid_input) do
    raise ArgumentError, "Date must be a string in YYYYMMDD or YYYY-MM-DD format"
  end

  defp fetch_daily_kills(date, parent_pid) do
    date_string = format_date_for_api(date)

    zkb_client = Application.get_env(:wanderer_kills, :zkb_client, ZkbClient)

    case zkb_client.fetch_history(date_string) do
      {:ok, kill_map} ->
        # Convert map to list of {id, hash} tuples
        kill_list =
          kill_map
          |> Enum.map(fn {id_str, hash} ->
            {String.to_integer(id_str), hash}
          end)
          |> Enum.sort_by(&elem(&1, 0))

        send(parent_pid, {:task_result, {:ok, kill_list}})

      {:error, reason} ->
        send(parent_pid, {:task_result, {:error, reason}})
    end
  end

  defp format_date_for_api(date) do
    date
    |> Date.to_string()
    |> String.replace("-", "")
  end

  defp process_kill_batch(batch) do
    results =
      batch
      |> Enum.map(fn {killmail_id, hash} ->
        process_single_kill(killmail_id, hash)
      end)

    send(self(), {:batch_result, {:ok, results}})
  end

  defp process_single_kill(killmail_id, hash, retry_count \\ 0) do
    max_retries = 3

    # Use RateLimiter to check rate limits
    case SmartRateLimiter.check_rate_limit(:zkillboard) do
      :ok ->
        # Build minimal zkb data structure needed by the pipeline
        zkb_data = %{"hash" => hash}

        killmail_data = %{
          "killmail_id" => killmail_id,
          "zkb" => zkb_data
        }

        # Process through unified pipeline - this will fetch full data from ESI
        # Use a very old cutoff time so historical kills are always processed
        cutoff_time = DateTime.add(DateTime.utc_now(), -365 * 24 * 60 * 60, :second)

        case UnifiedProcessor.process_killmail(killmail_data, cutoff_time, []) do
          {:ok, _processed} ->
            {:ok, killmail_id}

          {:error, reason} when retry_count < max_retries ->
            Logger.warning("Failed to process historical kill, retrying",
              killmail_id: killmail_id,
              error: reason,
              retry_count: retry_count + 1,
              max_retries: max_retries
            )

            # Small delay before retry
            Process.sleep(100 * (retry_count + 1))
            process_single_kill(killmail_id, hash, retry_count + 1)

          {:error, reason} ->
            Logger.warning("Failed to process historical kill after all retries",
              killmail_id: killmail_id,
              error: reason,
              retries_exhausted: max_retries
            )

            {:error, reason}
        end

      {:error, _reason} when retry_count < max_retries ->
        # Rate limit hit, retry after delay
        Logger.debug("Rate limit hit for historical kill, retrying",
          killmail_id: killmail_id,
          retry_count: retry_count + 1
        )

        Process.sleep(200 * (retry_count + 1))
        process_single_kill(killmail_id, hash, retry_count + 1)

      {:error, reason} ->
        # Return error after exhausting retries
        {:error, reason}
    end
  end

  defp schedule_next_batch(delay) do
    Process.send_after(self(), :process_batch, delay)
  end

  defp calculate_progress(state) do
    total_days = Date.diff(state.end_date, state.start_date)
    elapsed_days = Date.diff(state.current_date, state.start_date)

    if total_days > 0 do
      Float.round(elapsed_days / total_days * 100, 2)
    else
      100.0
    end
  end

  defp emit_telemetry(event, measurements, state) do
    :telemetry.execute(
      @telemetry_prefix ++ [event],
      measurements,
      %{
        current_date: state.current_date,
        paused: state.paused
      }
    )
  end
end
