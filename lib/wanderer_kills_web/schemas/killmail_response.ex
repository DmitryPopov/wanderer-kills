defmodule WandererKillsWeb.Schemas.KillmailResponse do
  @moduledoc """
  OpenAPI schema for single killmail response.
  """

  require OpenApiSpex
  alias WandererKillsWeb.Schemas.Killmail

  OpenApiSpex.schema(%{
    title: "KillmailResponse",
    description: "Response containing a single killmail",
    type: :object,
    allOf: [Killmail],
    example: %{
      killmail_id: 123_456_789,
      system_id: 30_000_142,
      kill_time: "2024-01-01T12:00:00Z",
      victim: %{
        character_id: 95_465_499,
        corporation_id: 98_000_001,
        alliance_id: 99_000_001,
        ship_type_id: 670,
        damage_taken: 5432
      },
      attackers: [
        %{
          character_id: 90_379_338,
          corporation_id: 98_000_002,
          alliance_id: 99_000_002,
          ship_type_id: 17_918,
          damage_done: 5432,
          final_blow: true
        }
      ],
      zkb: %{
        totalValue: 100_000_000,
        points: 1,
        npc: false,
        solo: true,
        awox: false
      }
    }
  })
end
