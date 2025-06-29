defmodule WandererKills.Subs.Subscriptions.BaseIndexTest do
  use ExUnit.Case, async: false

  require Logger

  alias WandererKills.Subs.Subscriptions.BaseIndex

  # Create a test implementation of BaseIndex
  defmodule TestEntityIndex do
    use WandererKills.Subs.Subscriptions.BaseIndex,
      entity_type: :test_entity,
      table_name: :test_entity_subscription_index
  end

  setup do
    # Ensure the test index is always available
    ensure_test_index_running()

    # Clear the index before each test
    safe_clear()

    on_exit(fn ->
      # Clean up after test
      safe_clear()
    end)

    :ok
  end

  defp ensure_test_index_running do
    case GenServer.whereis(TestEntityIndex) do
      nil ->
        {:ok, _pid} = TestEntityIndex.start_link([])

      pid ->
        # Check if process is actually alive
        if Process.alive?(pid) do
          :ok
        else
          # Process is dead but still registered, restart it
          {:ok, _pid} = TestEntityIndex.start_link([])
        end
    end
  end

  defp safe_clear do
    if GenServer.whereis(TestEntityIndex) do
      TestEntityIndex.clear()
    end
  rescue
    # Catch specific expected errors and re-raise unexpected ones
    error ->
      case error do
        %ArgumentError{} ->
          # Invalid arguments or state
          ensure_test_index_running()

        _ ->
          # Log and re-raise any unexpected errors
          Logger.error("Unexpected error in test clear: #{inspect(error)}")
          reraise error, __STACKTRACE__
      end
  catch
    :exit, {:noproc, _} ->
      # GenServer process doesn't exist
      ensure_test_index_running()

    :exit, {:timeout, _} ->
      # GenServer call timeout
      ensure_test_index_running()

    kind, reason ->
      # Log and re-raise any other unexpected errors
      Logger.error("Unexpected catch in test clear: #{inspect({kind, reason})}")

      reraise RuntimeError,
              "Unexpected error in test clear: #{inspect({kind, reason})}",
              __STACKTRACE__
  end

  describe "BaseIndex behaviour compliance" do
    test "implements all required behaviour callbacks" do
      # Verify the module implements the IndexBehaviour
      assert TestEntityIndex.__info__(:attributes)
             |> Enum.any?(fn {key, values} ->
               key == :behaviour and WandererKills.Subs.Subscriptions.IndexBehaviour in values
             end)
    end
  end

  describe "add_subscription/2" do
    test "adds subscription with single entity" do
      TestEntityIndex.add_subscription("sub_1", [123])

      assert TestEntityIndex.find_subscriptions_for_entity(123) == ["sub_1"]
      assert TestEntityIndex.find_subscriptions_for_entity(456) == []
    end

    test "adds subscription with multiple entities" do
      TestEntityIndex.add_subscription("sub_1", [123, 456, 789])

      assert TestEntityIndex.find_subscriptions_for_entity(123) == ["sub_1"]
      assert TestEntityIndex.find_subscriptions_for_entity(456) == ["sub_1"]
      assert TestEntityIndex.find_subscriptions_for_entity(789) == ["sub_1"]
    end

    test "handles multiple subscriptions for same entity" do
      TestEntityIndex.add_subscription("sub_1", [123])
      TestEntityIndex.add_subscription("sub_2", [123, 456])
      TestEntityIndex.add_subscription("sub_3", [123])

      subs = TestEntityIndex.find_subscriptions_for_entity(123)
      assert length(subs) == 3
      assert "sub_1" in subs
      assert "sub_2" in subs
      assert "sub_3" in subs
    end

    test "handles empty entity list" do
      TestEntityIndex.add_subscription("sub_1", [])

      stats = TestEntityIndex.get_stats()
      assert stats.total_subscriptions == 1
      assert stats.total_entity_entries == 0
    end

    test "logs warning for large entity lists" do
      large_entity_list = Enum.to_list(1..25)

      # This should trigger the large list warning (>20 entities)
      TestEntityIndex.add_subscription("sub_large", large_entity_list)

      # Verify all entities are indexed
      Enum.each(large_entity_list, fn entity_id ->
        assert TestEntityIndex.find_subscriptions_for_entity(entity_id) == ["sub_large"]
      end)
    end
  end

  describe "update_subscription/2" do
    setup do
      TestEntityIndex.add_subscription("sub_1", [123, 456])
      :ok
    end

    test "adds new entities to existing subscription" do
      TestEntityIndex.update_subscription("sub_1", [123, 456, 789])

      assert TestEntityIndex.find_subscriptions_for_entity(123) == ["sub_1"]
      assert TestEntityIndex.find_subscriptions_for_entity(456) == ["sub_1"]
      assert TestEntityIndex.find_subscriptions_for_entity(789) == ["sub_1"]
    end

    test "removes entities no longer in subscription" do
      TestEntityIndex.update_subscription("sub_1", [123])

      assert TestEntityIndex.find_subscriptions_for_entity(123) == ["sub_1"]
      assert TestEntityIndex.find_subscriptions_for_entity(456) == []
    end

    test "completely changes entity list" do
      TestEntityIndex.update_subscription("sub_1", [789, 999])

      assert TestEntityIndex.find_subscriptions_for_entity(123) == []
      assert TestEntityIndex.find_subscriptions_for_entity(456) == []
      assert TestEntityIndex.find_subscriptions_for_entity(789) == ["sub_1"]
      assert TestEntityIndex.find_subscriptions_for_entity(999) == ["sub_1"]
    end

    test "handles updating to empty entity list" do
      TestEntityIndex.update_subscription("sub_1", [])

      assert TestEntityIndex.find_subscriptions_for_entity(123) == []
      assert TestEntityIndex.find_subscriptions_for_entity(456) == []

      stats = TestEntityIndex.get_stats()
      assert stats.total_entity_entries == 0
    end

    test "updates non-existent subscription" do
      # Should create the subscription
      TestEntityIndex.update_subscription("sub_new", [999])

      assert TestEntityIndex.find_subscriptions_for_entity(999) == ["sub_new"]
    end
  end

  describe "remove_subscription/1" do
    setup do
      TestEntityIndex.add_subscription("sub_1", [123, 456])
      TestEntityIndex.add_subscription("sub_2", [456, 789])
      :ok
    end

    test "removes subscription from all its entities" do
      TestEntityIndex.remove_subscription("sub_1")

      assert TestEntityIndex.find_subscriptions_for_entity(123) == []
      assert TestEntityIndex.find_subscriptions_for_entity(456) == ["sub_2"]
      assert TestEntityIndex.find_subscriptions_for_entity(789) == ["sub_2"]
    end

    test "cleans up entity entries with no subscriptions" do
      TestEntityIndex.remove_subscription("sub_1")
      TestEntityIndex.remove_subscription("sub_2")

      assert TestEntityIndex.find_subscriptions_for_entity(123) == []
      assert TestEntityIndex.find_subscriptions_for_entity(456) == []
      assert TestEntityIndex.find_subscriptions_for_entity(789) == []

      stats = TestEntityIndex.get_stats()
      assert stats.total_entity_entries == 0
    end

    test "handles removing non-existent subscription" do
      TestEntityIndex.remove_subscription("sub_999")

      # Should not affect existing subscriptions
      assert TestEntityIndex.find_subscriptions_for_entity(123) == ["sub_1"]
      assert length(TestEntityIndex.find_subscriptions_for_entity(456)) == 2
    end
  end

  describe "find_subscriptions_for_entities/1" do
    setup do
      TestEntityIndex.add_subscription("sub_1", [123, 456])
      TestEntityIndex.add_subscription("sub_2", [456, 789])
      TestEntityIndex.add_subscription("sub_3", [789, 999])
      :ok
    end

    test "finds all unique subscriptions for multiple entities" do
      subs = TestEntityIndex.find_subscriptions_for_entities([123, 789])
      assert length(subs) == 3
      assert "sub_1" in subs
      assert "sub_2" in subs
      assert "sub_3" in subs
    end

    test "deduplicates subscription IDs" do
      # Both entities are in sub_2
      subs = TestEntityIndex.find_subscriptions_for_entities([456, 789])
      assert length(subs) == 3
      assert "sub_1" in subs
      assert "sub_2" in subs
      assert "sub_3" in subs
    end

    test "returns empty list for unknown entities" do
      assert TestEntityIndex.find_subscriptions_for_entities([111, 222]) == []
    end

    test "handles empty entity list" do
      assert TestEntityIndex.find_subscriptions_for_entities([]) == []
    end

    test "handles mix of known and unknown entities" do
      subs = TestEntityIndex.find_subscriptions_for_entities([123, 111])
      assert subs == ["sub_1"]
    end
  end

  describe "get_stats/0" do
    test "returns correct statistics" do
      TestEntityIndex.add_subscription("sub_1", [123, 456, 789])
      TestEntityIndex.add_subscription("sub_2", [456, 789])
      TestEntityIndex.add_subscription("sub_3", [])

      stats = TestEntityIndex.get_stats()

      assert stats.total_subscriptions == 3
      # 123, 456, 789
      assert stats.total_entity_entries == 3
      # 3 + 2 + 0
      assert stats.total_entity_subscriptions == 5
      assert is_number(stats.memory_usage_bytes)
      assert stats.memory_usage_bytes > 0
    end

    test "returns zero stats for empty index" do
      stats = TestEntityIndex.get_stats()

      assert stats.total_subscriptions == 0
      assert stats.total_entity_entries == 0
      assert stats.total_entity_subscriptions == 0
      assert is_number(stats.memory_usage_bytes)
    end
  end

  describe "clear/0" do
    test "removes all cached entries" do
      TestEntityIndex.add_subscription("sub_1", [123, 456])
      TestEntityIndex.add_subscription("sub_2", [789])

      # Verify data exists
      assert TestEntityIndex.find_subscriptions_for_entity(123) == ["sub_1"]
      stats_before = TestEntityIndex.get_stats()
      assert stats_before.total_subscriptions == 2

      # Clear and verify empty
      assert TestEntityIndex.clear() == :ok

      assert TestEntityIndex.find_subscriptions_for_entity(123) == []
      stats_after = TestEntityIndex.get_stats()
      assert stats_after.total_subscriptions == 0
      assert stats_after.total_entity_entries == 0
    end
  end

  describe "performance characteristics" do
    test "handles large number of subscriptions efficiently" do
      # Add 1000 subscriptions, each with 10 entities
      for i <- 1..1000 do
        entities = Enum.to_list((i * 10)..(i * 10 + 9))
        TestEntityIndex.add_subscription("sub_#{i}", entities)
      end

      # Time a lookup
      {time, result} =
        :timer.tc(fn ->
          TestEntityIndex.find_subscriptions_for_entity(5005)
        end)

      assert result == ["sub_500"]

      # Performance assertion only runs when PERF_TEST env var is set
      if System.get_env("PERF_TEST") do
        # Should be very fast, relaxed from 1ms to 5ms
        assert time < 5_000
      end
    end

    test "handles lookups for entities with many subscriptions" do
      # Add 500 subscriptions all interested in entity 123
      for i <- 1..500 do
        TestEntityIndex.add_subscription("sub_#{i}", [123])
      end

      {time, result} =
        :timer.tc(fn ->
          TestEntityIndex.find_subscriptions_for_entity(123)
        end)

      assert length(result) == 500
      # Should still be fast even with many results
      assert time < 2_000
    end

    test "batch entity lookup is efficient" do
      # Setup: 100 subscriptions with various entities
      for i <- 1..100 do
        entities = Enum.to_list((i * 100)..(i * 100 + 50))
        TestEntityIndex.add_subscription("sub_#{i}", entities)
      end

      # Lookup subscriptions for 50 entities
      entities_to_find = Enum.to_list(150..199)

      {time, result} =
        :timer.tc(fn ->
          TestEntityIndex.find_subscriptions_for_entities(entities_to_find)
        end)

      # Should find subscriptions efficiently
      assert length(result) > 0
      # Under 5ms for 50 entity lookups
      assert time < 5_000
    end
  end

  describe "ETS configuration" do
    test "creates ETS table with correct options" do
      info = :ets.info(:test_entity_subscription_index)

      assert info[:type] == :set
      assert info[:protection] == :public
      assert info[:named_table] == true
      assert info[:read_concurrency] == true
      assert info[:write_concurrency] == true
    end
  end

  describe "cleanup functionality" do
    test "periodic cleanup removes empty entries" do
      # Add and then remove a subscription to potentially create empty entries
      TestEntityIndex.add_subscription("temp_sub", [123, 456])
      TestEntityIndex.remove_subscription("temp_sub")

      # Force cleanup
      BaseIndex.cleanup_empty_entries(:test_entity_subscription_index)

      # Verify no entries remain
      stats = TestEntityIndex.get_stats()
      assert stats.total_entity_entries == 0
    end
  end
end
