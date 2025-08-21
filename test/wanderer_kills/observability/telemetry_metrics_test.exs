defmodule WandererKills.Core.Observability.TelemetryMetricsTest do
  use ExUnit.Case, async: false

  alias WandererKills.Core.Observability.Telemetry

  setup do
    # Start the telemetry metrics system if not already started
    case Process.whereis(WandererKills.Core.Observability.Telemetry) do
      nil ->
        {:ok, _pid} = Telemetry.start_link()

      _pid ->
        # Already started, just attach handlers
        Telemetry.attach_task_handlers()
    end

    # Ensure clean state
    Telemetry.reset_metrics_with_tasks()

    on_exit(fn ->
      # Reset metrics after each test to prevent state leakage
      Telemetry.reset_metrics_with_tasks()
    end)

    :ok
  end

  describe "task event tracking" do
    test "tracks task start events" do
      # Emit a task start event
      :telemetry.execute(
        [:wanderer_kills, :task, :start],
        %{system_time: System.system_time()},
        %{task_name: "test_task"}
      )

      # Give time for async cast to process
      Process.sleep(10)

      metrics = Telemetry.get_metrics()
      assert metrics[:tasks_started] == 1
    end

    test "tracks task completion events" do
      # Emit a task stop event
      :telemetry.execute(
        [:wanderer_kills, :task, :stop],
        %{duration: 1000},
        %{task_name: "test_task"}
      )

      # Give time for async cast to process
      Process.sleep(10)

      metrics = Telemetry.get_metrics()
      assert metrics[:tasks_completed] == 1
    end

    test "tracks task error events" do
      # Emit a task error event
      :telemetry.execute(
        [:wanderer_kills, :task, :error],
        %{duration: 1000},
        %{task_name: "test_task", error: "Test error"}
      )

      # Give time for async cast to process
      Process.sleep(10)

      metrics = Telemetry.get_metrics()
      assert metrics[:tasks_failed] == 1
    end
  end

  describe "preload task tracking" do
    test "tracks preload task events" do
      # Start a preload task
      :telemetry.execute(
        [:wanderer_kills, :task, :start],
        %{system_time: System.system_time()},
        %{task_name: "subscription_preload"}
      )

      # Complete it
      :telemetry.execute(
        [:wanderer_kills, :task, :stop],
        %{duration: 1000},
        %{task_name: "subscription_preload"}
      )

      # Give time for async cast to process
      Process.sleep(10)

      metrics = Telemetry.get_metrics()
      assert metrics[:preload_tasks_started] == 1
      assert metrics[:preload_tasks_completed] == 1
      assert metrics[:preload_tasks_failed] == 0
    end

    test "tracks failed preload tasks" do
      # Start and fail a preload task
      :telemetry.execute(
        [:wanderer_kills, :task, :start],
        %{system_time: System.system_time()},
        %{task_name: "subscription_preload"}
      )

      :telemetry.execute(
        [:wanderer_kills, :task, :error],
        %{duration: 1000},
        %{task_name: "subscription_preload", error: "Test error"}
      )

      # Give time for async cast to process
      Process.sleep(10)

      metrics = Telemetry.get_metrics()
      assert metrics[:preload_tasks_started] == 1
      assert metrics[:preload_tasks_failed] == 1
    end
  end

  describe "webhook task tracking" do
    test "tracks webhook notification tasks" do
      # Track webhook notification
      :telemetry.execute(
        [:wanderer_kills, :task, :start],
        %{system_time: System.system_time()},
        %{task_name: "webhook_notification"}
      )

      :telemetry.execute(
        [:wanderer_kills, :task, :stop],
        %{duration: 1000},
        %{task_name: "webhook_notification"}
      )

      # Give time for async cast to process
      Process.sleep(10)

      metrics = Telemetry.get_metrics()
      assert metrics[:webhook_tasks_started] == 1
      assert metrics[:webhook_tasks_completed] == 1
      assert metrics[:webhooks_sent] == 1
    end

    test "tracks failed webhook tasks" do
      # Track failed webhook
      :telemetry.execute(
        [:wanderer_kills, :task, :start],
        %{system_time: System.system_time()},
        %{task_name: "send_webhook_notifications"}
      )

      :telemetry.execute(
        [:wanderer_kills, :task, :error],
        %{duration: 1000},
        %{task_name: "send_webhook_notifications", error: "Test error"}
      )

      # Give time for async cast to process
      Process.sleep(10)

      metrics = Telemetry.get_metrics()
      assert metrics[:webhook_tasks_failed] == 1
      assert metrics[:webhooks_failed] == 1
    end
  end

  describe "metric retrieval" do
    test "get_metric returns default value for missing keys" do
      assert Telemetry.get_metric(:nonexistent) == 0
      assert Telemetry.get_metric(:nonexistent, 42) == 42
    end

    test "get_metrics returns all metrics" do
      # Emit some events
      :telemetry.execute(
        [:wanderer_kills, :task, :start],
        %{system_time: System.system_time()},
        %{task_name: "test"}
      )

      # Give time for async cast to process
      Process.sleep(10)

      metrics = Telemetry.get_metrics()
      assert is_map(metrics)
      assert Map.has_key?(metrics, :tasks_started)
      assert metrics[:tasks_started] == 1
    end
  end

  describe "reset functionality" do
    test "reset_metrics clears all counters" do
      # Add some data
      :telemetry.execute(
        [:wanderer_kills, :task, :start],
        %{system_time: System.system_time()},
        %{task_name: "test"}
      )

      # Give time for async cast to process
      Process.sleep(10)

      metrics = Telemetry.get_metrics()
      assert metrics[:tasks_started] == 1

      # Reset with task initialization
      Telemetry.reset_metrics_with_tasks()

      # Give time for async cast to process
      Process.sleep(10)

      # Check all counters are back to 0
      metrics = Telemetry.get_metrics()
      assert metrics[:tasks_started] == 0
      assert metrics[:tasks_completed] == 0
      assert metrics[:tasks_failed] == 0
    end
  end
end
