defmodule WandererKills.SSE.FilterHandler do
  @moduledoc """
  Handles server-side filtering of killmails for SSE streams.

  This module determines whether a killmail should be sent to a client
  based on the active filters for that connection.
  """

  require Logger

  @doc """
  Determines if a killmail should be sent based on the active filters.

  ## Parameters
  - `killmail` - The killmail to check
  - `filters` - The active filters for the connection

  ## Returns
  - `true` if the killmail should be sent
  - `false` if the killmail should be filtered out
  """
  @spec should_send_killmail?(map(), map()) :: boolean()
  def should_send_killmail?(killmail, filters) do
    cond do
      no_filters?(filters) ->
        true

      value_below_threshold?(killmail, filters.min_value) ->
        false

      no_location_filters?(filters) ->
        true

      true ->
        character_matches?(killmail, filters.character_ids) ||
          system_matches?(killmail, filters.system_ids)
    end
  end

  # Check if any filters are active
  defp no_filters?(filters) do
    Enum.empty?(filters.character_ids) &&
      Enum.empty?(filters.system_ids) &&
      is_nil(filters.min_value)
  end

  # Check if value is below threshold
  defp value_below_threshold?(_killmail, nil), do: false

  defp value_below_threshold?(killmail, min_value) do
    !value_matches?(killmail, min_value)
  end

  # Check if there are no location-based filters
  defp no_location_filters?(filters) do
    Enum.empty?(filters.character_ids) && Enum.empty?(filters.system_ids)
  end

  # Check if killmail matches character filter
  defp character_matches?(_killmail, []), do: false

  defp character_matches?(killmail, character_ids) when is_list(character_ids) do
    character_set = MapSet.new(character_ids)

    victim_matches?(killmail, character_set) ||
      any_attacker_matches?(killmail, character_set)
  end

  defp victim_matches?(killmail, character_set) do
    case get_in(killmail, ["victim", "character_id"]) do
      nil -> false
      char_id -> MapSet.member?(character_set, char_id)
    end
  end

  defp any_attacker_matches?(killmail, character_set) do
    killmail
    |> Map.get("attackers", [])
    |> Enum.any?(&attacker_matches?(&1, character_set))
  end

  defp attacker_matches?(attacker, character_set) do
    case Map.get(attacker, "character_id") do
      nil -> false
      char_id -> MapSet.member?(character_set, char_id)
    end
  end

  # Check if killmail matches system filter
  defp system_matches?(_killmail, []), do: false

  defp system_matches?(killmail, system_ids) when is_list(system_ids) do
    system_id = Map.get(killmail, "solar_system_id") || Map.get(killmail, "system_id")
    system_id in system_ids
  end

  # Check if killmail meets minimum value threshold
  defp value_matches?(_killmail, nil), do: true

  defp value_matches?(killmail, min_value) do
    case get_in(killmail, ["zkb", "totalValue"]) || get_in(killmail, ["zkb", "total_value"]) do
      nil ->
        Logger.debug("[FilterHandler] No zkb value found in killmail",
          killmail_id: Map.get(killmail, "killmail_id")
        )

        false

      value when is_number(value) ->
        value >= min_value

      _ ->
        false
    end
  end

  @doc """
  Logs filter match details for debugging.

  ## Parameters
  - `killmail` - The killmail being checked
  - `filters` - The active filters
  - `result` - Whether the killmail passed the filters
  """
  @spec log_filter_result(map(), map(), boolean()) :: :ok
  def log_filter_result(killmail, filters, result) do
    Logger.debug("[FilterHandler] Filter check result",
      killmail_id: Map.get(killmail, "killmail_id"),
      passed: result,
      has_character_filter: not Enum.empty?(filters.character_ids),
      has_system_filter: not Enum.empty?(filters.system_ids),
      has_value_filter: not is_nil(filters.min_value)
    )

    :ok
  end
end
