defmodule WandererKillsWeb.Schemas.Killmail do
  @moduledoc """
  OpenAPI schema for killmail data.
  """

  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias WandererKillsWeb.Schemas.{Victim, Attacker, ZKB}

  OpenApiSpex.schema(%{
    title: "Killmail",
    description: "A complete killmail record with enriched data",
    type: :object,
    properties: %{
      killmail_id: %Schema{
        type: :integer,
        description: "Unique killmail ID"
      },
      kill_time: %Schema{
        type: :string,
        format: :"date-time",
        description: "Time when the kill occurred"
      },
      solar_system_id: %Schema{
        type: :integer,
        description: "EVE system ID where the kill occurred"
      },
      solar_system_name: %Schema{
        type: :string,
        description: "System name",
        nullable: true
      },
      victim: Victim,
      attackers: %Schema{
        type: :array,
        items: Attacker,
        description: "List of attackers"
      },
      zkb: ZKB
    },
    required: [:killmail_id, :kill_time, :solar_system_id, :victim, :attackers, :zkb],
    example: %{
      "killmail_id" => 123_456_789,
      "kill_time" => "2024-01-15T14:30:00Z",
      "solar_system_id" => 30_000_142,
      "solar_system_name" => "Jita",
      "victim" => %{
        "character_id" => 987_654_321,
        "character_name" => "Victim Name",
        "corporation_id" => 98_000_001,
        "corporation_name" => "Victim Corp",
        "ship_type_id" => 670,
        "ship_name" => "Raven",
        "damage_taken" => 28_470
      },
      "attackers" => [
        %{
          "character_id" => 123_456_789,
          "character_name" => "Attacker Name",
          "corporation_id" => 98_000_002,
          "corporation_name" => "Attacker Corp",
          "ship_type_id" => 17_918,
          "ship_name" => "Rattlesnake",
          "weapon_type_id" => 2488,
          "damage_done" => 28_470,
          "final_blow" => true
        }
      ],
      "zkb" => %{
        "location_id" => 50_000_001,
        "hash" => "abc123def456",
        "fitted_value" => 150_000_000.0,
        "total_value" => 152_000_000.0,
        "points" => 15,
        "npc" => false,
        "solo" => true,
        "awox" => false
      }
    }
  })
end
