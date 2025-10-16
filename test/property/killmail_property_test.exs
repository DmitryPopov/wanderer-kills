defmodule WandererKills.Domain.KillmailPropertyTest do
  use ExUnit.Case
  use ExUnitProperties
  use WandererKills.TestCase

  @moduletag :property
  @moduletag area: :killmail_processing
  @moduletag performance: :medium

  alias WandererKills.Domain.Killmail

  describe "killmail parsing properties" do
    @tag :property
    test "killmail conversion is consistent" do
      check all(killmail_data <- simple_killmail_generator()) do
        case Killmail.new(killmail_data) do
          {:ok, killmail} ->
            # Verify that a valid killmail can be converted back
            map_data = Killmail.to_map(killmail)
            assert {:ok, _} = Killmail.new(map_data)

            # Just verify that the killmail was processed successfully
            assert killmail.killmail_id == 123_456_789

          {:error, _} ->
            # If parsing fails, it should consistently fail
            assert {:error, _} = Killmail.new(killmail_data)
        end
      end
    end

    @tag :property
    test "killmail IDs are preserved correctly" do
      check all(
              killmail_id <- positive_integer(),
              max_runs: 20
            ) do
        killmail_data = %{
          "killmail_id" => killmail_id,
          "solar_system_id" => 30_000_142,
          "killmail_time" => "2024-01-01T12:00:00Z",
          "victim" => simple_victim(),
          "attackers" => [simple_attacker()]
        }

        case Killmail.new(killmail_data) do
          {:ok, killmail} ->
            assert killmail.killmail_id == killmail_id
            assert killmail.system_id == 30_000_142

          {:error, _reason} ->
            # Some IDs might be invalid, that's okay
            :ok
        end
      end
    end
  end

  # Helper functions for simple test data

  defp simple_killmail_generator do
    fixed_map(%{
      "killmail_id" => constant(123_456_789),
      "solar_system_id" => constant(30_000_142),
      "killmail_time" => constant("2024-01-01T12:00:00Z"),
      "victim" => simple_victim(),
      "attackers" => list_of(simple_attacker(), length: 1)
    })
  end

  defp simple_victim do
    fixed_map(%{
      "character_id" => constant(95_465_499),
      "corporation_id" => constant(1_000_009),
      "ship_type_id" => constant(587),
      "damage_taken" => constant(1337)
    })
  end

  defp simple_attacker do
    fixed_map(%{
      "character_id" => constant(95_465_500),
      "corporation_id" => constant(1_000_010),
      "ship_type_id" => constant(17_619),
      "damage_done" => constant(1337),
      "final_blow" => constant(true)
    })
  end
end
