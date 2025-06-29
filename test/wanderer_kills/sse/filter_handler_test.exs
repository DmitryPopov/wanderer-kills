defmodule WandererKills.SSE.FilterHandlerTest do
  use ExUnit.Case, async: true

  alias WandererKills.SSE.FilterHandler

  describe "should_send_killmail?/2" do
    setup do
      {:ok,
       killmail: %{
         "killmail_id" => 12_345,
         "solar_system_id" => 30_000_142,
         "victim" => %{"character_id" => 100},
         "attackers" => [
           %{"character_id" => 200},
           %{"character_id" => 300}
         ],
         "zkb" => %{"totalValue" => 150_000_000}
       }}
    end

    test "returns true when no filters are specified", %{killmail: killmail} do
      filters = %{character_ids: [], system_ids: [], min_value: nil}
      assert FilterHandler.should_send_killmail?(killmail, filters)
    end

    test "filters by character_ids - victim match", %{killmail: killmail} do
      filters = %{character_ids: [100], system_ids: [], min_value: nil}
      assert FilterHandler.should_send_killmail?(killmail, filters)
    end

    test "filters by character_ids - attacker match", %{killmail: killmail} do
      filters = %{character_ids: [300], system_ids: [], min_value: nil}
      assert FilterHandler.should_send_killmail?(killmail, filters)
    end

    test "filters by character_ids - no match", %{killmail: killmail} do
      filters = %{character_ids: [999], system_ids: [], min_value: nil}
      refute FilterHandler.should_send_killmail?(killmail, filters)
    end

    test "filters by system_ids - match", %{killmail: killmail} do
      filters = %{character_ids: [], system_ids: [30_000_142], min_value: nil}
      assert FilterHandler.should_send_killmail?(killmail, filters)
    end

    test "filters by system_ids - no match", %{killmail: killmail} do
      filters = %{character_ids: [], system_ids: [30_000_143], min_value: nil}
      refute FilterHandler.should_send_killmail?(killmail, filters)
    end

    test "filters by min_value - above threshold", %{killmail: killmail} do
      filters = %{character_ids: [], system_ids: [], min_value: 100_000_000}
      assert FilterHandler.should_send_killmail?(killmail, filters)
    end

    test "filters by min_value - below threshold", %{killmail: killmail} do
      filters = %{character_ids: [], system_ids: [], min_value: 200_000_000}
      refute FilterHandler.should_send_killmail?(killmail, filters)
    end

    test "combines character and value filters", %{killmail: killmail} do
      # Should pass if character matches AND value is above threshold
      filters = %{character_ids: [100], system_ids: [], min_value: 100_000_000}
      assert FilterHandler.should_send_killmail?(killmail, filters)

      # Should fail if character matches but value is below threshold
      filters = %{character_ids: [100], system_ids: [], min_value: 200_000_000}
      refute FilterHandler.should_send_killmail?(killmail, filters)
    end

    test "character OR system filters work correctly", %{killmail: killmail} do
      # Should pass if either character OR system matches
      filters = %{character_ids: [999], system_ids: [30_000_142], min_value: nil}
      assert FilterHandler.should_send_killmail?(killmail, filters)

      filters = %{character_ids: [100], system_ids: [30_000_999], min_value: nil}
      assert FilterHandler.should_send_killmail?(killmail, filters)
    end

    test "handles killmails with nil victim character", %{killmail: killmail} do
      killmail = put_in(killmail["victim"]["character_id"], nil)
      filters = %{character_ids: [200], system_ids: [], min_value: nil}

      # Should still match on attacker
      assert FilterHandler.should_send_killmail?(killmail, filters)
    end

    test "handles killmails with no zkb data", %{killmail: killmail} do
      killmail = Map.delete(killmail, "zkb")
      filters = %{character_ids: [], system_ids: [], min_value: 100_000_000}

      # Should not match when min_value is set but zkb data is missing
      refute FilterHandler.should_send_killmail?(killmail, filters)
    end

    test "handles alternative field names", %{killmail: killmail} do
      # Test system_id instead of solar_system_id
      killmail =
        killmail
        |> Map.delete("solar_system_id")
        |> Map.put("system_id", 30_000_142)

      filters = %{character_ids: [], system_ids: [30_000_142], min_value: nil}
      assert FilterHandler.should_send_killmail?(killmail, filters)

      # Test total_value instead of totalValue
      killmail = put_in(killmail, ["zkb", "total_value"], 150_000_000)
      killmail = update_in(killmail, ["zkb"], &Map.delete(&1, "totalValue"))

      filters = %{character_ids: [], system_ids: [], min_value: 100_000_000}
      assert FilterHandler.should_send_killmail?(killmail, filters)
    end
  end
end
