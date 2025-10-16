defmodule WandererKills.Benchmarks.UnifiedProcessorBenchmark do
  @moduledoc """
  Benchmarks for the UnifiedProcessor pipeline measuring:
  - Single killmail processing time
  - Batch processing performance (10, 50, 100 killmails)
  - Validation, enrichment, and storage stages separately
  - Full vs partial killmail processing

  Run with: mix run bench/unified_processor_benchmark.exs
  """

  alias WandererKills.Ingest.Killmails.UnifiedProcessor
  alias WandererKills.Core.Storage.KillmailStore
  alias WandererKills.TestFactory
  alias WandererKills.Core.Cache

  require Logger

  def run do
    Logger.info("Starting UnifiedProcessor Benchmarks...")
    
    # Ensure application is started
    Application.ensure_all_started(:wanderer_kills)
    
    # Clear any existing data
    KillmailStore.clear()
    Cache.delete_all()
    
    # Run benchmarks
    benchmark_single_killmail_processing()
    benchmark_batch_processing()
    benchmark_pipeline_stages()
    benchmark_full_vs_partial()
    benchmark_memory_usage()
    
    Logger.info("UnifiedProcessor benchmarks completed!")
  end

  defp benchmark_single_killmail_processing do
    Logger.info("\n=== Single Killmail Processing Benchmark ===")
    
    # Generate test killmails
    full_killmail = TestFactory.build(:full_killmail)
    
    # Get cutoff time (24 hours ago)
    cutoff_time = DateTime.utc_now() |> DateTime.add(-24 * 60 * 60, :second)
    
    # Warm up
    UnifiedProcessor.process_killmail(full_killmail, cutoff_time)
    
    # Measure single killmail processing
    times = for _ <- 1..100 do
      KillmailStore.clear()
      {time, _} = :timer.tc(fn ->
        UnifiedProcessor.process_killmail(full_killmail, cutoff_time)
      end)
      time
    end
    
    avg_time = Enum.sum(times) / length(times)
    min_time = Enum.min(times)
    max_time = Enum.max(times)
    
    Logger.info("""
    Single killmail processing (100 runs):
      Average: #{Float.round(avg_time / 1000, 2)}ms
      Min: #{Float.round(min_time / 1000, 2)}ms
      Max: #{Float.round(max_time / 1000, 2)}ms
    """)
  end

  defp benchmark_batch_processing do
    Logger.info("\n=== Batch Processing Benchmark ===")
    
    batch_sizes = [10, 50, 100, 500]
    
    Enum.each(batch_sizes, fn size ->
      # Generate batch
      killmails = Enum.map(1..size, fn i ->
        TestFactory.build(:full_killmail, killmail_id: i)
      end)
      
      KillmailStore.clear()
      
      {time, _} = :timer.tc(fn ->
        UnifiedProcessor.process_batch(killmails, cutoff_time)
      end)
      
      avg_per_killmail = time / size
      
      Logger.info("""
      Batch size #{size}:
        Total time: #{Float.round(time / 1000, 2)}ms
        Avg per killmail: #{Float.round(avg_per_killmail / 1000, 2)}ms
        Throughput: #{Float.round(1_000_000 / avg_per_killmail, 1)} killmails/sec
      """)
    end)
  end

  defp benchmark_pipeline_stages do
    Logger.info("\n=== Pipeline Stages Benchmark ===")
    
    cutoff_time = DateTime.utc_now() |> DateTime.add(-24 * 60 * 60, :second)
    
    # Generate test data
    raw_killmail = TestFactory.build(:raw_killmail)
    full_killmail = TestFactory.build(:full_killmail)
    
    # Benchmark validation-only processing
    {validation_time, _} = :timer.tc(fn ->
      for _ <- 1..1000 do
        UnifiedProcessor.process_killmail(raw_killmail, cutoff_time, validate_only: true)
      end
    end)
    
    # Benchmark with enrichment but no storage
    {enrichment_time, _} = :timer.tc(fn ->
      for _ <- 1..100 do
        UnifiedProcessor.process_killmail(full_killmail, cutoff_time, store: false)
      end
    end)
    
    # Benchmark storage only
    {storage_time, _} = :timer.tc(fn ->
      for i <- 1..1000 do
        killmail = Map.put(full_killmail, :killmail_id, i)
        KillmailStore.store(killmail)
      end
    end)
    
    Logger.info("""
    Pipeline stages (average per operation):
      Validation only: #{Float.round(validation_time / 1000 / 1000, 3)}ms
      With enrichment: #{Float.round(enrichment_time / 100 / 1000, 3)}ms
      Storage: #{Float.round(storage_time / 1000 / 1000, 3)}ms
    """)
  end

  defp benchmark_full_vs_partial do
    Logger.info("\n=== Full vs Partial Killmail Processing ===")
    
    cutoff_time = DateTime.utc_now() |> DateTime.add(-24 * 60 * 60, :second)
    
    # Generate test data
    full_killmail = TestFactory.build(:full_killmail)
    partial_killmail = TestFactory.build(:partial_killmail)
    
    # Process full killmails
    full_times = for i <- 1..100 do
      km = Map.put(full_killmail, :killmail_id, i)
      {time, _} = :timer.tc(fn ->
        UnifiedProcessor.process_killmail(km, cutoff_time)
      end)
      time
    end
    
    # Process partial killmails
    partial_times = for i <- 101..200 do
      km = Map.put(partial_killmail, :killmail_id, i)
      {time, _} = :timer.tc(fn ->
        UnifiedProcessor.process_killmail(km, cutoff_time)
      end)
      time
    end
    
    avg_full = Enum.sum(full_times) / length(full_times)
    avg_partial = Enum.sum(partial_times) / length(partial_times)
    
    Logger.info("""
    Full vs Partial killmail processing (100 runs each):
      Full killmail avg: #{Float.round(avg_full / 1000, 2)}ms
      Partial killmail avg: #{Float.round(avg_partial / 1000, 2)}ms
      Difference: #{Float.round((avg_full - avg_partial) / 1000, 2)}ms
    """)
  end

  defp benchmark_memory_usage do
    Logger.info("\n=== Memory Usage Benchmark ===")
    
    cutoff_time = DateTime.utc_now() |> DateTime.add(-24 * 60 * 60, :second)
    
    # Get initial memory
    :erlang.garbage_collect()
    initial_memory = :erlang.memory(:total)
    
    # Process a batch of killmails
    killmails = Enum.map(1..1000, fn i ->
      TestFactory.build(:full_killmail, killmail_id: i)
    end)
    
    UnifiedProcessor.process_batch(killmails, cutoff_time)
    
    # Get final memory
    :erlang.garbage_collect()
    final_memory = :erlang.memory(:total)
    
    memory_used = final_memory - initial_memory
    memory_per_killmail = memory_used / 1000
    
    # Check ETS memory
    ets_info = :ets.info(KillmailStore.table_name())
    ets_memory = Keyword.get(ets_info, :memory, 0) * :erlang.system_info(:wordsize)
    
    Logger.info("""
    Memory usage for 1000 killmails:
      Total memory used: #{Float.round(memory_used / 1024 / 1024, 2)} MB
      Memory per killmail: #{Float.round(memory_per_killmail / 1024, 2)} KB
      ETS table memory: #{Float.round(ets_memory / 1024 / 1024, 2)} MB
    """)
  end
end

# Run the benchmarks
WandererKills.Benchmarks.UnifiedProcessorBenchmark.run()