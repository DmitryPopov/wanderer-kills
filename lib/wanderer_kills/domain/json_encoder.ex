defmodule WandererKills.Domain.JsonEncoder do
  @moduledoc """
  Jason.Encoder protocol implementations for domain structs.

  This module provides optimized JSON encoding for domain structs,
  eliminating the need for intermediate map conversions.
  """

  alias WandererKills.Domain.{Attacker, Killmail, Victim, ZkbMetadata}

  # Shared helper function for all protocol implementations
  def maybe_add_field(map, _key, nil), do: map
  def maybe_add_field(map, key, value), do: Map.put(map, key, value)

  # Implement Jason.Encoder for Killmail
  defimpl Jason.Encoder, for: Killmail do
    alias WandererKills.Domain.JsonEncoder

    def encode(killmail, opts) do
      killmail
      |> build_killmail_map()
      |> Jason.Encode.map(opts)
    end

    defp build_killmail_map(killmail) do
      %{
        "killmail_id" => killmail.killmail_id,
        "kill_time" => format_kill_time(killmail.kill_time),
        "system_id" => killmail.system_id,
        "victim" => killmail.victim,
        "attackers" => killmail.attackers
      }
      |> JsonEncoder.maybe_add_field("solar_system_name", killmail.solar_system_name)
      |> JsonEncoder.maybe_add_field("moon_id", killmail.moon_id)
      |> JsonEncoder.maybe_add_field("war_id", killmail.war_id)
      |> JsonEncoder.maybe_add_field("zkb", killmail.zkb)
      |> JsonEncoder.maybe_add_field(
        "attacker_count",
        killmail.attacker_count
      )
    end

    defp format_kill_time(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
    defp format_kill_time(str) when is_binary(str), do: str
    defp format_kill_time(nil), do: nil
  end

  # Implement Jason.Encoder for Victim
  defimpl Jason.Encoder, for: Victim do
    alias WandererKills.Domain.JsonEncoder

    def encode(victim, opts) do
      victim
      |> build_victim_map()
      |> Jason.Encode.map(opts)
    end

    defp build_victim_map(victim) do
      %{
        "character_id" => victim.character_id,
        "ship_type_id" => victim.ship_type_id,
        "damage_taken" => victim.damage_taken
      }
      |> JsonEncoder.maybe_add_field("corporation_id", victim.corporation_id)
      |> JsonEncoder.maybe_add_field("alliance_id", victim.alliance_id)
      |> JsonEncoder.maybe_add_field("position", victim.position)
      |> JsonEncoder.maybe_add_field("character_name", victim.character_name)
      |> JsonEncoder.maybe_add_field(
        "corporation_name",
        victim.corporation_name
      )
      |> JsonEncoder.maybe_add_field(
        "corporation_ticker",
        victim.corporation_ticker
      )
      |> JsonEncoder.maybe_add_field("alliance_name", victim.alliance_name)
      |> JsonEncoder.maybe_add_field(
        "alliance_ticker",
        victim.alliance_ticker
      )
      |> JsonEncoder.maybe_add_field("ship_name", victim.ship_name)
    end
  end

  # Implement Jason.Encoder for Attacker
  defimpl Jason.Encoder, for: Attacker do
    alias WandererKills.Domain.JsonEncoder

    def encode(attacker, opts) do
      attacker
      |> build_attacker_map()
      |> Jason.Encode.map(opts)
    end

    defp build_attacker_map(attacker) do
      %{
        "damage_done" => attacker.damage_done,
        "final_blow" => attacker.final_blow
      }
      |> JsonEncoder.maybe_add_field("character_id", attacker.character_id)
      |> JsonEncoder.maybe_add_field(
        "corporation_id",
        attacker.corporation_id
      )
      |> JsonEncoder.maybe_add_field("alliance_id", attacker.alliance_id)
      |> JsonEncoder.maybe_add_field("ship_type_id", attacker.ship_type_id)
      |> JsonEncoder.maybe_add_field(
        "weapon_type_id",
        attacker.weapon_type_id
      )
      |> JsonEncoder.maybe_add_field(
        "security_status",
        attacker.security_status
      )
      |> JsonEncoder.maybe_add_field(
        "character_name",
        attacker.character_name
      )
      |> JsonEncoder.maybe_add_field(
        "corporation_name",
        attacker.corporation_name
      )
      |> JsonEncoder.maybe_add_field(
        "corporation_ticker",
        attacker.corporation_ticker
      )
      |> JsonEncoder.maybe_add_field("alliance_name", attacker.alliance_name)
      |> JsonEncoder.maybe_add_field(
        "alliance_ticker",
        attacker.alliance_ticker
      )
      |> JsonEncoder.maybe_add_field("ship_name", attacker.ship_name)
    end
  end

  # Implement Jason.Encoder for ZkbMetadata
  defimpl Jason.Encoder, for: ZkbMetadata do
    alias WandererKills.Domain.JsonEncoder

    def encode(zkb, opts) do
      zkb
      |> build_zkb_map()
      |> Jason.Encode.map(opts)
    end

    defp build_zkb_map(zkb) do
      %{
        "locationID" => zkb.location_id,
        "hash" => zkb.hash,
        "totalValue" => zkb.total_value,
        "points" => zkb.points,
        "npc" => zkb.npc,
        "solo" => zkb.solo,
        "awox" => zkb.awox
      }
      |> JsonEncoder.maybe_add_field("fittedValue", zkb.fitted_value)
      |> JsonEncoder.maybe_add_field("droppedValue", zkb.dropped_value)
      |> JsonEncoder.maybe_add_field("destroyedValue", zkb.destroyed_value)
      |> JsonEncoder.maybe_add_field("labels", zkb.labels)
    end
  end
end
