defmodule WandererKills.Domain.Killmail do
  @moduledoc """
  Domain struct representing a killmail.

  This module defines the core killmail structure used throughout the application,
  replacing loose maps with a typed struct for better type safety and documentation.
  """

  alias WandererKills.Core.Support.Error
  alias WandererKills.Domain.{Attacker, Victim, ZkbMetadata}

  @type t :: %__MODULE__{
          killmail_id: integer(),
          kill_time: DateTime.t(),
          system_id: integer(),
          solar_system_name: binary() | nil,
          moon_id: integer() | nil,
          war_id: integer() | nil,
          victim: Victim.t(),
          attackers: [Attacker.t()],
          zkb: ZkbMetadata.t() | nil,
          attacker_count: non_neg_integer() | nil
        }

  @enforce_keys [:killmail_id, :kill_time, :system_id, :victim, :attackers]
  defstruct [
    :killmail_id,
    :kill_time,
    :system_id,
    :solar_system_name,
    :moon_id,
    :war_id,
    :victim,
    :attackers,
    :zkb,
    :attacker_count
  ]

  @doc """
  Creates a new Killmail struct from a map.

  ## Parameters
    - `attrs` - Map with killmail attributes

  ## Returns
    - `{:ok, %Killmail{}}` - Successfully created killmail
    - `{:error, reason}` - Failed to create killmail

  ## Examples

      iex> Killmail.new(%{
      ...>   "killmail_id" => 123,
      ...>   "kill_time" => "2024-01-01T12:00:00Z",
      ...>   "system_id" => 30000142,
      ...>   "victim" => %{},
      ...>   "attackers" => []
      ...> })
      {:ok, %Killmail{...}}
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, victim} <- build_victim(attrs["victim"] || attrs[:victim]),
         {:ok, attackers} <- build_attackers(attrs["attackers"] || attrs[:attackers]),
         {:ok, zkb} <- build_zkb(attrs["zkb"] || attrs[:zkb]),
         {:ok, kill_time} <- parse_kill_time(attrs) do
      killmail = %__MODULE__{
        killmail_id: get_field(attrs, ["killmail_id", :killmail_id]),
        kill_time: kill_time,
        system_id: get_field(attrs, ["system_id", :system_id, "solar_system_id"]),
        solar_system_name: get_field(attrs, ["solar_system_name", :solar_system_name]),
        moon_id: get_field(attrs, ["moon_id", :moon_id]),
        war_id: get_field(attrs, ["war_id", :war_id]),
        victim: victim,
        attackers: attackers,
        zkb: zkb,
        attacker_count: length(attackers)
      }

      validate_required_fields(killmail)
    else
      error -> error
    end
  end

  @doc """
  Converts a Killmail struct to a map for JSON serialization.

  ## Parameters
    - `killmail` - Killmail struct to convert

  ## Returns
    Map representation of the killmail
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = killmail) do
    %{
      "killmail_id" => killmail.killmail_id,
      "kill_time" => format_kill_time(killmail.kill_time),
      "system_id" => killmail.system_id,
      "solar_system_name" => killmail.solar_system_name,
      "moon_id" => killmail.moon_id,
      "war_id" => killmail.war_id,
      "victim" => Victim.to_map(killmail.victim),
      "attackers" => Enum.map(killmail.attackers, &Attacker.to_map/1),
      "zkb" => if(killmail.zkb, do: ZkbMetadata.to_map(killmail.zkb), else: nil),
      "attacker_count" => killmail.attacker_count
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  @doc """
  Updates a killmail with enriched data.

  ## Parameters
    - `killmail` - Original killmail
    - `enriched_data` - Map with enriched data

  ## Returns
    Updated killmail struct
  """
  @spec update_with_enriched_data(t(), map()) :: t()
  def update_with_enriched_data(%__MODULE__{} = killmail, enriched_data)
      when is_map(enriched_data) do
    victim =
      if enriched_victim = enriched_data["victim"] do
        Victim.update_with_enriched_data(killmail.victim, enriched_victim)
      else
        killmail.victim
      end

    attackers =
      if enriched_attackers = enriched_data["attackers"] do
        update_attackers_with_enriched_data(killmail.attackers, enriched_attackers)
      else
        killmail.attackers
      end

    %{killmail | victim: victim, attackers: attackers}
  end

  # Private functions

  defp build_victim(nil),
    do: {:error, Error.validation_error(:missing_victim, "Victim data is required")}

  defp build_victim(victim_data) when is_map(victim_data) do
    Victim.new(victim_data)
  end

  defp build_attackers(nil), do: {:ok, []}

  defp build_attackers(attackers) when is_list(attackers) do
    attackers
    |> Enum.map(&Attacker.new/1)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, attacker}, {:ok, acc} -> {:cont, {:ok, [attacker | acc]}}
      {:error, _} = error, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp build_zkb(nil), do: {:ok, nil}

  defp build_zkb(zkb_data) when is_map(zkb_data) do
    ZkbMetadata.new(zkb_data)
  end

  defp parse_kill_time(attrs) do
    time_str = get_field(attrs, ["kill_time", :kill_time, "killmail_time", :killmail_time])

    case time_str do
      nil ->
        {:error, Error.validation_error(:missing_kill_time, "Kill time is required")}

      str when is_binary(str) ->
        case DateTime.from_iso8601(str) do
          {:ok, dt, _} ->
            {:ok, dt}

          _ ->
            {:error,
             Error.validation_error(:invalid_kill_time, "Kill time must be valid ISO-8601 format")}
        end

      %DateTime{} = dt ->
        {:ok, dt}

      _ ->
        {:error,
         Error.validation_error(:invalid_kill_time, "Kill time must be a string or DateTime")}
    end
  end

  defp format_kill_time(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_kill_time(str) when is_binary(str), do: str

  defp get_field(map, keys) when is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp validate_required_fields(%__MODULE__{} = killmail) do
    errors = []
    errors = if is_nil(killmail.killmail_id), do: [:missing_killmail_id | errors], else: errors
    errors = if is_nil(killmail.system_id), do: [:missing_system_id | errors], else: errors

    case errors do
      [] ->
        {:ok, killmail}

      _ ->
        error_messages =
          Enum.map(errors, fn
            :missing_killmail_id -> "killmail_id is required"
            :missing_system_id -> "system_id is required"
          end)

        {:error,
         Error.validation_error(:validation_failed, Enum.join(error_messages, ", "), %{
           errors: errors
         })}
    end
  end

  defp update_attackers_with_enriched_data(attackers, enriched_attackers) do
    # Match attackers by position in list (they should be in same order)
    attackers
    |> Enum.zip(enriched_attackers)
    |> Enum.map(fn {attacker, enriched} ->
      if is_map(enriched) do
        Attacker.update_with_enriched_data(attacker, enriched)
      else
        attacker
      end
    end)
  end
end
