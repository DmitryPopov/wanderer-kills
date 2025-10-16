defmodule WandererKills.Benchmarks.HttpClientBenchmark do
  @moduledoc """
  Benchmarks for HTTP client infrastructure measuring:
  - Request/response time with unified HTTP client
  - Rate limiting performance with SmartRateLimiter
  - Error handling and retry logic performance
  - Request coalescing effectiveness

  Run with: mix run bench/http_client_benchmark.exs
  """

  alias WandererKills.Http.Client
  alias WandererKills.Ingest.SmartRateLimiter
  alias WandererKills.Ingest.RequestCoalescer
  alias WandererKills.Ingest.ESI
  alias WandererKills.Core.Support.Error

  require Logger

  def run do
    Logger.info("Starting HTTP Client Infrastructure Benchmarks...")
    
    # Ensure application is started
    Application.ensure_all_started(:wanderer_kills)
    
    # Run benchmarks
    benchmark_http_client()
    benchmark_smart_rate_limiter()
    benchmark_request_coalescing()
    benchmark_error_handling()
    benchmark_concurrent_requests()
    
    Logger.info("HTTP Client benchmarks completed!")
  end

  defp benchmark_http_client do
    Logger.info("\n=== HTTP Client Performance Benchmark ===")
    
    # We'll use httpbin.org for testing (a public HTTP testing service)
    base_url = "https://httpbin.org"
    
    # Test different request types
    request_configs = [
      %{method: :get, path: "/get", description: "Simple GET"},
      %{method: :get, path: "/delay/0", description: "GET with minimal delay"},
      %{method: :post, path: "/post", body: %{test: "data"}, description: "POST with JSON body"},
      %{method: :get, path: "/status/200", description: "Status check"}
    ]
    
    Enum.each(request_configs, fn config ->
      times = for _ <- 1..50 do
        {time, _result} = :timer.tc(fn ->
          case config.method do
            :get -> Client.get(base_url <> config.path, [], [])
            :post -> Client.post(base_url <> config.path, Map.get(config, :body), [], [])
          end
        end)
        time
      end
      
      avg_time = Enum.sum(times) / length(times)
      min_time = Enum.min(times)
      max_time = Enum.max(times)
      
      Logger.info("""
      #{config.description}:
        Average: #{Float.round(avg_time / 1000, 2)}ms
        Min: #{Float.round(min_time / 1000, 2)}ms
        Max: #{Float.round(max_time / 1000, 2)}ms
      """)
    end)
  end

  defp benchmark_smart_rate_limiter do
    Logger.info("\n=== Smart Rate Limiter Benchmark ===")
    
    # Create a rate limiter instance
    {:ok, limiter} = SmartRateLimiter.start_link(
      name: :benchmark_limiter,
      max_tokens: 150,
      refill_rate: 75
    )
    
    # Benchmark token acquisition
    acquisition_times = for _ <- 1..1000 do
      {time, _} = :timer.tc(fn ->
        SmartRateLimiter.acquire(:benchmark_limiter)
      end)
      time
    end
    
    avg_acquire = Enum.sum(acquisition_times) / length(acquisition_times)
    
    Logger.info("""
    Token acquisition (1000 operations):
      Average time: #{Float.round(avg_acquire, 2)} μs
      Throughput: #{Float.round(1_000_000 / avg_acquire, 1)} ops/sec
    """)
    
    # Benchmark rate limiting under load
    Logger.info("\nTesting rate limiting under concurrent load...")
    
    # Spawn concurrent processes trying to acquire tokens
    task_count = 100
    tokens_per_task = 10
    
    {concurrent_time, results} = :timer.tc(fn ->
      tasks = for _ <- 1..task_count do
        Task.async(fn ->
          for _ <- 1..tokens_per_task do
            SmartRateLimiter.acquire(:benchmark_limiter)
          end
        end)
      end
      
      Task.await_many(tasks, 30_000)
    end)
    
    Logger.info("""
    Concurrent rate limiting (#{task_count} tasks, #{tokens_per_task} tokens each):
      Total time: #{Float.round(concurrent_time / 1_000_000, 2)}s
      Total operations: #{task_count * tokens_per_task}
      Throughput: #{Float.round(task_count * tokens_per_task / (concurrent_time / 1_000_000), 1)} ops/sec
    """)
    
    # Test circuit breaker behavior
    Logger.info("\nTesting circuit breaker behavior...")
    
    # Simulate failures to trigger circuit breaker
    for _ <- 1..15 do
      SmartRateLimiter.report_failure(:benchmark_limiter)
    end
    
    {cb_time, cb_result} = :timer.tc(fn ->
      SmartRateLimiter.acquire(:benchmark_limiter)
    end)
    
    Logger.info("""
    Circuit breaker response:
      State: #{if cb_result == {:error, :circuit_open}, do: "OPEN (as expected)", else: "CLOSED"}
      Response time: #{Float.round(cb_time, 2)} μs
    """)
    
    # Cleanup
    GenServer.stop(limiter)
  end

  defp benchmark_request_coalescing do
    Logger.info("\n=== Request Coalescing Benchmark ===")
    
    # Start request coalescer
    {:ok, coalescer} = RequestCoalescer.start_link(name: :benchmark_coalescer)
    
    # Define a mock request function with artificial delay
    request_fn = fn key ->
      Process.sleep(50)  # Simulate API call
      {:ok, "data_for_#{key}"}
    end
    
    # Test single request
    {single_time, _} = :timer.tc(fn ->
      RequestCoalescer.coalesce(:benchmark_coalescer, "test_key", request_fn)
    end)
    
    Logger.info("""
    Single request:
      Time: #{Float.round(single_time / 1000, 2)}ms
    """)
    
    # Test coalesced requests (multiple processes requesting same key)
    Logger.info("\nTesting request coalescing effectiveness...")
    
    # Spawn 20 concurrent requests for the same key
    {coalesced_time, results} = :timer.tc(fn ->
      tasks = for _ <- 1..20 do
        Task.async(fn ->
          RequestCoalescer.coalesce(:benchmark_coalescer, "shared_key", request_fn)
        end)
      end
      
      Task.await_many(tasks)
    end)
    
    unique_results = Enum.uniq(results)
    
    Logger.info("""
    Coalesced requests (20 concurrent for same key):
      Total time: #{Float.round(coalesced_time / 1000, 2)}ms
      Expected time without coalescing: ~#{Float.round(20 * 50, 0)}ms
      Time saved: ~#{Float.round((20 * 50) - (coalesced_time / 1000), 0)}ms
      Unique results: #{length(unique_results)} (should be 1)
      Effectiveness: #{Float.round((1 - (coalesced_time / 1000) / (20 * 50)) * 100, 1)}% reduction
    """)
    
    # Test with different keys (no coalescing benefit)
    {different_time, _} = :timer.tc(fn ->
      tasks = for i <- 1..10 do
        Task.async(fn ->
          RequestCoalescer.coalesce(:benchmark_coalescer, "key_#{i}", request_fn)
        end)
      end
      
      Task.await_many(tasks)
    end)
    
    Logger.info("""
    Different keys (10 concurrent, no coalescing):
      Total time: #{Float.round(different_time / 1000, 2)}ms
      Avg per request: #{Float.round(different_time / 1000 / 10, 2)}ms
    """)
    
    # Cleanup
    GenServer.stop(coalescer)
  end

  defp benchmark_error_handling do
    Logger.info("\n=== Error Handling & Retry Logic Benchmark ===")
    
    # Create a mock HTTP client that fails predictably
    failing_request = fn attempt ->
      if attempt < 3 do
        {:error, %{reason: :timeout}}
      else
        {:ok, %{status: 200, body: "success"}}
      end
    end
    
    # Benchmark retry logic
    {retry_time, _} = :timer.tc(fn ->
      attempt = :persistent_term.get(:attempt_counter, 0)
      
      result = Enum.reduce_while(1..5, {:error, nil}, fn i, _acc ->
        :persistent_term.put(:attempt_counter, i)
        case failing_request.(i) do
          {:ok, _} = success -> {:halt, success}
          error -> 
            if i < 5 do
              Process.sleep(100 * i)  # Exponential backoff
              {:cont, error}
            else
              {:halt, error}
            end
        end
      end)
      
      :persistent_term.erase(:attempt_counter)
      result
    end)
    
    Logger.info("""
    Retry logic (3 failures, then success):
      Total time: #{Float.round(retry_time / 1000, 2)}ms
      Expected backoff time: ~#{100 + 200}ms
      Overhead: #{Float.round((retry_time / 1000) - 300, 2)}ms
    """)
    
    # Benchmark error parsing and wrapping
    error_types = [
      {:timeout, "Request timeout"},
      {:connection_refused, "Connection refused"},
      {{:bad_response, 500}, "Internal server error"},
      {:invalid_json, "Invalid JSON response"}
    ]
    
    parsing_times = for {error_type, message} <- error_types do
      {time, _} = :timer.tc(fn ->
        for _ <- 1..1000 do
          Error.http_error(error_type, message, true)
        end
      end)
      {error_type, time / 1000}
    end
    
    Logger.info("\nError parsing performance (1000 operations each):")
    Enum.each(parsing_times, fn {error_type, avg_time} ->
      Logger.info("  #{inspect(error_type)}: #{Float.round(avg_time, 2)} μs")
    end)
  end

  defp benchmark_concurrent_requests do
    Logger.info("\n=== Concurrent Request Performance ===")
    
    # Test various concurrency levels
    concurrency_levels = [10, 50, 100, 200]
    
    Enum.each(concurrency_levels, fn level ->
      # Use httpbin.org delay endpoint to simulate realistic API calls
      {time, results} = :timer.tc(fn ->
        tasks = for i <- 1..level do
          Task.async(fn ->
            # Vary the endpoints to avoid rate limiting
            endpoint = case rem(i, 4) do
              0 -> "/get"
              1 -> "/status/200"
              2 -> "/headers"
              3 -> "/user-agent"
            end
            
            Client.get("https://httpbin.org#{endpoint}", [], [])
          end)
        end
        
        Task.await_many(tasks, 30_000)
      end)
      
      successful = Enum.count(results, fn
        {:ok, _} -> true
        _ -> false
      end)
      
      Logger.info("""
      Concurrent requests (#{level}):
        Total time: #{Float.round(time / 1_000_000, 2)}s
        Successful: #{successful}/#{level}
        Avg per request: #{Float.round(time / 1000 / level, 2)}ms
        Throughput: #{Float.round(level / (time / 1_000_000), 1)} req/sec
      """)
    end)
    
    # Test connection pooling effectiveness
    Logger.info("\nTesting connection pooling...")
    
    # Make repeated requests to same host
    {pooled_time, _} = :timer.tc(fn ->
      for _ <- 1..50 do
        Client.get("https://httpbin.org/get", [], [])
      end
    end)
    
    avg_pooled = pooled_time / 50
    
    Logger.info("""
    Connection pooling (50 sequential requests):
      Total time: #{Float.round(pooled_time / 1000, 2)}ms
      Avg per request: #{Float.round(avg_pooled / 1000, 2)}ms
    """)
  end
end

# Run the benchmarks
WandererKills.Benchmarks.HttpClientBenchmark.run()