defmodule WandererKillsWeb.Schemas.Victim do
  @moduledoc """
  OpenAPI schema for killmail victim.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Victim",
    description: "The victim of a killmail",
    type: :object,
    properties: %{
      character_id: %OpenApiSpex.Schema{
        type: :integer,
        description: "Character ID",
        nullable: true
      },
      character_name: %OpenApiSpex.Schema{
        type: :string,
        description: "Character name",
        nullable: true
      },
      corporation_id: %OpenApiSpex.Schema{
        type: :integer,
        description: "Corporation ID",
        nullable: true
      },
      corporation_name: %OpenApiSpex.Schema{
        type: :string,
        description: "Corporation name",
        nullable: true
      },
      alliance_id: %OpenApiSpex.Schema{
        type: :integer,
        description: "Alliance ID",
        nullable: true
      },
      alliance_name: %OpenApiSpex.Schema{
        type: :string,
        description: "Alliance name",
        nullable: true
      },
      ship_type_id: %OpenApiSpex.Schema{
        type: :integer,
        description: "Ship type ID"
      },
      ship_name: %OpenApiSpex.Schema{
        type: :string,
        description: "Ship name",
        nullable: true
      },
      damage_taken: %OpenApiSpex.Schema{
        type: :integer,
        description: "Total damage taken"
      }
    },
    required: [:ship_type_id, :damage_taken]
  })
end
