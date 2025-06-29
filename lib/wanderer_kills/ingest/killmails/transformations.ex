defmodule WandererKills.Ingest.Killmails.Transformations do
  @moduledoc """
  Centralized module for all killmail field transformations and data normalization.

  This module consolidates transformation logic that was previously scattered
  across multiple modules including field normalization, data structure
  standardization, and data flattening operations.

  ## Functions

  - Field name normalization (killID -> killmail_id, etc.)
  - Data structure normalization with defaults
  - Entity data flattening (nested -> flat fields)
  - Ship name enrichment
  - Attacker count calculation

  ## Usage

  ```elixir
  # Normalize field names
  normalized = Transformations.normalize_field_names(raw_killmail)

  # Flatten enriched entity data
  flattened = Transformations.flatten_enriched_data(enriched_killmail)

  # Apply victim/attacker normalization
  victim = Transformations.normalize_victim(victim_map)
  attackers = Transformations.normalize_attackers(attackers_list)
  ```
  """

  require Logger
  alias WandererKills.Core.ShipTypes.Info
  alias WandererKills.Core.Support.Error
  alias WandererKills.Ingest.ESI.Client

  # Field name mappings for normalization
  @field_mappings %{
    "killID" => "killmail_id",
    "killmail_time" => "kill_time",
    "solarSystemID" => "system_id",
    "solar_system_id" => "system_id",
    "moonID" => "moon_id",
    "warID" => "war_id"
  }

  # Default values for normalized data structures
  @victim_defaults %{
    "character_id" => nil,
    "corporation_id" => nil,
    "alliance_id" => nil,
    "ship_type_id" => nil,
    "damage_taken" => 0,
    "position" => nil
  }

  @attacker_defaults %{
    "character_id" => nil,
    "corporation_id" => nil,
    "alliance_id" => nil,
    "ship_type_id" => nil,
    "damage_done" => 0,
    "final_blow" => false,
    "security_status" => 0.0,
    "weapon_type_id" => nil
  }

  # ============================================================================
  # Field Name Normalization
  # ============================================================================

  @doc """
  Normalizes killmail field names to consistent naming convention.

  Converts legacy field names like "killID" to standardized names like "killmail_id".

  ## Parameters
  - `killmail` - Raw killmail map with potentially non-standard field names

  ## Returns
  - Killmail map with normalized field names

  ## Examples

  ```elixir
  raw = %{"killID" => 123, "killmail_time" => "2024-01-01T12:00:00Z"}
  normalized = normalize_field_names(raw)
  # %{"killmail_id" => 123, "kill_time" => "2024-01-01T12:00:00Z"}
  ```
  """
  @spec normalize_field_names(map()) :: map()
  def normalize_field_names(killmail) when is_map(killmail) do
    Enum.reduce(@field_mappings, killmail, fn {old_key, new_key}, acc ->
      case Map.pop(acc, old_key) do
        {nil, _} -> acc
        {value, updated_map} -> Map.put(updated_map, new_key, value)
      end
    end)
  end

  # ============================================================================
  # Data Structure Normalization
  # ============================================================================

  @doc """
  Normalizes victim data structure with default values.

  Ensures victim data has all required fields with appropriate defaults
  for missing values.

  ## Parameters
  - `victim` - Raw victim data map

  ## Returns
  - Normalized victim map with defaults applied
  """
  @spec normalize_victim(map()) :: map()
  def normalize_victim(victim) when is_map(victim) do
    apply_defaults(victim, @victim_defaults)
  end

  @doc """
  Normalizes attackers data structure with defaults.

  Applies default values to each attacker.

  ## Parameters
  - `attackers` - List of raw attacker data maps

  ## Returns
  - Normalized attackers list
  """
  @spec normalize_attackers([map()]) :: [map()]
  def normalize_attackers(attackers) when is_list(attackers) do
    normalize_entity_list(attackers, @attacker_defaults)
  end

  @doc """
  Normalizes attackers data and returns count.

  Applies default values to each attacker and calculates total attacker count.
  This is a convenience function when you need both normalized data and count.

  ## Parameters
  - `attackers` - List of raw attacker data maps

  ## Returns
  - `{normalized_attackers, attacker_count}` - Tuple of normalized list and count
  """
  @spec normalize_attackers_with_count([map()]) :: {[map()], non_neg_integer()}
  def normalize_attackers_with_count(attackers) when is_list(attackers) do
    normalized = normalize_attackers(attackers)
    {normalized, length(attackers)}
  end

  # ============================================================================
  # Data Flattening Operations
  # ============================================================================

  @doc """
  Flattens enriched data in a killmail by extracting nested entity information.

  Converts nested enriched data like victim.character.name to flat fields
  like victim_name for easier access and processing.

  ## Parameters
  - `killmail` - Killmail with enriched nested entity data

  ## Returns
  - Killmail with flattened data fields
  """
  @spec flatten_enriched_data(map()) :: map()
  def flatten_enriched_data(killmail) when is_map(killmail) do
    killmail
    |> flatten_victim_data()
    |> flatten_attackers_data()
    |> flatten_system_data()
  end

  @doc """
  Flattens victim entity data to top-level fields.

  Extracts character, corporation, alliance, and ship information
  from nested structures to flat victim fields.

  ## Parameters
  - `killmail` - Killmail containing victim with nested entity data

  ## Returns
  - Killmail with flattened victim data
  """
  @spec flatten_victim_data(map()) :: map()
  def flatten_victim_data(killmail) when is_map(killmail) do
    victim = Map.get(killmail, "victim", %{})

    flattened_victim =
      victim
      |> add_flat_field("victim_name", ["character", "name"])
      |> add_flat_field("corporation_name", ["corporation", "name"])
      |> add_flat_field("corporation_ticker", ["corporation", "ticker"])
      |> add_flat_field("alliance_name", ["alliance", "name"])
      |> add_flat_field("alliance_ticker", ["alliance", "ticker"])
      |> add_flat_field("ship_name", ["ship", "name"])
      |> remove_nested_entity_data()

    Map.put(killmail, "victim", flattened_victim)
  end

  @doc """
  Flattens attackers entity data to top-level fields.

  Extracts character, corporation, alliance, and ship information
  from nested structures for each attacker.

  ## Parameters
  - `killmail` - Killmail containing attackers with nested entity data

  ## Returns
  - Killmail with flattened attackers data
  """
  @spec flatten_attackers_data(map()) :: map()
  def flatten_attackers_data(killmail) when is_map(killmail) do
    attackers = Map.get(killmail, "attackers", [])

    flattened_attackers =
      Enum.map(attackers, fn attacker ->
        attacker
        |> add_flat_field("attacker_name", ["character", "name"])
        |> add_flat_field("corporation_name", ["corporation", "name"])
        |> add_flat_field("corporation_ticker", ["corporation", "ticker"])
        |> add_flat_field("alliance_name", ["alliance", "name"])
        |> add_flat_field("alliance_ticker", ["alliance", "ticker"])
        |> add_flat_field("ship_name", ["ship", "name"])
        |> remove_nested_entity_data()
      end)

    Map.put(killmail, "attackers", flattened_attackers)
  end

  @doc """
  Flattens system entity data to top-level fields.

  Extracts system information from nested structures to flat fields.

  ## Parameters
  - `killmail` - Killmail containing system with nested entity data

  ## Returns
  - Killmail with flattened system data
  """
  @spec flatten_system_data(map()) :: map()
  def flatten_system_data(killmail) when is_map(killmail) do
    killmail
    |> add_flat_field("solar_system_name", ["system", "name"])
    |> remove_nested_system_data()
  end

  # Removes nested system data to avoid duplication after flattening
  defp remove_nested_system_data(data) when is_map(data) do
    Map.delete(data, "system")
  end

  # ============================================================================
  # Ship Enrichment
  # ============================================================================

  @doc """
  Calculates and adds attacker count to killmail.

  ## Parameters
  - `killmail` - Killmail to add attacker count to

  ## Returns
  - Killmail with "attacker_count" field added
  """
  @spec add_attacker_count(map()) :: map()
  def add_attacker_count(killmail) when is_map(killmail) do
    count = killmail |> Map.get("attackers", []) |> length()
    Map.put(killmail, "attacker_count", count)
  end

  @doc """
  Enriches killmail with ship names for victim and attackers.

  This function adds "ship_name" fields to the victim and all attackers
  by looking up ship type IDs in the ship types cache.

  ## Parameters
  - `killmail` - Killmail to enrich with ship names

  ## Returns
  - `{:ok, enriched_killmail}` - Killmail with ship names added
  """
  @spec enrich_with_ship_names(map()) :: {:ok, map()}
  def enrich_with_ship_names(killmail) when is_map(killmail) do
    Logger.debug("Starting ship name enrichment for killmail",
      killmail_id: Map.get(killmail, "killmail_id")
    )

    with {:ok, killmail} <- add_victim_ship_name(killmail),
         {:ok, killmail} <- add_attackers_ship_names(killmail) do
      Logger.debug("Completed ship name enrichment for killmail",
        killmail_id: Map.get(killmail, "killmail_id")
      )

      {:ok, killmail}
    else
      {:error, reason} = error ->
        Logger.warning("Failed to enrich ship names",
          reason: reason,
          killmail_id: Map.get(killmail, "killmail_id")
        )

        # Return the error to allow the caller to decide how to handle it
        error
    end
  end

  # ============================================================================
  # Private Helper Functions
  # ============================================================================

  # Adds a flat field by extracting value from nested path
  defp add_flat_field(data, field_name, path) when is_map(data) do
    case get_in(data, path) do
      nil -> data
      value -> Map.put(data, field_name, value)
    end
  end

  # Removes nested entity data to avoid duplication after flattening
  defp remove_nested_entity_data(data) when is_map(data) do
    data
    |> Map.delete("character")
    |> Map.delete("corporation")
    |> Map.delete("alliance")
    |> Map.delete("ship")
  end

  # Adds ship name to victim
  defp add_victim_ship_name(killmail) do
    victim = Map.get(killmail, "victim", %{})

    case get_ship_name(Map.get(victim, "ship_type_id")) do
      {:ok, ship_name} ->
        updated_victim = Map.put(victim, "ship_name", ship_name)
        {:ok, Map.put(killmail, "victim", updated_victim)}

      {:error, _reason} ->
        # Log but don't fail the enrichment for missing ship names
        Logger.debug("Could not get ship name for victim",
          ship_type_id: Map.get(victim, "ship_type_id"),
          killmail_id: Map.get(killmail, "killmail_id")
        )

        {:ok, killmail}
    end
  end

  # Adds ship names to all attackers
  defp add_attackers_ship_names(killmail) do
    attackers = Map.get(killmail, "attackers", [])

    updated_attackers =
      Enum.map(attackers, fn attacker ->
        case get_ship_name(Map.get(attacker, "ship_type_id")) do
          {:ok, ship_name} ->
            Map.put(attacker, "ship_name", ship_name)

          {:error, _reason} ->
            Logger.debug("Could not get ship name for attacker",
              ship_type_id: Map.get(attacker, "ship_type_id"),
              killmail_id: Map.get(killmail, "killmail_id")
            )

            attacker
        end
      end)

    {:ok, Map.put(killmail, "attackers", updated_attackers)}
  end

  # Gets ship name from ship type ID using cached data
  defp get_ship_name(nil),
    do: {:error, Error.ship_types_error(:no_ship_type_id, "No ship type ID provided")}

  defp get_ship_name(ship_type_id) when is_integer(ship_type_id) do
    ship_type_id
    |> get_ship_from_cache()
    |> fallback_to_esi(ship_type_id)
  end

  defp get_ship_name(_),
    do: {:error, Error.ship_types_error(:invalid_ship_type_id, "Invalid ship type ID format")}

  # Try to get ship data from cache first
  defp get_ship_from_cache(ship_type_id) do
    case Info.get_ship_type(ship_type_id) do
      {:ok, ship_data} -> extract_ship_name(ship_data)
      error -> error
    end
  end

  # Extract ship name from ship data, handling both atom and string keys
  defp extract_ship_name(ship_data) when is_map(ship_data) do
    case Map.get(ship_data, :name) || Map.get(ship_data, "name") do
      name when is_binary(name) ->
        {:ok, name}

      _ ->
        {:error, Error.ship_types_error(:invalid_ship_data, "Ship data missing name field")}
    end
  end

  # Fallback to ESI if not found in cache
  defp fallback_to_esi({:error, %Error{type: :not_found}}, ship_type_id) do
    do_esi_fallback(ship_type_id)
  end

  defp fallback_to_esi(result, _ship_type_id), do: result

  defp do_esi_fallback(ship_type_id) do
    case Client.get_type(ship_type_id) do
      {:ok, %{"name" => name}} when is_binary(name) ->
        {:ok, name}

      {:ok, _} ->
        {:error, Error.ship_types_error(:invalid_ship_data, "ESI data missing name field")}

      {:error, reason} ->
        # Preserve the original ESI error for better diagnostics
        {:error, reason}
    end
  end

  # ============================================================================
  # System Name Enrichment
  # ============================================================================

  @doc """
  Enriches killmail with system name.

  This function adds "solar_system_name" field to the killmail
  by looking up the system ID via ESI.

  ## Parameters
  - `killmail` - Killmail to enrich with system name

  ## Returns
  - `{:ok, enriched_killmail}` - Killmail with system name added
  """
  @spec enrich_with_system_name(map()) :: {:ok, map()}
  def enrich_with_system_name(killmail) when is_map(killmail) do
    Logger.debug("Starting system name enrichment for killmail",
      killmail_id: Map.get(killmail, "killmail_id")
    )

    {:ok, enriched_killmail} = add_system_name(killmail)

    Logger.debug("Completed system name enrichment for killmail",
      killmail_id: Map.get(killmail, "killmail_id")
    )

    {:ok, enriched_killmail}
  end

  # Adds system name to killmail from enriched system data
  defp add_system_name(killmail) do
    case get_in(killmail, ["system", "name"]) do
      name when is_binary(name) ->
        {:ok, Map.put(killmail, "solar_system_name", name)}

      _ ->
        # Log but don't fail the enrichment for missing system names
        Logger.debug("Could not get system name from enriched data",
          system_id: Map.get(killmail, "system_id"),
          killmail_id: Map.get(killmail, "killmail_id")
        )

        {:ok, killmail}
    end
  end

  # ============================================================================
  # Common Normalization Patterns
  # ============================================================================

  @doc """
  Applies default values to a data structure.

  Generic function for merging defaults with provided data.
  """
  @spec apply_defaults(map(), map()) :: map()
  def apply_defaults(data, defaults) when is_map(data) and is_map(defaults) do
    Map.merge(defaults, data)
  end

  @doc """
  Normalizes a list of entities with defaults.

  Generic function for normalizing lists of data structures.
  """
  @spec normalize_entity_list([map()], map()) :: [map()]
  def normalize_entity_list(entities, defaults) when is_list(entities) and is_map(defaults) do
    Enum.map(entities, &apply_defaults(&1, defaults))
  end

  # ============================================================================
  # Utility Functions
  # ============================================================================

  @doc """
  Extracts the killmail time field from a killmail.

  Handles different field name variations.
  """
  @spec get_killmail_time(map()) :: String.t() | DateTime.t() | nil
  def get_killmail_time(killmail) when is_map(killmail) do
    # ESI returns "killmail_time", but after normalization it might be "kill_time"
    killmail["killmail_time"] || killmail["kill_time"]
  end

  @doc """
  Extracts the killmail ID from a killmail safely.
  """
  @spec get_killmail_id(map()) :: integer() | nil
  def get_killmail_id(%{"killmail_id" => id}) when is_integer(id), do: id
  def get_killmail_id(_), do: nil
end
