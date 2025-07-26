defmodule WandererKills.Benchmarks.CacheBenchmark do
  @moduledoc """
  Benchmarks for cache operations measuring:
  - Cache hit/miss performance
  - Character extraction caching performance
  - Ship type cache performance
  - Cache memory usage under load
  - TTL expiration overhead

  Run with: mix run bench/cache_benchmark.exs
  """

  alias WandererKills.Core.Cache
  alias WandererKills.Core.Storage.ShipTypes
  alias WandererKills.TestFactory

  require Logger

  def run do
    Logger.info("Starting Cache Operation Benchmarks...")
    
    # Ensure application is started
    Application.ensure_all_started(:wanderer_kills)
    
    # Clear cache before starting
    Cache.delete_all()
    
    # Run benchmarks
    benchmark_cache_hit_miss()
    benchmark_character_extraction_cache()
    benchmark_ship_type_cache()
    benchmark_concurrent_cache_operations()
    benchmark_cache_memory_usage()
    benchmark_ttl_performance()
    
    Logger.info("Cache benchmarks completed!")
  end

  defp benchmark_cache_hit_miss do
    Logger.info("\n=== Cache Hit/Miss Performance Benchmark ===")
    
    # Prepare test data
    test_keys = for i <- 1..10_000, do: "test_key_#{i}"
    test_data = %{
      id: 12345,
      name: "Test Item",
      attributes: Enum.map(1..10, fn i -> {"attr_#{i}", :rand.uniform(1000)} end) |> Map.new()
    }
    
    # Benchmark cache misses
    miss_times = for key <- Enum.take(test_keys, 1000) do
      {time, _} = :timer.tc(fn ->
        Cache.get("cache_miss", key)
      end)
      time
    end
    
    avg_miss = Enum.sum(miss_times) / length(miss_times)
    
    # Populate cache for hit testing
    Enum.each(Enum.take(test_keys, 5000), fn key ->
      Cache.put("cache_hit", key, test_data, ttl: :timer.minutes(5))
    end)
    
    # Benchmark cache hits
    hit_times = for key <- Enum.take(test_keys, 1000) do
      {time, _} = :timer.tc(fn ->
        Cache.get("cache_hit", key)
      end)
      time
    end
    
    avg_hit = Enum.sum(hit_times) / length(hit_times)
    
    Logger.info("""
    Cache performance (1000 operations each):
      Cache miss avg: #{Float.round(avg_miss, 2)} μs
      Cache hit avg: #{Float.round(avg_hit, 2)} μs
      Hit/miss ratio: #{Float.round(avg_hit / avg_miss, 2)}x faster
    """)
    
    # Benchmark different data sizes
    Logger.info("\nCache performance by data size:")
    
    data_sizes = [
      {10, "Small (10 fields)"},
      {100, "Medium (100 fields)"},
      {1000, "Large (1000 fields)"}
    ]
    
    Enum.each(data_sizes, fn {size, label} ->
      large_data = Enum.map(1..size, fn i -> {"field_#{i}", :rand.uniform(10000)} end) |> Map.new()
      
      # Write
      {write_time, _} = :timer.tc(fn ->
        Cache.put("size_test", "key_#{size}", large_data)
      end)
      
      # Read
      {read_time, _} = :timer.tc(fn ->
        Cache.get("size_test", "key_#{size}")
      end)
      
      Logger.info("""
        #{label}:
          Write: #{Float.round(write_time, 2)} μs
          Read: #{Float.round(read_time, 2)} μs
      """)
    end)
  end

  defp benchmark_character_extraction_cache do
    Logger.info("\n=== Character Extraction Cache Benchmark ===")
    
    # Generate test killmails
    killmails = Enum.map(1..1000, fn i ->
      TestFactory.build(:full_killmail,
        killmail_id: i,
        attackers: Enum.map(1..20, fn j ->
          %{"character_id" => i * 1000 + j}
        end)
      )
    end)
    
    # Benchmark without cache (first extraction)
    Cache.delete_all("characters")
    
    {no_cache_time, _} = :timer.tc(fn ->
      Enum.each(killmails, fn km ->
        characters = extract_all_characters(km)
        Cache.put("characters", "km_#{km.killmail_id}", characters, ttl: :timer.minutes(5))
      end)
    end)
    
    # Benchmark with cache (subsequent lookups)
    {with_cache_time, _} = :timer.tc(fn ->
      Enum.each(killmails, fn km ->
        case Cache.get("characters", "km_#{km.killmail_id}") do
          {:ok, _cached} -> :ok
          {:error, :not_found} -> 
            characters = extract_all_characters(km)
            Cache.put("characters", "km_#{km.killmail_id}", characters)
        end
      end)
    end)
    
    Logger.info("""
    Character extraction caching (1000 killmails):
      Without cache: #{Float.round(no_cache_time / 1000, 2)}ms
      With cache: #{Float.round(with_cache_time / 1000, 2)}ms
      Speed improvement: #{Float.round(no_cache_time / with_cache_time, 1)}x
      Cache efficiency: #{Float.round((1 - with_cache_time / no_cache_time) * 100, 1)}%
    """)
    
    # Test cache effectiveness with partial hits
    Cache.delete_pattern("characters", "km_*")
    
    # Cache only 50% of killmails
    Enum.take_every(killmails, 2) |> Enum.each(fn km ->
      characters = extract_all_characters(km)
      Cache.put("characters", "km_#{km.killmail_id}", characters)
    end)
    
    hit_count = :counters.new(1, [])
    miss_count = :counters.new(1, [])
    
    {mixed_time, _} = :timer.tc(fn ->
      Enum.each(killmails, fn km ->
        case Cache.get("characters", "km_#{km.killmail_id}") do
          {:ok, _} -> :counters.add(hit_count, 1, 1)
          {:error, :not_found} -> 
            :counters.add(miss_count, 1, 1)
            characters = extract_all_characters(km)
            Cache.put("characters", "km_#{km.killmail_id}", characters)
        end
      end)
    end)
    
    hits = :counters.get(hit_count, 1)
    misses = :counters.get(miss_count, 1)
    
    Logger.info("""
    Mixed cache scenario (50% pre-cached):
      Time: #{Float.round(mixed_time / 1000, 2)}ms
      Cache hits: #{hits}
      Cache misses: #{misses}
      Hit rate: #{Float.round(hits / (hits + misses) * 100, 1)}%
    """)
  end

  defp benchmark_ship_type_cache do
    Logger.info("\n=== Ship Type Cache Benchmark ===")
    
    # Get all ship type IDs from the system
    ship_type_ids = case ShipTypes.CSV.list_ship_types() do
      {:ok, types} -> Enum.map(types, & &1.type_id) |> Enum.take(1000)
      _ -> Enum.map(1..1000, & &1)  # Fallback for testing
    end
    
    # Benchmark individual lookups
    lookup_times = for type_id <- Enum.take(ship_type_ids, 100) do
      {time, _} = :timer.tc(fn ->
        ShipTypes.get_ship_type(type_id)
      end)
      time
    end
    
    avg_lookup = Enum.sum(lookup_times) / length(lookup_times)
    
    # Benchmark batch operations
    batch_sizes = [10, 50, 100, 500]
    
    Enum.each(batch_sizes, fn size ->
      batch = Enum.take(ship_type_ids, size)
      
      {batch_time, _} = :timer.tc(fn ->
        Enum.map(batch, &ShipTypes.get_ship_type/1)
      end)
      
      avg_per_ship = batch_time / size
      
      Logger.info("""
      Ship type cache - batch size #{size}:
        Total time: #{Float.round(batch_time / 1000, 2)}ms
        Avg per lookup: #{Float.round(avg_per_ship, 2)} μs
      """)
    end)
    
    Logger.info("""
    Ship type cache performance:
      Average lookup time: #{Float.round(avg_lookup, 2)} μs
      Lookups per second: #{Float.round(1_000_000 / avg_lookup, 0)}
    """)
  end

  defp benchmark_concurrent_cache_operations do
    Logger.info("\n=== Concurrent Cache Operations Benchmark ===")
    
    # Test concurrent reads
    test_key = "concurrent_test"
    test_value = %{data: "test", timestamp: DateTime.utc_now()}
    Cache.put("concurrent", test_key, test_value)
    
    read_counts = [10, 50, 100, 500]
    
    Enum.each(read_counts, fn count ->
      {time, _} = :timer.tc(fn ->
        tasks = for _ <- 1..count do
          Task.async(fn ->
            Cache.get("concurrent", test_key)
          end)
        end
        
        Task.await_many(tasks)
      end)
      
      Logger.info("""
      Concurrent reads (#{count} tasks):
        Total time: #{Float.round(time / 1000, 2)}ms
        Avg per read: #{Float.round(time / count, 2)} μs
        Throughput: #{Float.round(count / (time / 1_000_000), 0)} reads/sec
      """)
    end)
    
    # Test concurrent writes
    Logger.info("\nConcurrent write performance:")
    
    write_counts = [10, 50, 100, 500]
    
    Enum.each(write_counts, fn count ->
      {time, _} = :timer.tc(fn ->
        tasks = for i <- 1..count do
          Task.async(fn ->
            Cache.put("concurrent_write", "key_#{i}", %{id: i, data: "test_#{i}"})
          end)
        end
        
        Task.await_many(tasks)
      end)
      
      Logger.info("""
      Concurrent writes (#{count} tasks):
        Total time: #{Float.round(time / 1000, 2)}ms
        Avg per write: #{Float.round(time / count, 2)} μs
        Throughput: #{Float.round(count / (time / 1_000_000), 0)} writes/sec
      """)
    end)
    
    # Test mixed read/write workload
    Logger.info("\nMixed workload (70% reads, 30% writes):")
    
    {mixed_time, _} = :timer.tc(fn ->
      tasks = for i <- 1..1000 do
        Task.async(fn ->
          if :rand.uniform(100) <= 70 do
            # Read operation
            Cache.get("mixed", "key_#{:rand.uniform(100)}")
          else
            # Write operation
            Cache.put("mixed", "key_#{i}", %{id: i, timestamp: System.system_time()})
          end
        end)
      end
      
      Task.await_many(tasks)
    end)
    
    Logger.info("""
    Mixed workload (1000 operations):
      Total time: #{Float.round(mixed_time / 1_000_000, 2)}s
      Throughput: #{Float.round(1000 / (mixed_time / 1_000_000), 0)} ops/sec
    """)
  end

  defp benchmark_cache_memory_usage do
    Logger.info("\n=== Cache Memory Usage Benchmark ===")
    
    # Clear cache and force GC
    Cache.delete_all()
    :erlang.garbage_collect()
    
    initial_memory = :erlang.memory(:total)
    
    # Add different amounts of data
    data_points = [
      {1_000, "1K entries"},
      {10_000, "10K entries"},
      {50_000, "50K entries"}
    ]
    
    Enum.each(data_points, fn {count, label} ->
      # Clear previous data
      Cache.delete_all()
      :erlang.garbage_collect()
      Process.sleep(100)
      
      before_memory = :erlang.memory(:total)
      
      # Add entries
      for i <- 1..count do
        Cache.put("memory_test", "key_#{i}", %{
          id: i,
          name: "Item #{i}",
          description: "A test item with some data to simulate realistic cache entries",
          attributes: %{
            value: :rand.uniform(1_000_000),
            category: "test",
            tags: ["tag1", "tag2", "tag3"]
          }
        })
      end
      
      after_memory = :erlang.memory(:total)
      memory_used = after_memory - before_memory
      memory_per_entry = memory_used / count
      
      # Get cache stats
      stats = Cache.stats()
      
      Logger.info("""
      Memory usage - #{label}:
        Total memory used: #{Float.round(memory_used / 1024 / 1024, 2)} MB
        Memory per entry: #{Float.round(memory_per_entry / 1024, 2)} KB
        Cache size: #{stats.size}
        Hit rate: #{Float.round(stats.hit_rate * 100, 1)}%
      """)
    end)
  end

  defp benchmark_ttl_performance do
    Logger.info("\n=== TTL Performance Benchmark ===")
    
    # Test different TTL values
    ttl_configs = [
      {1_000, "1 second", 100},
      {5_000, "5 seconds", 500},
      {60_000, "1 minute", 1000}
    ]
    
    Enum.each(ttl_configs, fn {ttl_ms, label, count} ->
      # Add entries with TTL
      {insert_time, _} = :timer.tc(fn ->
        for i <- 1..count do
          Cache.put("ttl_test", "ttl_key_#{i}", %{id: i}, ttl: ttl_ms)
        end
      end)
      
      # Check entries before expiration
      Process.sleep(div(ttl_ms, 2))
      
      {check_time, alive_count} = :timer.tc(fn ->
        Enum.count(1..count, fn i ->
          case Cache.get("ttl_test", "ttl_key_#{i}") do
            {:ok, _} -> true
            _ -> false
          end
        end)
      end)
      
      # Wait for expiration
      Process.sleep(div(ttl_ms, 2) + 100)
      
      {expired_check_time, expired_count} = :timer.tc(fn ->
        Enum.count(1..count, fn i ->
          case Cache.get("ttl_test", "ttl_key_#{i}") do
            {:ok, _} -> true
            _ -> false
          end
        end)
      end)
      
      Logger.info("""
      TTL #{label} (#{count} entries):
        Insert time: #{Float.round(insert_time / 1000, 2)}ms
        Mid-TTL check: #{alive_count}/#{count} alive (#{Float.round(check_time / 1000, 2)}ms)
        Post-TTL check: #{expired_count}/#{count} alive (#{Float.round(expired_check_time / 1000, 2)}ms)
        TTL overhead: #{Float.round((insert_time / count - insert_time / count) * 100, 1)}%
      """)
    end)
    
    # Clean up
    Cache.delete_pattern("ttl_test", "*")
  end

  # Helper function to extract characters from killmail
  defp extract_all_characters(killmail) do
    victim_chars = case killmail[:victim] do
      %{"character_id" => id} when is_integer(id) -> [id]
      _ -> []
    end
    
    attacker_chars = case killmail[:attackers] do
      attackers when is_list(attackers) ->
        Enum.flat_map(attackers, fn
          %{"character_id" => id} when is_integer(id) -> [id]
          _ -> []
        end)
      _ -> []
    end
    
    Enum.uniq(victim_chars ++ attacker_chars)
  end
end

# Run the benchmarks
WandererKills.Benchmarks.CacheBenchmark.run()