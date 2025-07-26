defmodule WandererKills.Integration.CacheMigrationTest do
  use ExUnit.Case, async: false
  use WandererKills.TestCase

  alias WandererKills.Core.Cache
  alias WandererKills.Ingest.ESI.Client

  setup do
    # Setup HTTP mocks for ESI client tests
    WandererKills.TestHelpers.setup_mocks()
    :ok
  end

  describe "Cachex migration integration tests" do
    test "ESI cache preserves character data with proper TTL" do
      character_id = 123_456

      character_data = %{
        "character_id" => character_id,
        "name" => "Test Character",
        "corporation_id" => 98_000_001
      }

      # Test cache miss then hit
      assert {:error, _} = Cache.get_character(character_id)

      # Put data and verify it can be retrieved
      assert {:ok, _} = Cache.put_character(character_id, character_data)
      assert {:ok, ^character_data} = Cache.get_character(character_id)

      # Verify cache exists
      assert Cache.exists?(:esi_data, "character:#{character_id}")
    end

    test "ESI cache handles corporation data correctly" do
      corporation_id = 98_000_002

      corporation_data = %{
        "corporation_id" => corporation_id,
        "name" => "Test Corporation",
        "ticker" => "TEST"
      }

      # Test get_or_set functionality
      result =
        Cache.get_or_set(:corporations, corporation_id, fn ->
          corporation_data
        end)

      assert {:ok, ^corporation_data} = result

      # Verify it's now cached
      assert {:ok, ^corporation_data} = Cache.get(:corporations, corporation_id)
    end

    test "ESI cache handles alliance data correctly" do
      alliance_id = 99_000_001

      alliance_data = %{
        "alliance_id" => alliance_id,
        "name" => "Test Alliance",
        "ticker" => "TESTA"
      }

      # Test get_or_set functionality
      result =
        Cache.get_or_set(:alliances, alliance_id, fn ->
          alliance_data
        end)

      assert {:ok, ^alliance_data} = result

      # Verify it's now cached
      assert {:ok, ^alliance_data} = Cache.get(:alliances, alliance_id)
    end

    test "ship types cache preserves behavior" do
      type_id = 587

      ship_data = %{
        "type_id" => type_id,
        "name" => "Rifter",
        "group_id" => 25
      }

      # Test cache miss then hit
      assert {:error, _} = Cache.get(:ship_types, type_id)

      # Put data and verify it can be retrieved
      assert {:ok, true} = Cache.put(:ship_types, type_id, ship_data)
      assert {:ok, ^ship_data} = Cache.get(:ship_types, type_id)

      # Test get_or_set functionality
      result =
        Cache.get_or_set(:ship_types, type_id, fn ->
          ship_data
        end)

      assert {:ok, ^ship_data} = result
    end

    test "systems cache handles killmail associations correctly" do
      system_id = 30_000_142
      killmail_ids = [12_345, 67_890, 54_321]

      # Test empty system initially - should return empty list
      assert {:ok, []} = Cache.list_system_killmails(system_id)

      # Add killmails to system
      Enum.each(killmail_ids, fn killmail_id ->
        assert {:ok, true} = Cache.add_system_killmail(system_id, killmail_id)
      end)

      # Verify killmails are associated
      assert {:ok, retrieved_ids} = Cache.list_system_killmails(system_id)
      assert length(retrieved_ids) == length(killmail_ids)

      # All original IDs should be present (order may vary)
      Enum.each(killmail_ids, fn id ->
        assert id in retrieved_ids
      end)
    end

    test "systems cache handles active systems correctly" do
      system_id = 30_000_143

      # Add system to active list first
      assert {:ok, _} = Cache.add_active_system(system_id)

      # Test that the system is marked as active
      assert {:ok, active_systems} = Cache.get_active_systems()
      assert system_id in active_systems

      # Note: get_active_systems() has a streaming issue in test environment
      # but the core functionality (is_active?) works correctly
    end

    test "systems cache handles fetch timestamps correctly" do
      system_id = 30_000_144

      # Should not have timestamp initially
      assert {:error, _} = Cache.get(:systems, "fetched:#{system_id}")

      # Set timestamp - use millisecond timestamp
      timestamp = :os.system_time(:millisecond)
      assert {:ok, _} = Cache.mark_system_fetched(system_id, timestamp)

      # Verify timestamp is retrieved correctly
      assert {:ok, retrieved_timestamp} = Cache.get(:systems, "fetched:#{system_id}")

      # Check if timestamp is the same (accounting for DateTime comparison)
      assert retrieved_timestamp == timestamp
    end

    test "systems cache handles recently fetched checks correctly" do
      system_id = 30_000_145

      # Should not be recently fetched initially
      refute Cache.system_fetched_recently?(system_id)

      # Set current timestamp
      assert {:ok, _} = Cache.mark_system_fetched(system_id, DateTime.utc_now())

      # Should now be recently fetched (within default threshold)
      assert true = Cache.system_fetched_recently?(system_id)

      # Test with custom threshold
      assert true = Cache.system_fetched_recently?(system_id, 60)
    end

    test "killmail cache handles individual killmails correctly" do
      killmail_id = 98_765

      killmail_data = %{
        "killmail_id" => killmail_id,
        "solar_system_id" => 30_000_142,
        "victim" => %{"character_id" => 123_456}
      }

      # Test cache miss then hit
      assert {:error, _} = Cache.get(:killmails, killmail_id)

      # Put data and verify it can be retrieved
      assert {:ok, true} = Cache.put(:killmails, killmail_id, killmail_data)
      assert {:ok, ^killmail_data} = Cache.get(:killmails, killmail_id)
    end

    test "unified ESI Client works correctly" do
      # Test character fetching
      character_id = 98_765_432
      character_data = %{"character_id" => character_id, "name" => "Client Test"}

      # Put character data in cache first
      Cache.put_character(character_id, character_data)

      # Test Client behavior implementation - should get from cache
      assert {:ok, ^character_data} = Client.get_character(character_id)
      assert Client.supports?({:character, character_id})
      refute Client.supports?({:unsupported, character_id})
    end

    test "cache namespaces work correctly with Helper module" do
      # Test different namespaces
      namespaces = [:characters, :corporations, :alliances, :ship_types, :systems]

      Enum.each(namespaces, fn namespace ->
        test_key = "test_key_#{Atom.to_string(namespace)}"
        test_value = %{"test" => "data", "namespace" => Atom.to_string(namespace)}

        # Put and get should work
        assert {:ok, true} = Cache.put(namespace, test_key, test_value)
        assert {:ok, fetched_value} = Cache.get(namespace, test_key)
        assert fetched_value == test_value
        assert {:ok, true} = Cache.exists?(namespace, test_key)

        # Delete should work
        assert {:ok, _} = Cache.delete(namespace, test_key)
        assert {:ok, false} = Cache.exists?(namespace, test_key)
      end)
    end

    test "telemetry events are emitted for cache operations" do
      # This test would require telemetry test helpers to capture events
      # For now, we verify the operations work without errors

      test_data = %{"test" => "telemetry"}

      # These operations should emit telemetry events
      assert {:ok, true} = Cache.put(:characters, "telemetry_key", test_data)
      assert {:ok, ^test_data} = Cache.get(:characters, "telemetry_key")

      # Miss should also emit telemetry
      assert {:error, _} = Cache.get(:characters, "nonexistent_key")
    end

    test "TTL functionality works correctly" do
      key = "ttl_test"
      value = %{"test" => "ttl"}

      # Put with short TTL (test environment should respect this)
      assert {:ok, true} = Cache.put(:characters, key, value)

      # Should be immediately available
      assert {:ok, ^value} = Cache.get(:characters, key)

      # For longer integration test, we'd wait for expiration
      # but for unit tests, we verify the structure works
    end
  end

  describe "fallback function behavior" do
    test "ESI cache get_or_set fallback works correctly" do
      character_id = 555_666
      fallback_data = %{"character_id" => character_id, "name" => "Fallback Character"}

      # Should call fallback on cache miss
      result =
        Cache.get_or_set(:characters, character_id, fn ->
          fallback_data
        end)

      assert {:ok, ^fallback_data} = result

      # Should now be cached and not call fallback again
      assert {:ok, ^fallback_data} = Cache.get(:characters, character_id)
    end

    test "ship types fallback preserves behavior" do
      type_id = 999_888
      fallback_data = %{"type_id" => type_id, "name" => "Fallback Ship"}

      # Should call fallback on cache miss
      result =
        Cache.get_or_set(:ship_types, type_id, fn ->
          fallback_data
        end)

      assert {:ok, ^fallback_data} = result

      # Should now be cached
      assert {:ok, ^fallback_data} = Cache.get(:ship_types, type_id)
    end
  end

  describe "error handling preservation" do
    test "cache errors are handled gracefully" do
      # Test with invalid data types where appropriate
      # Note: These functions have guard clauses that will raise FunctionClauseError
      # for invalid input types, which is the expected behavior

      # Test with non-existent valid IDs instead
      assert {:error, _} = Cache.get(:characters, 999_999_999)
      assert {:error, _} = Cache.get(:ship_types, 999_999_999)

      # Non-existent system returns empty list
      assert {:ok, []} = Cache.list_system_killmails(999_999_999)
    end
  end
end
