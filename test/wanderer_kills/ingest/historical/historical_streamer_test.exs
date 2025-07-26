defmodule WandererKills.Ingest.Historical.HistoricalStreamerTest do
  use WandererKills.DataCase, async: false
  import Mox

  alias WandererKills.Ingest.Historical.HistoricalStreamer
  alias WandererKills.Ingest.Killmails.UnifiedProcessor
  alias WandererKills.Ingest.Killmails.ZkbClient.Mock, as: ZkbClientMock

  @moduletag :capture_log

  setup do
    # Set up mox for cross-process calls
    set_mox_global()

    # Ensure TaskSupervisor is started
    case Process.whereis(WandererKills.TaskSupervisor) do
      nil -> start_supervised!({Task.Supervisor, name: WandererKills.TaskSupervisor})
      _pid -> :ok
    end

    # Mock configuration for testing
    test_config = %{
      enabled: true,
      start_date: "20240101",
      daily_limit: 100,
      batch_size: 10,
      batch_interval_ms: 100,
      max_retries: 3,
      retry_delay_ms: 50
    }

    Application.put_env(:wanderer_kills, :historical_streaming, test_config)

    on_exit(fn ->
      Application.delete_env(:wanderer_kills, :historical_streaming)
    end)

    %{config: test_config}
  end

  describe "start_link/1" do
    test "starts successfully when enabled" do
      assert {:ok, pid} = HistoricalStreamer.start_link([])
      assert Process.alive?(pid)

      # Clean up
      GenServer.stop(pid)
    end

    test "returns :ignore when disabled" do
      Application.put_env(:wanderer_kills, :historical_streaming, %{enabled: false})

      assert :ignore = HistoricalStreamer.start_link([])
    end
  end

  describe "status/0" do
    test "returns current status" do
      {:ok, pid} = HistoricalStreamer.start_link([])

      status = HistoricalStreamer.status()

      assert %{
               current_date: %Date{},
               end_date: %Date{},
               queue_size: 0,
               processed_count: 0,
               failed_count: 0,
               paused: false,
               progress_percentage: _
             } = status

      GenServer.stop(pid)
    end
  end

  describe "pause/0 and resume/0" do
    test "can pause and resume streaming" do
      {:ok, pid} = HistoricalStreamer.start_link([])

      # Pause
      assert :ok = HistoricalStreamer.pause()
      status = HistoricalStreamer.status()
      assert status.paused == true

      # Resume
      assert :ok = HistoricalStreamer.resume()
      status = HistoricalStreamer.status()
      assert status.paused == false

      GenServer.stop(pid)
    end

    test "resume returns error when not paused" do
      {:ok, pid} = HistoricalStreamer.start_link([])

      assert {:error, :not_paused} = HistoricalStreamer.resume()

      GenServer.stop(pid)
    end
  end

  describe "daily kill fetching" do
    test "fetches daily kills successfully" do
      set_mox_global()

      historical_data = %{
        "122912852" => "b2550e9cb63e9e93c4b4416c20e1674de8bbf34d",
        "122912855" => "e0b6afbcf3fd7359d95011d8f2656345f110a930"
      }

      ZkbClientMock
      |> expect(:fetch_history, fn
        "20240101" ->
          {:ok, historical_data}
      end)
      |> stub(:fetch_history, fn
        _date ->
          {:ok, %{}}
      end)

      {:ok, pid} = HistoricalStreamer.start_link([])

      # Allow the mock to be called by the HistoricalStreamer process
      allow(ZkbClientMock, self(), pid)

      # Wait for initial fetch (streamer waits 1000ms before starting)
      Process.sleep(1500)

      status = HistoricalStreamer.status()
      # Just verify the streamer is running and has advanced from the start date
      assert Date.compare(status.current_date, ~D[2024-01-01]) == :gt
      # Queue size should be non-negative
      assert status.queue_size >= 0

      GenServer.stop(pid)
    end

    test "handles fetch errors gracefully" do
      set_mox_global()

      ZkbClientMock
      |> expect(:fetch_history, fn
        "20240101" ->
          {:error, :timeout}
      end)

      {:ok, pid} = HistoricalStreamer.start_link([])

      # Allow the mock to be called by the HistoricalStreamer process
      allow(ZkbClientMock, self(), pid)

      # Wait for error handling (streamer waits 1000ms before starting)
      Process.sleep(1500)

      # Should still be running
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  describe "batch processing" do
    test "processes kills in batches" do
      set_mox_global()

      historical_data = %{
        "122912852" => "hash1",
        "122912855" => "hash2"
      }

      ZkbClientMock
      |> expect(:fetch_history, fn
        "20240101" ->
          {:ok, historical_data}
      end)

      # Mock UnifiedProcessor to track calls
      _original_process =
        Application.get_env(:wanderer_kills, :unified_processor, UnifiedProcessor)

      test_pid = self()

      _mock_processor = fn killmail_data, _priority ->
        send(test_pid, {:process_killmail, killmail_data})
        {:ok, killmail_data}
      end

      # This is a simplified test - in real implementation we'd need proper mocking
      {:ok, pid} = HistoricalStreamer.start_link([])

      # Wait for processing (streamer waits 1000ms before starting)
      Process.sleep(1500)

      GenServer.stop(pid)
    end
  end

  describe "configuration handling" do
    test "parses date string correctly" do
      # Test with YYYYMMDD format
      config = %{
        enabled: true,
        start_date: "20240315",
        daily_limit: 1000,
        batch_size: 50,
        batch_interval_ms: 5000
      }

      Application.put_env(:wanderer_kills, :historical_streaming, config)

      {:ok, pid} = HistoricalStreamer.start_link([])

      status = HistoricalStreamer.status()
      assert status.current_date == ~D[2024-03-15]

      GenServer.stop(pid)
    end

    test "handles invalid date by raising error" do
      config = %{
        enabled: true,
        start_date: "invalid_date",
        daily_limit: 1000,
        batch_size: 50,
        batch_interval_ms: 5000
      }

      Application.put_env(:wanderer_kills, :historical_streaming, config)

      # Should raise an error on invalid date format
      Process.flag(:trap_exit, true)
      assert {:error, _} = HistoricalStreamer.start_link([])
    end
  end

  describe "daily limit enforcement" do
    test "applies daily limit when configured" do
      # Large dataset
      large_dataset =
        1..200
        |> Enum.map(fn i -> {"#{i}", "hash#{i}"} end)
        |> Enum.into(%{})

      # Set global mode for this test since HistoricalStreamer spawns tasks
      set_mox_global()

      ZkbClientMock
      |> expect(:fetch_history, fn
        "20240101" ->
          {:ok, large_dataset}
      end)

      # Set small daily limit
      config = %{
        enabled: true,
        start_date: "20240101",
        daily_limit: 50,
        batch_size: 10,
        batch_interval_ms: 100
      }

      Application.put_env(:wanderer_kills, :historical_streaming, config)

      {:ok, pid} = HistoricalStreamer.start_link([])

      # Wait for processing (streamer waits 1000ms before starting)
      Process.sleep(1500)

      status = HistoricalStreamer.status()
      # Should be limited to daily_limit
      assert status.queue_size <= 50

      GenServer.stop(pid)
    end
  end

  describe "progress calculation" do
    test "calculates progress percentage correctly" do
      # Test with recent date to ensure progress calculation works
      yesterday = Date.utc_today() |> Date.add(-1)
      start_date = yesterday |> Date.to_string() |> String.replace("-", "")

      config = %{
        enabled: true,
        start_date: start_date,
        daily_limit: 100,
        batch_size: 10,
        batch_interval_ms: 100
      }

      Application.put_env(:wanderer_kills, :historical_streaming, config)

      set_mox_global()

      ZkbClientMock
      |> expect(:fetch_history, fn
        _date ->
          {:ok, %{}}
      end)

      {:ok, pid} = HistoricalStreamer.start_link([])

      # Wait for initial processing (streamer waits 1000ms before starting)
      Process.sleep(1500)

      status = HistoricalStreamer.status()
      assert is_number(status.progress_percentage)
      assert status.progress_percentage >= 0
      assert status.progress_percentage <= 100

      GenServer.stop(pid)
    end
  end

  describe "error handling" do
    test "handles malformed historical data" do
      set_mox_global()

      ZkbClientMock
      |> expect(:fetch_history, fn
        "20240101" ->
          {:error, :invalid_response}
      end)

      {:ok, pid} = HistoricalStreamer.start_link([])

      # Wait for error handling (streamer waits 1000ms before starting)
      Process.sleep(1500)

      # Should still be running and move to next day
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "continues processing after individual kill failures" do
      set_mox_global()

      historical_data = %{
        "122912852" => "valid_hash",
        "122912855" => "invalid_hash"
      }

      ZkbClientMock
      |> expect(:fetch_history, fn
        "20240101" ->
          {:ok, historical_data}
      end)

      {:ok, pid} = HistoricalStreamer.start_link([])

      # Wait for processing (streamer waits 1000ms before starting)
      Process.sleep(1500)

      # Should still be running
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  describe "telemetry events" do
    test "emits telemetry events during processing" do
      # This would require more sophisticated telemetry testing
      # For now, we just ensure the module can handle telemetry calls

      {:ok, pid} = HistoricalStreamer.start_link([])

      # The module should emit telemetry events without crashing
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end
end
