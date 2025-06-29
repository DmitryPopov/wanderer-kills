defmodule WandererKills.SSE.EventFormatterTest do
  use ExUnit.Case, async: true

  alias WandererKills.SSE.EventFormatter

  describe "format_event/2" do
    test "formats event with correct structure" do
      result = EventFormatter.format_event(:test, %{message: "hello"})

      assert %{event: "test", data: data} = result
      assert {:ok, %{"message" => "hello"}} = Jason.decode(data)
    end
  end

  describe "connected_event/1" do
    test "creates connected event with filters" do
      filters = %{character_ids: [123], system_ids: [], min_value: nil, preload_days: 0}
      result = EventFormatter.connected_event(filters)

      assert %{event: "connected", data: data} = result

      {:ok, decoded} = Jason.decode(data)
      assert decoded["status"] == "connected"
      assert decoded["filters"]["character_ids"] == filters.character_ids
      assert decoded["filters"]["system_ids"] == filters.system_ids
      assert decoded["filters"]["min_value"] == filters.min_value
      assert decoded["filters"]["preload_days"] == filters.preload_days
      assert decoded["timestamp"] != nil
    end
  end

  describe "batch_event/2" do
    test "creates batch event with killmails" do
      kills = [%{"killmail_id" => 1}, %{"killmail_id" => 2}]
      batch_info = %{number: 1, total: 3}

      result = EventFormatter.batch_event(kills, batch_info)

      assert %{event: "batch", data: data} = result

      {:ok, decoded} = Jason.decode(data)
      assert decoded["kills"] == kills
      assert decoded["count"] == 2
      assert decoded["batch_number"] == 1
      assert decoded["total_batches"] == 3
    end
  end

  describe "transition_event/1" do
    test "creates transition event" do
      result = EventFormatter.transition_event(150)

      assert %{event: "transition", data: data} = result

      {:ok, decoded} = Jason.decode(data)
      assert decoded["status"] == "historical_complete"
      assert decoded["total_historical"] == 150
      assert decoded["timestamp"] != nil
    end
  end

  describe "heartbeat_event/1" do
    test "creates heartbeat event with mode" do
      result = EventFormatter.heartbeat_event(:realtime)

      assert %{event: "heartbeat", data: data} = result

      {:ok, decoded} = Jason.decode(data)
      assert decoded["mode"] == "realtime"
      assert decoded["timestamp"] != nil
    end
  end

  describe "error_event/2" do
    test "creates error event" do
      result = EventFormatter.error_event(:connection_failed, "Unable to connect")

      assert %{event: "error", data: data} = result

      {:ok, decoded} = Jason.decode(data)
      assert decoded["type"] == "connection_failed"
      assert decoded["message"] == "Unable to connect"
      assert decoded["timestamp"] != nil
    end
  end

  describe "killmail_event/1" do
    test "creates killmail event" do
      killmail = %{"killmail_id" => 12_345, "system_id" => 30_000_142}
      result = EventFormatter.killmail_event(killmail)

      assert %{event: "killmail", data: data} = result

      {:ok, decoded} = Jason.decode(data)
      assert decoded == killmail
    end
  end
end
