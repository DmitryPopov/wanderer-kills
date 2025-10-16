defmodule WandererKills.Subs.FilterTest do
  use ExUnit.Case, async: true

  alias WandererKills.Domain.Killmail
  alias WandererKills.Subs.Filter

  # Helper to create a valid Killmail struct from test data
  defp create_test_killmail(attrs) do
    base_attrs = %{
      "killmail_id" => attrs["killmail_id"] || 123_456_789,
      "kill_time" => attrs["kill_time"] || "2024-01-01T12:00:00Z",
      "system_id" => attrs["solar_system_id"] || attrs["system_id"] || 30_000_142,
      "victim" => attrs["victim"] || %{"character_id" => 999, "damage_taken" => 100},
      "attackers" => attrs["attackers"] || []
    }

    {:ok, killmail} = Killmail.new(base_attrs)
    killmail
  end

  describe "matches_subscription?/2" do
    test "matches when system_id matches" do
      subscription = %{
        "system_ids" => [30_000_142, 30_000_143],
        "character_ids" => []
      }

      killmail =
        create_test_killmail(%{
          "solar_system_id" => 30_000_142,
          "victim" => %{"character_id" => 999, "damage_taken" => 100}
        })

      assert Filter.matches_subscription?(killmail, subscription)
    end

    test "matches when character_id matches as victim" do
      subscription = %{
        "system_ids" => [],
        "character_ids" => [123, 456]
      }

      killmail =
        create_test_killmail(%{
          "solar_system_id" => 30_000_999,
          "victim" => %{"character_id" => 123, "damage_taken" => 100},
          "attackers" => []
        })

      assert Filter.matches_subscription?(killmail, subscription)
    end

    test "matches when character_id matches as attacker" do
      subscription = %{
        "system_ids" => [],
        "character_ids" => [123, 456]
      }

      killmail =
        create_test_killmail(%{
          "solar_system_id" => 30_000_999,
          "victim" => %{"character_id" => 999, "damage_taken" => 100},
          "attackers" => [
            %{"character_id" => 456}
          ]
        })

      assert Filter.matches_subscription?(killmail, subscription)
    end

    test "matches when both system and character match" do
      subscription = %{
        "system_ids" => [30_000_142],
        "character_ids" => [123]
      }

      killmail =
        create_test_killmail(%{
          "solar_system_id" => 30_000_142,
          "victim" => %{"character_id" => 123, "damage_taken" => 100}
        })

      assert Filter.matches_subscription?(killmail, subscription)
    end

    test "does not match when neither system nor character match" do
      subscription = %{
        "system_ids" => [30_000_142],
        "character_ids" => [123]
      }

      killmail =
        create_test_killmail(%{
          "solar_system_id" => 30_000_999,
          "victim" => %{"character_id" => 999, "damage_taken" => 100},
          "attackers" => []
        })

      refute Filter.matches_subscription?(killmail, subscription)
    end

    test "matches when system matches but character does not (OR logic)" do
      subscription = %{
        "system_ids" => [30_000_142],
        "character_ids" => [123, 456]
      }

      killmail =
        create_test_killmail(%{
          "solar_system_id" => 30_000_142,
          "victim" => %{"character_id" => 999, "damage_taken" => 100},
          "attackers" => [%{"character_id" => 888}]
        })

      # Should match because system matches, even though character doesn't
      assert Filter.matches_subscription?(killmail, subscription)
    end

    test "handles system_id key instead of solar_system_id" do
      subscription = %{
        "system_ids" => [30_000_142],
        "character_ids" => []
      }

      killmail =
        create_test_killmail(%{
          "system_id" => 30_000_142,
          "victim" => %{"character_id" => 999, "damage_taken" => 100}
        })

      assert Filter.matches_subscription?(killmail, subscription)
    end

    test "handles nil system_ids in subscription" do
      subscription = %{
        "system_ids" => nil,
        "character_ids" => [123]
      }

      killmail =
        create_test_killmail(%{
          "solar_system_id" => 30_000_142,
          "victim" => %{"character_id" => 123, "damage_taken" => 100}
        })

      assert Filter.matches_subscription?(killmail, subscription)
    end

    test "handles nil character_ids in subscription" do
      subscription = %{
        "system_ids" => [30_000_142],
        "character_ids" => nil
      }

      killmail =
        create_test_killmail(%{
          "solar_system_id" => 30_000_142,
          "victim" => %{"character_id" => 123, "damage_taken" => 100}
        })

      assert Filter.matches_subscription?(killmail, subscription)
    end

    test "matches everything when both filters are empty (wildcard subscription)" do
      subscription = %{
        "system_ids" => [],
        "character_ids" => []
      }

      killmail =
        create_test_killmail(%{
          "solar_system_id" => 30_000_142,
          "victim" => %{"character_id" => 123, "damage_taken" => 100}
        })

      # Empty lists should mean "match everything" - wildcard subscription
      assert Filter.matches_subscription?(killmail, subscription)
    end
  end

  describe "filter_killmails/2" do
    test "filters killmails by system" do
      subscription = %{
        "system_ids" => [30_000_142],
        "character_ids" => []
      }

      killmails = [
        create_test_killmail(%{"solar_system_id" => 30_000_142, "killmail_id" => 1}),
        create_test_killmail(%{"solar_system_id" => 30_000_143, "killmail_id" => 2}),
        create_test_killmail(%{"solar_system_id" => 30_000_142, "killmail_id" => 3})
      ]

      filtered = Filter.filter_killmails(killmails, subscription)
      assert length(filtered) == 2

      # Sort results to ensure order-independent comparison
      solar_system_ids =
        filtered
        |> Enum.map(& &1.system_id)
        |> Enum.sort()

      assert solar_system_ids == [30_000_142, 30_000_142]
    end

    test "filters killmails by character" do
      subscription = %{
        "system_ids" => [],
        "character_ids" => [123]
      }

      killmails = [
        create_test_killmail(%{
          "solar_system_id" => 30_000_142,
          "victim" => %{"character_id" => 123, "damage_taken" => 100},
          "killmail_id" => 1
        }),
        create_test_killmail(%{
          "solar_system_id" => 30_000_143,
          "victim" => %{"character_id" => 456, "damage_taken" => 100},
          "killmail_id" => 2
        }),
        create_test_killmail(%{
          "solar_system_id" => 30_000_144,
          "victim" => %{"character_id" => 789, "damage_taken" => 100},
          "attackers" => [%{"character_id" => 123}],
          "killmail_id" => 3
        })
      ]

      filtered = Filter.filter_killmails(killmails, subscription)
      assert length(filtered) == 2
      assert Enum.map(filtered, & &1.killmail_id) == [1, 3]
    end

    test "returns empty list when no matches" do
      subscription = %{
        "system_ids" => [30_000_999],
        "character_ids" => []
      }

      killmails = [
        create_test_killmail(%{"solar_system_id" => 30_000_142, "killmail_id" => 1}),
        create_test_killmail(%{"solar_system_id" => 30_000_143, "killmail_id" => 2})
      ]

      filtered = Filter.filter_killmails(killmails, subscription)
      assert filtered == []
    end
  end

  describe "has_filters?/1" do
    test "returns true when has system filters" do
      subscription = %{"system_ids" => [30_000_142], "character_ids" => []}
      assert Filter.has_filters?(subscription)
    end

    test "returns true when has character filters" do
      subscription = %{"system_ids" => [], "character_ids" => [123]}
      assert Filter.has_filters?(subscription)
    end

    test "returns true when has both filters" do
      subscription = %{"system_ids" => [30_000_142], "character_ids" => [123]}
      assert Filter.has_filters?(subscription)
    end

    test "returns false when both filters are empty" do
      subscription = %{"system_ids" => [], "character_ids" => []}
      refute Filter.has_filters?(subscription)
    end

    test "returns false when both filters are nil" do
      subscription = %{"system_ids" => nil, "character_ids" => nil}
      refute Filter.has_filters?(subscription)
    end
  end

  describe "has_system_filter?/1" do
    test "returns true when system_ids is non-empty" do
      subscription = %{"system_ids" => [30_000_142]}
      assert Filter.has_system_filter?(subscription)
    end

    test "returns false when system_ids is empty" do
      subscription = %{"system_ids" => []}
      refute Filter.has_system_filter?(subscription)
    end

    test "returns false when system_ids is nil" do
      subscription = %{"system_ids" => nil}
      refute Filter.has_system_filter?(subscription)
    end
  end

  describe "has_character_filter?/1" do
    test "returns true when character_ids is non-empty" do
      subscription = %{"character_ids" => [123]}
      assert Filter.has_character_filter?(subscription)
    end

    test "returns false when character_ids is empty" do
      subscription = %{"character_ids" => []}
      refute Filter.has_character_filter?(subscription)
    end

    test "returns false when character_ids is nil" do
      subscription = %{"character_ids" => nil}
      refute Filter.has_character_filter?(subscription)
    end
  end
end
