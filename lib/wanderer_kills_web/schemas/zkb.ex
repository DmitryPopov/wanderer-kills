defmodule WandererKillsWeb.Schemas.ZKB do
  @moduledoc """
  OpenAPI schema for zKillboard metadata.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ZKB",
    description: "zKillboard metadata",
    type: :object,
    properties: %{
      location_id: %OpenApiSpex.Schema{
        type: :integer,
        description: "Location ID",
        nullable: true
      },
      hash: %OpenApiSpex.Schema{
        type: :string,
        description: "Kill hash"
      },
      fitted_value: %OpenApiSpex.Schema{
        type: :number,
        format: :float,
        description: "Fitted modules value",
        nullable: true
      },
      total_value: %OpenApiSpex.Schema{
        type: :number,
        format: :float,
        description: "Total ISK value",
        nullable: true
      },
      ship_value: %OpenApiSpex.Schema{
        type: :number,
        format: :float,
        description: "Ship hull value",
        nullable: true
      },
      points: %OpenApiSpex.Schema{
        type: :integer,
        description: "Kill points"
      },
      npc: %OpenApiSpex.Schema{
        type: :boolean,
        description: "NPC kill"
      },
      solo: %OpenApiSpex.Schema{
        type: :boolean,
        description: "Solo kill"
      },
      awox: %OpenApiSpex.Schema{
        type: :boolean,
        description: "Friendly fire"
      }
    }
  })
end
