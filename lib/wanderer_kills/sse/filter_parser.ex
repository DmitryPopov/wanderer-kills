defmodule WandererKills.SSE.FilterParser do
  @moduledoc """
  Parses and validates query parameters for SSE stream filtering.
  """

  alias WandererKills.Core.Support.Error

  @doc """
  Parses query parameters into a filter map.

  ## Parameters
  - system_ids: Comma-separated list of system IDs
  - character_ids: Comma-separated list of character IDs  
  - min_value: Minimum ISK value threshold

  ## Examples

      iex> parse(%{"system_ids" => "30000142,30000144"})
      {:ok, %{system_ids: [30000142, 30000144], character_ids: [], min_value: nil}}
      
      iex> parse(%{"min_value" => "100000000"})
      {:ok, %{system_ids: [], character_ids: [], min_value: 100000000}}
  """
  def parse(params) when is_map(params) do
    with {:ok, system_ids} <- parse_ids(params["system_ids"], "system_ids"),
         {:ok, character_ids} <- parse_ids(params["character_ids"], "character_ids"),
         {:ok, min_value} <- parse_min_value(params["min_value"]) do
      filters = %{
        system_ids: system_ids,
        character_ids: character_ids,
        min_value: min_value
      }

      validate_filters(filters)
    end
  end

  def parse(_), do: parse(%{})

  @doc """
  Checks if a killmail matches the given filters.
  """
  def matches?(killmail, filters) do
    system_match?(killmail, filters.system_ids) &&
      character_match?(killmail, filters.character_ids) &&
      value_match?(killmail, filters.min_value)
  end

  # Private functions

  defp parse_ids(nil, _field), do: {:ok, []}
  defp parse_ids("", _field), do: {:ok, []}

  defp parse_ids(ids_string, field) when is_binary(ids_string) do
    ids =
      ids_string
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&parse_integer/1)

    case Enum.find(ids, &match?({:error, _}, &1)) do
      {:error, value} ->
        {:error,
         Error.validation_error(
           :invalid_format,
           "Invalid #{field}: '#{value}' is not a valid integer"
         )}

      nil ->
        {:ok, Enum.map(ids, fn {:ok, id} -> id end)}
    end
  end

  defp parse_ids(_, field) do
    {:error,
     Error.validation_error(
       :invalid_format,
       "#{field} must be a comma-separated list of integers"
     )}
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> {:error, value}
    end
  end

  defp parse_min_value(nil), do: {:ok, nil}
  defp parse_min_value(""), do: {:ok, nil}

  defp parse_min_value(value) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} when float >= 0 ->
        {:ok, float}

      {float, ""} ->
        {:error,
         Error.validation_error(
           :invalid_format,
           "min_value must be non-negative, got #{float}"
         )}

      _ ->
        {:error,
         Error.validation_error(
           :invalid_format,
           "Invalid min_value: '#{value}' is not a valid number"
         )}
    end
  end

  defp parse_min_value(value) when is_number(value) and value >= 0 do
    {:ok, value}
  end

  defp parse_min_value(_) do
    {:error,
     Error.validation_error(
       :invalid_format,
       "min_value must be a non-negative number"
     )}
  end

  defp validate_filters(filters) do
    cond do
      length(filters.system_ids) > 100 ->
        {:error,
         Error.validation_error(
           :invalid_format,
           "Too many system_ids specified (max 100)"
         )}

      length(filters.character_ids) > 100 ->
        {:error,
         Error.validation_error(
           :invalid_format,
           "Too many character_ids specified (max 100)"
         )}

      true ->
        {:ok, filters}
    end
  end

  defp system_match?(_killmail, []), do: true

  defp system_match?(killmail, system_ids) do
    killmail.solar_system_id in system_ids
  end

  defp character_match?(_killmail, []), do: true

  defp character_match?(killmail, character_ids) do
    victim_match = killmail.victim.character_id in character_ids

    attacker_match =
      killmail.attackers
      |> Enum.any?(fn attacker -> attacker.character_id in character_ids end)

    victim_match or attacker_match
  end

  defp value_match?(_killmail, nil), do: true

  defp value_match?(killmail, min_value) do
    case Map.get(killmail, :zkb) do
      %{total_value: total} when is_number(total) ->
        total >= min_value

      _ ->
        false
    end
  end
end
