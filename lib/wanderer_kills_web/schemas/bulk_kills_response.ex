defmodule WandererKillsWeb.Schemas.BulkKillsResponse do
  @moduledoc """
  OpenAPI schema for bulk kills response.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "BulkKillsResponse",
    description: "Response containing kills for multiple systems",
    type: :object,
    properties: %{
      systems_kills: %OpenApiSpex.Schema{
        type: :object,
        description: "Map of system IDs to their kill lists",
        additionalProperties: %OpenApiSpex.Schema{
          type: :array,
          items: WandererKillsWeb.Schemas.Killmail
        }
      },
      timestamp: %OpenApiSpex.Schema{
        type: :string,
        format: :"date-time",
        description: "ISO8601 timestamp of the response"
      }
    },
    required: [:systems_kills, :timestamp],
    example: %{
      systems_kills: %{
        "30000142" => [
          %{
            killmail_id: 123_456_789,
            system_id: 30_000_142,
            kill_time: "2024-01-01T12:00:00Z",
            victim: %{character_id: 95_465_499},
            attackers: [%{character_id: 90_379_338}],
            zkb: %{totalValue: 100_000_000}
          }
        ]
      },
      timestamp: "2024-01-01T12:00:00Z"
    }
  })
end
