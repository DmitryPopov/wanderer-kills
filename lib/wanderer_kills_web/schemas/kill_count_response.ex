defmodule WandererKillsWeb.Schemas.KillCountResponse do
  @moduledoc """
  OpenAPI schema for kill count response.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "KillCountResponse",
    description: "Response containing kill count for a system",
    type: :object,
    properties: %{
      system_id: %OpenApiSpex.Schema{
        type: :integer,
        description: "EVE Online system ID"
      },
      count: %OpenApiSpex.Schema{
        type: :integer,
        description: "Total number of kills in the system"
      },
      timestamp: %OpenApiSpex.Schema{
        type: :string,
        format: :"date-time",
        description: "ISO8601 timestamp of the response"
      }
    },
    required: [:system_id, :count, :timestamp],
    example: %{
      system_id: 30_000_142,
      count: 42,
      timestamp: "2024-01-01T12:00:00Z"
    }
  })
end
