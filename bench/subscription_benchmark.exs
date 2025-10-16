defmodule WandererKills.Benchmarks.SubscriptionBenchmark do
  @moduledoc """
  Benchmarks for the subscription system measuring:
  - Character index lookup performance (~7.64 μs target)
  - System index lookup performance (~8.32 μs target)
  - Subscription filtering performance
  - WebSocket message broadcasting performance

  Run with: mix run bench/subscription_benchmark.exs
  """

  alias WandererKills.Subs.Subscriptions.{CharacterIndex, SystemIndex, Filter}
  alias WandererKills.Subs.Broadcaster
  alias WandererKills.TestFactory

  require Logger

  def run do
    Logger.info("Starting Subscription System Benchmarks...")
    
    # Ensure application is started
    Application.ensure_all_started(:wanderer_kills)
    
    # Clear any existing data
    CharacterIndex.clear()
    SystemIndex.clear()
    
    # Run benchmarks
    benchmark_character_index_lookups()
    benchmark_system_index_lookups()
    benchmark_subscription_filtering()
    benchmark_websocket_broadcasting()
    benchmark_large_scale_subscriptions()
    
    Logger.info("Subscription benchmarks completed!")
  end

  defp benchmark_character_index_lookups do
    Logger.info("\n=== Character Index Lookup Benchmark ===")
    Logger.info("Target: ~7.64 μs per lookup")
    
    # Populate index with realistic data
    Logger.info("Populating CharacterIndex with 50,000 character subscriptions...")
    
    populate_time = :timer.tc(fn ->
      for i <- 1..5_000 do
        # Each subscription has 1-20 characters
        char_count = 1 + :rand.uniform(19)
        characters = Enum.map(1..char_count, fn _ -> :rand.uniform(10_000_000) end)
        CharacterIndex.add_subscription("sub_#{i}", characters)
      end
    end) |> elem(0)
    
    Logger.info("Population completed in #{Float.round(populate_time / 1_000_000, 2)}s")
    
    # Benchmark single lookups
    test_characters = Enum.map(1..10_000, fn _ -> :rand.uniform(10_000_000) end)
    
    lookup_times = for char_id <- test_characters do
      {time, _} = :timer.tc(fn ->
        CharacterIndex.find_subscriptions_for_entity(char_id)
      end)
      time
    end
    
    avg_lookup = Enum.sum(lookup_times) / length(lookup_times)
    min_lookup = Enum.min(lookup_times)
    max_lookup = Enum.max(lookup_times)
    p95_lookup = percentile(lookup_times, 95)
    p99_lookup = percentile(lookup_times, 99)
    
    Logger.info("""
    Character index lookups (10,000 operations):
      Average: #{Float.round(avg_lookup, 2)} μs
      Min: #{Float.round(min_lookup, 2)} μs
      Max: #{Float.round(max_lookup, 2)} μs
      P95: #{Float.round(p95_lookup, 2)} μs
      P99: #{Float.round(p99_lookup, 2)} μs
      Status: #{if avg_lookup <= 7.64, do: "✓ PASS", else: "✗ FAIL (target: 7.64 μs)"}
    """)
    
    # Benchmark batch lookups
    batch_sizes = [10, 50, 100, 500]
    
    Enum.each(batch_sizes, fn batch_size ->
      batch = Enum.take(test_characters, batch_size)
      
      {batch_time, _} = :timer.tc(fn ->
        CharacterIndex.find_subscriptions_for_entities(batch)
      end)
      
      avg_per_char = batch_time / batch_size
      
      Logger.info("""
      Batch lookup (#{batch_size} characters):
        Total time: #{Float.round(batch_time / 1000, 2)}ms
        Avg per character: #{Float.round(avg_per_char, 2)} μs
      """)
    end)
  end

  defp benchmark_system_index_lookups do
    Logger.info("\n=== System Index Lookup Benchmark ===")
    Logger.info("Target: ~8.32 μs per lookup")
    
    # Populate index with realistic data
    Logger.info("Populating SystemIndex with 10,000 system subscriptions...")
    
    populate_time = :timer.tc(fn ->
      for i <- 1..2_000 do
        # Each subscription has 1-10 systems
        system_count = 1 + :rand.uniform(9)
        systems = Enum.map(1..system_count, fn _ -> 30_000_000 + :rand.uniform(10_000) end)
        SystemIndex.add_subscription("sub_#{i}", systems)
      end
    end) |> elem(0)
    
    Logger.info("Population completed in #{Float.round(populate_time / 1_000_000, 2)}s")
    
    # Benchmark single lookups
    test_systems = Enum.map(1..10_000, fn _ -> 30_000_000 + :rand.uniform(10_000) end)
    
    lookup_times = for system_id <- test_systems do
      {time, _} = :timer.tc(fn ->
        SystemIndex.find_subscriptions_for_entity(system_id)
      end)
      time
    end
    
    avg_lookup = Enum.sum(lookup_times) / length(lookup_times)
    min_lookup = Enum.min(lookup_times)
    max_lookup = Enum.max(lookup_times)
    p95_lookup = percentile(lookup_times, 95)
    p99_lookup = percentile(lookup_times, 99)
    
    Logger.info("""
    System index lookups (10,000 operations):
      Average: #{Float.round(avg_lookup, 2)} μs
      Min: #{Float.round(min_lookup, 2)} μs
      Max: #{Float.round(max_lookup, 2)} μs
      P95: #{Float.round(p95_lookup, 2)} μs
      P99: #{Float.round(p99_lookup, 2)} μs
      Status: #{if avg_lookup <= 8.32, do: "✓ PASS", else: "✗ FAIL (target: 8.32 μs)"}
    """)
  end

  defp benchmark_subscription_filtering do
    Logger.info("\n=== Subscription Filtering Benchmark ===")
    
    # Generate test killmails with various attributes
    killmails = Enum.map(1..1000, fn i ->
      TestFactory.build(:full_killmail,
        killmail_id: i,
        solar_system_id: 30_000_000 + :rand.uniform(5000),
        total_value: :rand.uniform(1_000_000_000)
      )
    end)
    
    # Create subscriptions with different filter criteria
    subscriptions = [
      %{
        "id" => "value_filter",
        "filters" => %{"min_value" => 100_000_000}
      },
      %{
        "id" => "system_filter",
        "system_ids" => Enum.map(1..100, fn _ -> 30_000_000 + :rand.uniform(5000) end)
      },
      %{
        "id" => "character_filter",
        "character_ids" => Enum.map(1..500, fn _ -> :rand.uniform(10_000_000) end)
      },
      %{
        "id" => "combined_filter",
        "filters" => %{"min_value" => 50_000_000},
        "system_ids" => Enum.map(1..50, fn _ -> 30_000_000 + :rand.uniform(5000) end),
        "character_ids" => Enum.map(1..200, fn _ -> :rand.uniform(10_000_000) end)
      }
    ]
    
    Enum.each(subscriptions, fn sub ->
      {time, matches} = :timer.tc(fn ->
        Enum.filter(killmails, fn km ->
          Filter.matches_subscription?(km, sub)
        end)
      end)
      
      Logger.info("""
      Filter type: #{sub["id"]}
        Time: #{Float.round(time / 1000, 2)}ms
        Matches: #{length(matches)}/#{length(killmails)}
        Avg per killmail: #{Float.round(time / length(killmails), 2)} μs
      """)
    end)
  end

  defp benchmark_websocket_broadcasting do
    Logger.info("\n=== WebSocket Broadcasting Benchmark ===")
    
    # Simulate different numbers of connected clients
    client_counts = [100, 1_000, 5_000, 10_000]
    
    # Generate a test killmail to broadcast
    killmail = TestFactory.build(:full_killmail)
    
    Enum.each(client_counts, fn client_count ->
      # Simulate clients by subscribing to topics
      topics = for i <- 1..client_count do
        topic = "subscription:sub_#{i}"
        Phoenix.PubSub.subscribe(WandererKills.PubSub, topic)
        topic
      end
      
      # Measure broadcast time
      {broadcast_time, _} = :timer.tc(fn ->
        Enum.each(topics, fn topic ->
          Broadcaster.broadcast_killmail(topic, killmail)
        end)
      end)
      
      # Unsubscribe
      Enum.each(topics, fn topic ->
        Phoenix.PubSub.unsubscribe(WandererKills.PubSub, topic)
      end)
      
      avg_per_client = broadcast_time / client_count
      
      Logger.info("""
      Broadcasting to #{client_count} clients:
        Total time: #{Float.round(broadcast_time / 1_000_000, 2)}s
        Avg per client: #{Float.round(avg_per_client / 1000, 2)}ms
        Throughput: #{Float.round(client_count / (broadcast_time / 1_000_000), 1)} broadcasts/sec
      """)
    end)
  end

  defp benchmark_large_scale_subscriptions do
    Logger.info("\n=== Large Scale Subscription Benchmark ===")
    Logger.info("Testing scalability targets: 50,000 characters, 10,000 systems")
    
    # Clear indexes
    CharacterIndex.clear()
    SystemIndex.clear()
    
    # Create realistic subscription distribution
    Logger.info("Creating 5,000 subscriptions with mixed interests...")
    
    {setup_time, _} = :timer.tc(fn ->
      for i <- 1..5_000 do
        sub_id = "sub_#{i}"
        
        # 60% have character interests (1-50 characters each)
        if :rand.uniform(100) <= 60 do
          char_count = 1 + :rand.uniform(49)
          characters = Enum.map(1..char_count, fn _ -> :rand.uniform(100_000_000) end)
          CharacterIndex.add_subscription(sub_id, characters)
        end
        
        # 40% have system interests (1-10 systems each)
        if :rand.uniform(100) <= 40 do
          system_count = 1 + :rand.uniform(9)
          systems = Enum.map(1..system_count, fn _ -> 30_000_000 + :rand.uniform(10_000) end)
          SystemIndex.add_subscription(sub_id, systems)
        end
      end
    end)
    
    Logger.info("Setup completed in #{Float.round(setup_time / 1_000_000, 2)}s")
    
    # Get index statistics
    char_stats = CharacterIndex.get_stats()
    sys_stats = SystemIndex.get_stats()
    
    Logger.info("""
    Index statistics:
      Character Index:
        Total subscriptions: #{char_stats.subscription_count}
        Total characters tracked: #{char_stats.entity_count}
        Memory usage: #{Float.round(char_stats.memory_bytes / 1024 / 1024, 2)} MB
      System Index:
        Total subscriptions: #{sys_stats.subscription_count}
        Total systems tracked: #{sys_stats.entity_count}
        Memory usage: #{Float.round(sys_stats.memory_bytes / 1024 / 1024, 2)} MB
    """)
    
    # Benchmark killmail matching at scale
    test_killmails = Enum.map(1..100, fn i ->
      TestFactory.build(:full_killmail,
        killmail_id: i,
        solar_system_id: 30_000_000 + :rand.uniform(10_000)
      )
    end)
    
    {match_time, results} = :timer.tc(fn ->
      Enum.map(test_killmails, fn km ->
        characters = WandererKills.Ingest.Killmails.CharacterMatcher.extract_character_ids(km)
        char_subs = CharacterIndex.find_subscriptions_for_entities(characters)
        sys_subs = SystemIndex.find_subscriptions_for_entity(km.solar_system_id)
        
        MapSet.union(char_subs, sys_subs) |> MapSet.size()
      end)
    end)
    
    total_matches = Enum.sum(results)
    avg_matches = total_matches / length(test_killmails)
    avg_time = match_time / length(test_killmails)
    
    Logger.info("""
    Large scale matching (100 killmails):
      Total time: #{Float.round(match_time / 1000, 2)}ms
      Avg time per killmail: #{Float.round(avg_time / 1000, 2)}ms
      Total subscription matches: #{total_matches}
      Avg matches per killmail: #{Float.round(avg_matches, 1)}
      Throughput: #{Float.round(1_000_000 / avg_time, 1)} killmails/sec
    """)
  end

  # Helper function to calculate percentile
  defp percentile(list, p) do
    sorted = Enum.sort(list)
    k = (length(sorted) - 1) * p / 100
    f = :erlang.floor(k)
    c = :erlang.ceil(k)
    
    if f == c do
      Enum.at(sorted, trunc(k))
    else
      d0 = Enum.at(sorted, trunc(f)) * (c - k)
      d1 = Enum.at(sorted, trunc(c)) * (k - f)
      d0 + d1
    end
  end
end

# Run the benchmarks
WandererKills.Benchmarks.SubscriptionBenchmark.run()