defmodule WandererKills.CacheTest do
  use WandererKills.TestCase

  alias WandererKills.Core.Cache
  alias WandererKills.TestHelpers

  # Test setup is handled by UnifiedTestCase

  describe "killmail operations" do
    test "can store and retrieve a killmail" do
      killmail = TestHelpers.create_test_killmail(123)
      assert {:ok, true} = Cache.put(:killmails, 123, killmail)
      assert {:ok, ^killmail} = Cache.get(:killmails, 123)
    end

    test "returns error for non-existent killmail" do
      assert {:error, %{type: :not_found}} = Cache.get(:killmails, 999)
    end

    test "can delete a killmail" do
      killmail = TestHelpers.create_test_killmail(123)
      assert {:ok, true} = Cache.put(:killmails, 123, killmail)
      assert {:ok, true} = Cache.delete(:killmails, 123)

      assert {:error, %{type: :not_found}} = Cache.get(:killmails, 123)
    end
  end

  describe "system operations" do
    test "can store and retrieve system killmails" do
      killmail1 = TestHelpers.create_test_killmail(123)
      killmail2 = TestHelpers.create_test_killmail(456)

      assert {:ok, true} = Cache.put(:killmails, 123, killmail1)
      assert {:ok, true} = Cache.put(:killmails, 456, killmail2)
      assert {:ok, true} = Cache.add_system_killmail(789, 123)
      assert {:ok, true} = Cache.add_system_killmail(789, 456)
      assert {:ok, killmail_ids} = Cache.list_system_killmails(789)
      assert 123 in killmail_ids
      assert 456 in killmail_ids
    end

    test "returns empty list for system with no killmails" do
      # For a system with no killmails, we get an empty list in a tuple
      assert {:ok, []} = Cache.list_system_killmails(999)
    end

    test "can manage system killmails" do
      killmail = TestHelpers.create_test_killmail(123)
      assert {:ok, true} = Cache.put(:killmails, 123, killmail)
      assert {:ok, true} = Cache.add_system_killmail(789, 123)
      assert {:ok, killmail_ids} = Cache.list_system_killmails(789)
      assert 123 in killmail_ids
      assert {:ok, killmail_ids} = Cache.list_system_killmails(789)
      assert 123 in killmail_ids
    end
  end

  describe "system timestamp operations" do
    test "can mark system as fetched and check if recently fetched" do
      timestamp = :os.system_time(:millisecond)
      assert {:ok, true} = Cache.mark_system_fetched(789, timestamp)
      assert Cache.system_fetched_recently?(789)
    end

    test "returns false for system with no fetch timestamp" do
      refute Cache.system_fetched_recently?(999)
    end

    test "returns false for system fetched long ago" do
      # 2 hours ago
      old_timestamp = DateTime.add(DateTime.utc_now(), -7200, :second)
      assert {:ok, true} = Cache.mark_system_fetched(789, old_timestamp)
      # Check within 1 hour
      refute Cache.system_fetched_recently?(789, 3600)
    end
  end

  describe "active systems operations" do
    test "can manage active systems list" do
      assert {:ok, []} = Cache.get_active_systems()
      assert {:ok, true} = Cache.add_active_system(789)
      assert {:ok, true} = Cache.add_active_system(456)
      assert {:ok, systems} = Cache.get_active_systems()
      assert 789 in systems
      assert 456 in systems
    end
  end
end
