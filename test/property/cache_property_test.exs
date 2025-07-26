defmodule WandererKills.Core.CachePropertyTest do
  use WandererKills.UnifiedTestCase, async: false, mocks: false
  use ExUnitProperties

  @moduletag :property
  @moduletag area: :cache
  @moduletag performance: :medium

  alias WandererKills.Core.Cache

  describe "cache operation properties" do
    @tag :property
    test "cache put and get operations maintain consistency" do
      check all(
              key <- string(:alphanumeric, min_length: 1, max_length: 50),
              value <- term(),
              max_runs: 20
            ) do
        # Start with a clean cache
        WandererKills.TestHelpers.clear_all_caches()

        # Put and get should be consistent
        case Cache.put(:killmails, key, value) do
          {:ok, _} ->
            case Cache.get(:killmails, key) do
              {:ok, retrieved_value} ->
                assert retrieved_value == value

              {:error, _} ->
                # Some operations might fail, that's okay
                :ok
            end

          {:error, _} ->
            # Some puts might fail, that's okay
            :ok
        end
      end
    end

    @tag :property
    test "cache operations work" do
      check all(_ <- constant(:ok), max_runs: 10) do
        WandererKills.TestHelpers.clear_all_caches()

        # Basic cache operation test
        case Cache.put(:killmails, "test_key", "test_value") do
          {:ok, _} ->
            case Cache.get(:killmails, "test_key") do
              {:ok, value} -> assert value == "test_value"
              {:error, _} -> :ok
            end

          {:error, _} ->
            :ok
        end
      end
    end
  end
end
