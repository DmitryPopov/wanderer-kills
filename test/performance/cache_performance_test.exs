defmodule WandererKills.Performance.CachePerformanceTest do
  use ExUnit.Case, async: false
  alias WandererKills.Core.Cache

  @tag :performance
  test "cache operations performance" do
    # Cache is already initialized by the application

    # Test cache write performance
    write_times =
      for i <- 1..1000 do
        start = System.monotonic_time(:microsecond)
        Cache.put(:killmails, i, %{id: i, data: "test"})
        System.monotonic_time(:microsecond) - start
      end

    avg_write = Enum.sum(write_times) / length(write_times)
    IO.puts("Average cache write time: #{avg_write} μs")

    # Test cache read performance
    read_times =
      for i <- 1..1000 do
        start = System.monotonic_time(:microsecond)
        Cache.get(:killmails, i)
        System.monotonic_time(:microsecond) - start
      end

    avg_read = Enum.sum(read_times) / length(read_times)
    IO.puts("Average cache read time: #{avg_read} μs")

    # Test batch operations
    batch_start = System.monotonic_time(:microsecond)
    results = Cache.get_many(:killmails, Enum.to_list(1..100))
    batch_time = System.monotonic_time(:microsecond) - batch_start
    IO.puts("Batch read 100 items: #{batch_time} μs (#{batch_time / 100} μs per item)")

    assert map_size(results) == 100
    # Should be under 100 microseconds
    assert avg_write < 100
    # Should be under 50 microseconds
    assert avg_read < 50
  end

  # Disabled due to race conditions with cleanup worker in test suite
  # This test works when run in isolation but fails when run with the full suite
  # due to timing issues with the cleanup worker running every 100ms in test mode
  #
  # @tag :performance
  # test "storage operations with event streaming" do
  #   # Storage is already initialized by the application
  #
  #   # Test killmail storage with event streaming
  #   store_times =
  #     for i <- 1..1000 do
  #       killmail = %{
  #         "killmail_id" => i,
  #         "killmail_time" => DateTime.utc_now() |> DateTime.to_iso8601(),
  #         "solar_system_id" => 30_000_142,
  #         "victim" => %{"character_id" => 123}
  #       }
  #
  #       start = System.monotonic_time(:microsecond)
  #       KillmailStore.put(i, 30_000_142, killmail)
  #       System.monotonic_time(:microsecond) - start
  #     end
  #
  #   avg_store = Enum.sum(store_times) / length(store_times)
  #   IO.puts("Average storage write time: #{avg_store} μs")
  #
  #   # Test system killmail retrieval
  #   retrieve_start = System.monotonic_time(:microsecond)
  #   killmails = KillmailStore.list_by_system(30_000_142)
  #   retrieve_time = System.monotonic_time(:microsecond) - retrieve_start
  #   IO.puts("Retrieved #{length(killmails)} killmails in #{retrieve_time} μs")
  #
  #   # Test event streaming capability
  #   if Application.get_env(:wanderer_kills, :storage)[:enable_event_streaming] do
  #     # Event streaming is working if we can store and retrieve killmails
  #     IO.puts("Event streaming enabled - storage operations are event-enabled")
  #   end
  #
  #   assert length(killmails) == 1000
  #   # Should be under 200 microseconds including event generation
  #   assert avg_store < 200
  # end
end
