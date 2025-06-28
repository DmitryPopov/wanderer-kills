defmodule WandererKills.Core.Observability.TelemetryMetrics do
  @moduledoc """
  Aggregates telemetry events into metrics for status reporting.

  This GenServer subscribes to telemetry events and maintains counters
  that can be queried by the unified status reporter.
  """

  use GenServer
  require Logger

  @table :telemetry_metrics

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get current metric values.
  """
  def get_metrics do
    case :ets.info(@table) do
      :undefined ->
        %{}

      _ ->
        :ets.tab2list(@table)
        |> Enum.into(%{})
    end
  end

  @doc """
  Get a specific metric value.
  """
  def get_metric(key, default \\ 0) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end

  @doc """
  Reset all metrics to zero.
  """
  def reset_metrics do
    GenServer.call(__MODULE__, :reset_metrics)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for metrics
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

    # Initialize counters
    init_counters()

    # Attach telemetry handlers
    attach_handlers()

    Logger.info("[TelemetryMetrics] Started telemetry metrics aggregator")

    {:ok, %{}}
  end

  @impl true
  def handle_call(:reset_metrics, _from, state) do
    init_counters()
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    detach_handlers()
    :ok
  end

  # Private functions

  defp init_counters do
    # Task metrics
    :ets.insert(@table, {:tasks_started, 0})
    :ets.insert(@table, {:tasks_completed, 0})
    :ets.insert(@table, {:tasks_failed, 0})

    # Preload-specific task metrics
    :ets.insert(@table, {:preload_tasks_started, 0})
    :ets.insert(@table, {:preload_tasks_completed, 0})
    :ets.insert(@table, {:preload_tasks_failed, 0})

    # Webhook metrics
    :ets.insert(@table, {:webhook_tasks_started, 0})
    :ets.insert(@table, {:webhook_tasks_completed, 0})
    :ets.insert(@table, {:webhook_tasks_failed, 0})
    :ets.insert(@table, {:webhooks_sent, 0})
    :ets.insert(@table, {:webhooks_failed, 0})

    # Broadcast metrics
    :ets.insert(@table, {:broadcast_tasks_started, 0})
    :ets.insert(@table, {:broadcast_tasks_completed, 0})
    :ets.insert(@table, {:broadcast_tasks_failed, 0})

    # Maintenance metrics
    :ets.insert(@table, {:maintenance_tasks_started, 0})
    :ets.insert(@table, {:maintenance_tasks_completed, 0})
    :ets.insert(@table, {:maintenance_tasks_failed, 0})

    # Preload delivery metrics
    :ets.insert(@table, {:kills_delivered, 0})

    # SSE metrics
    :ets.insert(
      @table,
      {:sse,
       %{
         killmail_events: 0,
         heartbeat_events: 0,
         error_events: 0,
         connected_events: 0,
         batch_events: 0
       }}
    )
  end

  defp attach_handlers do
    :telemetry.attach_many(
      "telemetry-metrics-task-handler",
      [
        [:wanderer_kills, :task, :start],
        [:wanderer_kills, :task, :stop],
        [:wanderer_kills, :task, :error]
      ],
      &__MODULE__.handle_task_event/4,
      nil
    )

    :telemetry.attach(
      "telemetry-metrics-preload-handler",
      [:wanderer_kills, :preload, :kills_delivered],
      &__MODULE__.handle_preload_event/4,
      nil
    )

    :telemetry.attach(
      "telemetry-metrics-sse-handler",
      [:wanderer_kills, :sse, :event, :sent],
      &__MODULE__.handle_sse_event/4,
      nil
    )
  end

  defp detach_handlers do
    :telemetry.detach("telemetry-metrics-task-handler")
    :telemetry.detach("telemetry-metrics-preload-handler")
    :telemetry.detach("telemetry-metrics-sse-handler")
  end

  @doc false
  def handle_task_event([:wanderer_kills, :task, :start], _measurements, metadata, _config) do
    increment_counter(:tasks_started)
    track_task_start(metadata[:task_name])
  end

  @doc false
  def handle_task_event([:wanderer_kills, :task, :stop], _measurements, metadata, _config) do
    increment_counter(:tasks_completed)
    track_task_completion(metadata[:task_name])
  end

  @doc false
  def handle_task_event([:wanderer_kills, :task, :error], _measurements, metadata, _config) do
    increment_counter(:tasks_failed)
    track_task_failure(metadata[:task_name])
  end

  @doc false
  def handle_preload_event(
        [:wanderer_kills, :preload, :kills_delivered],
        measurements,
        _metadata,
        _config
      ) do
    count = Map.get(measurements, :count, 0)
    :ets.update_counter(@table, :kills_delivered, count, {:kills_delivered, 0})
  end

  @doc false
  def handle_sse_event(
        [:wanderer_kills, :sse, :event, :sent],
        _measurements,
        metadata,
        _config
      ) do
    event_type = Map.get(metadata, :event_type, "unknown")

    case :ets.lookup(@table, :sse) do
      [{:sse, current_metrics}] ->
        updated_metrics = update_sse_event_counter(current_metrics, event_type)
        :ets.insert(@table, {:sse, updated_metrics})

      [] ->
        initial_metrics = initialize_sse_metrics(event_type)
        :ets.insert(@table, {:sse, initial_metrics})
    end
  end

  defp update_sse_event_counter(current_metrics, event_type) do
    case event_type do
      "killmail" -> Map.update(current_metrics, :killmail_events, 1, &(&1 + 1))
      "heartbeat" -> Map.update(current_metrics, :heartbeat_events, 1, &(&1 + 1))
      "error" -> Map.update(current_metrics, :error_events, 1, &(&1 + 1))
      "connected" -> Map.update(current_metrics, :connected_events, 1, &(&1 + 1))
      "batch" -> Map.update(current_metrics, :batch_events, 1, &(&1 + 1))
      _ -> current_metrics
    end
  end

  defp initialize_sse_metrics(event_type) do
    %{
      killmail_events: if(event_type == "killmail", do: 1, else: 0),
      heartbeat_events: if(event_type == "heartbeat", do: 1, else: 0),
      error_events: if(event_type == "error", do: 1, else: 0),
      connected_events: if(event_type == "connected", do: 1, else: 0),
      batch_events: if(event_type == "batch", do: 1, else: 0)
    }
  end

  defp increment_counter(key) do
    :ets.update_counter(@table, key, 1, {key, 0})
  end

  defp track_task_start(task_name) do
    task_type = get_task_type(task_name)

    case task_type do
      :preload -> increment_counter(:preload_tasks_started)
      :webhook -> increment_counter(:webhook_tasks_started)
      :broadcast -> increment_counter(:broadcast_tasks_started)
      :maintenance -> increment_counter(:maintenance_tasks_started)
      _ -> :ok
    end
  end

  defp track_task_completion(task_name) do
    task_type = get_task_type(task_name)

    case task_type do
      :preload ->
        increment_counter(:preload_tasks_completed)

      :webhook ->
        increment_counter(:webhook_tasks_completed)
        increment_counter(:webhooks_sent)

      :broadcast ->
        increment_counter(:broadcast_tasks_completed)

      :maintenance ->
        increment_counter(:maintenance_tasks_completed)

      _ ->
        Logger.info("[TelemetryMetrics] Unknown task type: #{inspect(task_name)}")
    end
  end

  defp track_task_failure(task_name) do
    task_type = get_task_type(task_name)

    case task_type do
      :preload ->
        increment_counter(:preload_tasks_failed)

      :webhook ->
        increment_counter(:webhook_tasks_failed)
        increment_counter(:webhooks_failed)

      :broadcast ->
        increment_counter(:broadcast_tasks_failed)

      :maintenance ->
        increment_counter(:maintenance_tasks_failed)

      _ ->
        :ok
    end
  end

  defp get_task_type(task_name) do
    cond do
      task_name in ["subscription_preload", "websocket_preload"] ->
        :preload

      task_name in [
        "webhook_notification",
        "send_webhook_notifications",
        "send_webhook_count_notifications"
      ] ->
        :webhook

      task_name in ["broadcast_killmail_update", "broadcast_killmail_count"] ->
        :broadcast

      task_name == "ship_type_update" ->
        :maintenance

      true ->
        :unknown
    end
  end
end
