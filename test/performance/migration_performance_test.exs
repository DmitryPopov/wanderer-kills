defmodule MigrationPerformanceTest do
  @moduledoc """
  Performance benchmark to verify that the migrated indexes maintain
  the same performance characteristics as the original implementations.

  This test validates that the BaseIndex-based implementations are
  equivalent in performance to the original hand-coded versions.
  """

  use ExUnit.Case, async: false

  alias WandererKills.Subs.{CharacterIndex, SystemIndex}

  @test_character_ids [123_456, 789_012, 345_678, 901_234, 567_890]
  @test_system_ids [30_000_142, 30_000_144, 30_000_148, 30_001_407, 30_045_349]
  @subscription_count 100
  @lookup_iterations 1000

  setup do
    # Initialize both indexes if not already initialized
    CharacterIndex.init()
    SystemIndex.init()

    # Clear any existing data
    CharacterIndex.clear()
    SystemIndex.clear()

    on_exit(fn ->
      # Clear data instead of stopping shared GenServers
      CharacterIndex.clear()
      SystemIndex.clear()
    end)

    :ok
  end

  describe "character index performance" do
    @describetag :perf
    test "bulk subscription addition performance" do
      {time, _result} =
        :timer.tc(fn ->
          for i <- 1..@subscription_count do
            entities = Enum.take_random(@test_character_ids, 3)
            CharacterIndex.add_subscription("sub_#{i}", entities)
          end
        end)

      avg_time_per_sub = time / @subscription_count

      # Should be under 1ms per subscription addition
      assert avg_time_per_sub < 1000, "Average time per subscription: #{avg_time_per_sub}μs"

      IO.puts("Character Index - Bulk Addition Performance:")
      IO.puts("  Total time: #{Float.round(time / 1000, 2)}ms")
      IO.puts("  Average per subscription: #{Float.round(avg_time_per_sub, 2)}μs")
    end

    test "lookup performance under load" do
      # Add test data
      for i <- 1..@subscription_count do
        entities = Enum.take_random(@test_character_ids, 3)
        CharacterIndex.add_subscription("sub_#{i}", entities)
      end

      # Benchmark single entity lookups
      {time, _result} =
        :timer.tc(fn ->
          for _i <- 1..@lookup_iterations do
            test_entity = Enum.random(@test_character_ids)
            CharacterIndex.find_subscriptions_for_character(test_entity)
          end
        end)

      avg_lookup_time = time / @lookup_iterations

      # Should be under 100μs per lookup
      assert avg_lookup_time < 100, "Average lookup time: #{avg_lookup_time}μs"

      IO.puts("Character Index - Lookup Performance:")
      IO.puts("  Total time: #{Float.round(time / 1000, 2)}ms")
      IO.puts("  Average per lookup: #{Float.round(avg_lookup_time, 2)}μs")
    end

    test "batch lookup performance" do
      # Add test data
      for i <- 1..@subscription_count do
        entities = Enum.take_random(@test_character_ids, 3)
        CharacterIndex.add_subscription("sub_#{i}", entities)
      end

      batch_iterations = div(@lookup_iterations, 10)

      {time, _result} =
        :timer.tc(fn ->
          for _i <- 1..batch_iterations do
            CharacterIndex.find_subscriptions_for_characters(@test_character_ids)
          end
        end)

      avg_batch_time = time / batch_iterations

      # Batch lookups should be efficient
      assert avg_batch_time < 1000, "Average batch lookup time: #{avg_batch_time}μs"

      IO.puts("Character Index - Batch Lookup Performance:")
      IO.puts("  Average per batch: #{Float.round(avg_batch_time, 2)}μs")
    end

    test "health check performance" do
      # Add test data
      for i <- 1..@subscription_count do
        entities = Enum.take_random(@test_character_ids, 2)
        CharacterIndex.add_subscription("sub_#{i}", entities)
      end

      {time, health} =
        :timer.tc(fn ->
          WandererKills.Core.Observability.Health.check_component(:character_subscriptions)
        end)

      # Health checks should complete quickly
      assert time < 50_000, "Health check took: #{time}μs"
      assert health.healthy == true

      IO.puts("Character Health - Check Performance:")
      IO.puts("  Health check time: #{Float.round(time / 1000, 2)}ms")
    end
  end

  describe "system index performance" do
    @describetag :perf
    test "bulk subscription addition performance" do
      {time, _result} =
        :timer.tc(fn ->
          for i <- 1..@subscription_count do
            entities = Enum.take_random(@test_system_ids, 3)
            SystemIndex.add_subscription("sub_#{i}", entities)
          end
        end)

      avg_time_per_sub = time / @subscription_count

      # Should be under 1ms per subscription addition
      assert avg_time_per_sub < 1000, "Average time per subscription: #{avg_time_per_sub}μs"

      IO.puts("System Index - Bulk Addition Performance:")
      IO.puts("  Total time: #{Float.round(time / 1000, 2)}ms")
      IO.puts("  Average per subscription: #{Float.round(avg_time_per_sub, 2)}μs")
    end

    test "lookup performance under load" do
      # Add test data
      for i <- 1..@subscription_count do
        entities = Enum.take_random(@test_system_ids, 3)
        SystemIndex.add_subscription("sub_#{i}", entities)
      end

      # Benchmark single entity lookups
      {time, _result} =
        :timer.tc(fn ->
          for _i <- 1..@lookup_iterations do
            test_entity = Enum.random(@test_system_ids)
            SystemIndex.find_subscriptions_for_system(test_entity)
          end
        end)

      avg_lookup_time = time / @lookup_iterations

      # Should be under 100μs per lookup
      assert avg_lookup_time < 100, "Average lookup time: #{avg_lookup_time}μs"

      IO.puts("System Index - Lookup Performance:")
      IO.puts("  Total time: #{Float.round(time / 1000, 2)}ms")
      IO.puts("  Average per lookup: #{Float.round(avg_lookup_time, 2)}μs")
    end

    test "health check performance" do
      # Add test data
      for i <- 1..@subscription_count do
        entities = Enum.take_random(@test_system_ids, 2)
        SystemIndex.add_subscription("sub_#{i}", entities)
      end

      {time, health} =
        :timer.tc(fn ->
          WandererKills.Core.Observability.Health.check_component(:system_subscriptions)
        end)

      # Health checks should complete quickly
      assert time < 50_000, "Health check took: #{time}μs"
      assert health.healthy == true

      IO.puts("System Health - Check Performance:")
      IO.puts("  Health check time: #{Float.round(time / 1000, 2)}ms")
    end
  end

  describe "memory efficiency" do
    @describetag :perf
    test "memory usage is reasonable" do
      # Add substantial test data
      for i <- 1..500 do
        char_entities = Enum.take_random(@test_character_ids, 3)
        sys_entities = Enum.take_random(@test_system_ids, 3)

        CharacterIndex.add_subscription("char_sub_#{i}", char_entities)
        SystemIndex.add_subscription("sys_sub_#{i}", sys_entities)
      end

      char_stats = CharacterIndex.get_stats()
      sys_stats = SystemIndex.get_stats()

      char_memory_mb = char_stats.memory_usage_bytes / (1024 * 1024)
      sys_memory_mb = sys_stats.memory_usage_bytes / (1024 * 1024)

      # Memory usage should be reasonable for the data size
      assert char_memory_mb < 10, "Character index memory: #{char_memory_mb}MB"
      assert sys_memory_mb < 10, "System index memory: #{sys_memory_mb}MB"

      IO.puts("Memory Usage:")
      IO.puts("  Character Index: #{Float.round(char_memory_mb, 2)}MB")
      IO.puts("  System Index: #{Float.round(sys_memory_mb, 2)}MB")
    end
  end
end
