defmodule WandererKills.CharacterSubscriptionIntegrationTest do
  @moduledoc """
  Integration tests for character-based subscription functionality.

  Tests the full flow from subscription creation through killmail filtering
  to ensure character-based subscriptions work correctly across all components.
  """

  use ExUnit.Case, async: false

  alias WandererKills.Domain.Killmail
  alias WandererKills.Subs.SimpleSubscriptionManager, as: SubscriptionManager
  alias WandererKills.Subs.{CharacterIndex, SystemIndex}

  setup do
    # Ensure TaskSupervisor is started
    case Process.whereis(WandererKills.TaskSupervisor) do
      nil -> start_supervised!({Task.Supervisor, name: WandererKills.TaskSupervisor})
      _pid -> :ok
    end

    # Ensure SimpleSubscriptionManager is started
    case Process.whereis(SubscriptionManager) do
      nil -> start_supervised!(SubscriptionManager)
      _pid -> :ok
    end

    # Clear any existing subscriptions
    SubscriptionManager.clear_all_subscriptions()

    # Clear indexes (they are initialized by SimpleSubscriptionManager)
    CharacterIndex.clear()
    SystemIndex.clear()

    :ok
  end

  # Helper to create test killmail structs
  defp create_test_killmail(attrs) do
    base_attrs = %{
      "killmail_id" => attrs["killmail_id"] || 123_456_789,
      "kill_time" => attrs["kill_time"] || "2024-01-01T12:00:00Z",
      "system_id" => attrs["solar_system_id"] || attrs["system_id"] || 30_000_142,
      "victim" => ensure_valid_victim(attrs["victim"]),
      "attackers" => ensure_valid_attackers(attrs["attackers"] || [])
    }

    {:ok, killmail} = Killmail.new(base_attrs)
    killmail
  end

  defp ensure_valid_victim(victim) when is_map(victim) do
    victim
    |> Map.put_new("damage_taken", 100)
  end

  defp ensure_valid_attackers(attackers) when is_list(attackers) do
    Enum.map(attackers, fn attacker ->
      attacker
      |> Map.put_new("damage_done", 100)
      |> Map.put_new("final_blow", false)
    end)
  end

  describe "character-based webhook subscriptions" do
    test "filters killmails correctly for character subscriptions" do
      # Create a subscription for specific characters
      {:ok, subscription_id} =
        SubscriptionManager.add_subscription(%{
          "subscriber_id" => "test_user_#{System.unique_integer([:positive])}",
          "system_ids" => [],
          "character_ids" => [95_465_499, 90_379_338],
          "callback_url" => "https://example.com/webhook"
        })

      assert is_binary(subscription_id)

      # Create test killmails
      killmail_with_victim_match =
        create_test_killmail(%{
          "killmail_id" => 123_456,
          "solar_system_id" => 30_000_999,
          "kill_time" => "2024-01-01T12:00:00Z",
          "victim" => %{
            # Matches subscription
            "character_id" => 95_465_499,
            "corporation_id" => 98_000_001,
            "ship_type_id" => 587
          },
          "attackers" => [
            %{"character_id" => 111_111, "ship_type_id" => 621}
          ]
        })

      killmail_with_attacker_match =
        create_test_killmail(%{
          "killmail_id" => 123_457,
          "solar_system_id" => 30_000_888,
          "kill_time" => "2024-01-01T12:01:00Z",
          "victim" => %{
            "character_id" => 222_222,
            "corporation_id" => 98_000_002,
            "ship_type_id" => 590
          },
          "attackers" => [
            %{"character_id" => 333_333, "ship_type_id" => 622},
            # Matches subscription
            %{"character_id" => 90_379_338, "ship_type_id" => 623}
          ]
        })

      killmail_no_match =
        create_test_killmail(%{
          "killmail_id" => 123_458,
          "solar_system_id" => 30_000_777,
          "kill_time" => "2024-01-01T12:02:00Z",
          "victim" => %{
            "character_id" => 444_444,
            "corporation_id" => 98_000_003,
            "ship_type_id" => 591
          },
          "attackers" => [
            %{"character_id" => 555_555, "ship_type_id" => 624}
          ]
        })

      # Verify subscription matching
      subscriptions = SubscriptionManager.list_subscriptions()
      assert length(subscriptions) == 1

      [sub] = subscriptions
      # Character IDs are sorted in the subscription
      assert Enum.sort(sub.character_ids) == Enum.sort([90_379_338, 95_465_499])

      # Verify the Filter module correctly identifies matching killmails
      alias WandererKills.Subs.Filter

      assert Filter.matches_subscription?(killmail_with_victim_match, sub)
      assert Filter.matches_subscription?(killmail_with_attacker_match, sub)
      refute Filter.matches_subscription?(killmail_no_match, sub)
    end

    test "handles mixed system and character subscriptions" do
      # Create a subscription with both systems and characters
      {:ok, _subscription_id} =
        SubscriptionManager.add_subscription(%{
          "subscriber_id" => "test_user_#{System.unique_integer([:positive])}",
          "system_ids" => [30_000_142],
          "character_ids" => [95_465_499],
          "callback_url" => "https://example.com/webhook"
        })

      # Killmail matching by system only
      killmail_system_match =
        create_test_killmail(%{
          "killmail_id" => 200_001,
          # Matches system
          "solar_system_id" => 30_000_142,
          "kill_time" => "2024-01-01T12:00:00Z",
          "victim" => %{
            # Does not match character
            "character_id" => 999_999,
            "corporation_id" => 98_000_001,
            "ship_type_id" => 587
          },
          "attackers" => []
        })

      # Killmail matching by character only
      killmail_character_match =
        create_test_killmail(%{
          "killmail_id" => 200_002,
          # Does not match system
          "solar_system_id" => 30_000_999,
          "kill_time" => "2024-01-01T12:01:00Z",
          "victim" => %{
            # Matches character
            "character_id" => 95_465_499,
            "corporation_id" => 98_000_002,
            "ship_type_id" => 590
          },
          "attackers" => []
        })

      # Killmail matching both
      killmail_both_match =
        create_test_killmail(%{
          "killmail_id" => 200_003,
          # Matches system
          "solar_system_id" => 30_000_142,
          "kill_time" => "2024-01-01T12:02:00Z",
          "victim" => %{
            # Matches character
            "character_id" => 95_465_499,
            "corporation_id" => 98_000_003,
            "ship_type_id" => 591
          },
          "attackers" => []
        })

      # Killmail matching neither
      killmail_no_match =
        create_test_killmail(%{
          "killmail_id" => 200_004,
          # Does not match system
          "solar_system_id" => 30_000_888,
          "kill_time" => "2024-01-01T12:03:00Z",
          "victim" => %{
            # Does not match character
            "character_id" => 888_888,
            "corporation_id" => 98_000_004,
            "ship_type_id" => 592
          },
          "attackers" => []
        })

      # Verify filtering
      [sub] = SubscriptionManager.list_subscriptions()
      alias WandererKills.Subs.Filter

      assert Filter.matches_subscription?(killmail_system_match, sub)
      assert Filter.matches_subscription?(killmail_character_match, sub)
      assert Filter.matches_subscription?(killmail_both_match, sub)
      refute Filter.matches_subscription?(killmail_no_match, sub)
    end
  end

  describe "performance with large character lists" do
    test "efficiently handles subscriptions with many characters" do
      # Create a subscription with 1000 characters
      character_ids = Enum.to_list(1..1000)

      {:ok, _subscription_id} =
        SubscriptionManager.add_subscription(%{
          "subscriber_id" => "test_user_#{System.unique_integer([:positive])}",
          "system_ids" => [],
          "character_ids" => character_ids,
          "callback_url" => "https://example.com/webhook"
        })

      # Create a killmail with many attackers, with one matching character
      attackers_with_match =
        Enum.map(1001..2000, fn id ->
          if id == 1500 do
            # This character is in our subscription (character id 500)
            %{"character_id" => 500, "ship_type_id" => 621}
          else
            %{"character_id" => id, "ship_type_id" => 621}
          end
        end)

      killmail_with_match =
        create_test_killmail(%{
          "killmail_id" => 300_001,
          "solar_system_id" => 30_000_142,
          "kill_time" => "2024-01-01T12:00:00Z",
          "victim" => %{
            "character_id" => 9_999_999,
            "corporation_id" => 98_000_001,
            "ship_type_id" => 587
          },
          "attackers" => attackers_with_match
        })

      [sub] = SubscriptionManager.list_subscriptions()
      alias WandererKills.Subs.Filter

      # Time the filtering operation
      {time, result} =
        :timer.tc(fn ->
          Filter.matches_subscription?(killmail_with_match, sub)
        end)

      assert result == true

      # Performance assertion only runs when PERF_TEST env var is set
      if System.get_env("PERF_TEST") do
        # Should complete in under 50ms even with 1000 characters and 1000 attackers
        assert time < 50_000
      end
    end
  end
end
