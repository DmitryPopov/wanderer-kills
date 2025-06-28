defmodule WandererKillsWeb.Schemas.Attacker do
  @moduledoc """
  OpenAPI schema for killmail attacker.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Attacker",
    description: "An attacker on a killmail",
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
        description: "Ship type ID",
        nullable: true
      },
      ship_name: %OpenApiSpex.Schema{
        type: :string,
        description: "Ship name",
        nullable: true
      },
      weapon_type_id: %OpenApiSpex.Schema{
        type: :integer,
        description: "Weapon type ID",
        nullable: true
      },
      weapon_name: %OpenApiSpex.Schema{
        type: :string,
        description: "Weapon name",
        nullable: true
      },
      damage_done: %OpenApiSpex.Schema{
        type: :integer,
        description: "Damage dealt"
      },
      final_blow: %OpenApiSpex.Schema{
        type: :boolean,
        description: "Dealt final blow"
      }
    },
    required: [:damage_done, :final_blow]
  })
end
