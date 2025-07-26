defmodule WandererKills.Core.ShipTypes.DataProcessor do
  @moduledoc """
  Consolidated CSV parsing and validation for ship types and groups.

  This module combines the functionality of the old Parser and Validator modules,
  providing a streamlined interface for processing ship type CSV data. It handles:

  - CSV file reading and parsing
  - Data validation and filtering
  - Type conversions and transformations
  - Error handling and statistics reporting

  ## Example Usage

      # Process ship types
      {:ok, %{ship_types: types, stats: stats}} = DataProcessor.process_ship_types("path/to/invTypes.csv")
      
      # Process ship groups  
      {:ok, %{ship_groups: groups, stats: stats}} = DataProcessor.process_ship_groups("path/to/invGroups.csv")
  """

  require Logger
  alias NimbleCSV.RFC4180, as: CSVParser
  alias WandererKills.Core.Support.Error

  @type ship_type :: %{
          type_id: integer(),
          name: String.t(),
          group_id: integer(),
          mass: float(),
          volume: float(),
          capacity: float(),
          portion_size: integer(),
          race_id: integer(),
          base_price: float(),
          published: boolean(),
          market_group_id: integer(),
          icon_id: integer(),
          sound_id: integer(),
          graphic_id: integer()
        }

  @type ship_group :: %{
          group_id: integer(),
          category_id: integer(),
          name: String.t(),
          icon_id: integer(),
          use_base_price: boolean(),
          anchored: boolean(),
          anchorable: boolean(),
          fittable_non_singleton: boolean(),
          published: boolean()
        }

  @type process_result :: %{
          ship_types: %{integer() => ship_type()} | nil,
          ship_groups: %{integer() => ship_group()} | nil,
          stats: map()
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Process ship types from a CSV file, parsing and validating the data.

  Returns a map of valid ship types keyed by type_id, along with processing statistics.
  """
  @spec process_ship_types(String.t()) :: {:ok, process_result()} | {:error, Error.t()}
  def process_ship_types(csv_path) do
    with {:ok, parsed_types} <- parse_csv_file(csv_path, &parse_ship_type_row/1),
         {:ok, validated_types} <- validate_ship_types(parsed_types) do
      {:ok, validated_types}
    end
  end

  @doc """
  Process ship groups from a CSV file, parsing and validating the data.

  Returns a map of valid ship groups keyed by group_id, along with processing statistics.
  """
  @spec process_ship_groups(String.t()) :: {:ok, process_result()} | {:error, Error.t()}
  def process_ship_groups(csv_path) do
    with {:ok, parsed_groups} <- parse_csv_file(csv_path, &parse_ship_group_row/1),
         {:ok, validated_groups} <- validate_ship_groups(parsed_groups) do
      {:ok, validated_groups}
    end
  end

  @doc """
  Gets the list of valid ship group IDs from configuration.
  """
  @spec get_valid_ship_group_ids() :: [integer()]
  def get_valid_ship_group_ids do
    Application.get_env(:wanderer_kills, :ship_types, [])
    |> Keyword.get(:valid_group_ids, default_ship_group_ids())
  end

  # ============================================================================
  # CSV Parsing
  # ============================================================================

  defp parse_csv_file(file_path, parser_function) when is_binary(file_path) do
    Logger.info("Parsing CSV file: #{file_path}")

    with {:ok, file_content} <- read_file(file_path),
         {:ok, records} <- parse_content(file_content, parser_function) do
      total_rows = length(records)
      parsed_records = Enum.reject(records, &is_nil/1)

      stats = %{
        total_rows: total_rows,
        parsed_count: length(parsed_records),
        parse_errors: total_rows - length(parsed_records)
      }

      Logger.info(
        "CSV parsing complete: #{stats.parsed_count} records parsed successfully, " <>
          "#{stats.parse_errors} errors"
      )

      {:ok, %{records: parsed_records, stats: stats}}
    end
  end

  defp read_file(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        {:ok, content}

      {:error, reason} ->
        Logger.error("Failed to read CSV file: #{file_path}, reason: #{inspect(reason)}")
        {:error, Error.csv_error(:read_failed, "Failed to read CSV file: #{inspect(reason)}")}
    end
  end

  defp parse_content(content, parser_function) do
    records =
      content
      |> CSVParser.parse_string()
      # Skip header row
      |> Stream.drop(1)
      |> Stream.map(parser_function)
      |> Enum.to_list()

    {:ok, records}
  rescue
    e ->
      Logger.error("CSV parsing error: #{inspect(e)}")
      {:error, Error.csv_error(:parse_failed, "CSV parsing failed: #{inspect(e)}")}
  end

  # ============================================================================
  # Row Parsers
  # ============================================================================

  defp parse_ship_type_row(row) do
    [
      type_id_str,
      group_id_str,
      name,
      _description,
      mass_str,
      volume_str,
      capacity_str,
      portion_size_str,
      race_id_str,
      base_price_str,
      published_str,
      market_group_id_str,
      icon_id_str,
      sound_id_str,
      graphic_id_str | _rest
    ] = row

    %{
      type_id: parse_integer(type_id_str),
      group_id: parse_integer(group_id_str),
      name: String.trim(name),
      mass: parse_float(mass_str),
      volume: parse_float(volume_str),
      capacity: parse_float(capacity_str),
      portion_size: parse_integer(portion_size_str, 1),
      race_id: parse_integer(race_id_str),
      base_price: parse_float(base_price_str),
      published: parse_boolean(published_str),
      market_group_id: parse_integer(market_group_id_str),
      icon_id: parse_integer(icon_id_str),
      sound_id: parse_integer(sound_id_str),
      graphic_id: parse_integer(graphic_id_str)
    }
  rescue
    _ -> nil
  end

  defp parse_ship_group_row(row) do
    [
      group_id_str,
      category_id_str,
      name,
      icon_id_str,
      use_base_price_str,
      anchored_str,
      anchorable_str,
      fittable_non_singleton_str,
      published_str | _rest
    ] = row

    %{
      group_id: parse_integer(group_id_str),
      category_id: parse_integer(category_id_str),
      name: String.trim(name),
      icon_id: parse_integer(icon_id_str),
      use_base_price: parse_boolean(use_base_price_str),
      anchored: parse_boolean(anchored_str),
      anchorable: parse_boolean(anchorable_str),
      fittable_non_singleton: parse_boolean(fittable_non_singleton_str),
      published: parse_boolean(published_str)
    }
  rescue
    _ -> nil
  end

  # ============================================================================
  # Validation
  # ============================================================================

  defp validate_ship_types(%{records: records, stats: parse_stats}) do
    valid_group_ids = get_valid_ship_group_ids()

    validated_types =
      records
      |> Enum.filter(&valid_ship_type?/1)
      |> Enum.filter(fn type -> type.group_id in valid_group_ids end)
      |> Map.new(fn type -> {type.type_id, type} end)

    stats =
      Map.merge(parse_stats, %{
        validated_count: map_size(validated_types),
        validation_errors: length(records) - map_size(validated_types),
        valid_group_ids: valid_group_ids
      })

    Logger.info(
      "Ship type validation complete: #{stats.validated_count} valid types, " <>
        "#{stats.validation_errors} filtered out"
    )

    {:ok, %{ship_types: validated_types, stats: stats}}
  end

  defp validate_ship_groups(%{records: records, stats: parse_stats}) do
    validated_groups =
      records
      |> Enum.filter(&valid_ship_group?/1)
      |> Map.new(fn group -> {group.group_id, group} end)

    stats =
      Map.merge(parse_stats, %{
        validated_count: map_size(validated_groups),
        validation_errors: length(records) - map_size(validated_groups)
      })

    Logger.info(
      "Ship group validation complete: #{stats.validated_count} valid groups, " <>
        "#{stats.validation_errors} filtered out"
    )

    {:ok, %{ship_groups: validated_groups, stats: stats}}
  end

  defp valid_ship_type?(ship_type) when is_map(ship_type) do
    with true <- is_integer(ship_type[:type_id]) and ship_type[:type_id] > 0,
         true <- is_binary(ship_type[:name]) and ship_type[:name] != "",
         true <- is_integer(ship_type[:group_id]) and ship_type[:group_id] > 0,
         true <- is_number(ship_type[:mass]) and ship_type[:mass] >= 0,
         true <- is_number(ship_type[:volume]) and ship_type[:volume] >= 0 do
      true
    else
      _ -> false
    end
  end

  defp valid_ship_type?(_), do: false

  defp valid_ship_group?(ship_group) when is_map(ship_group) do
    with true <- is_integer(ship_group[:group_id]) and ship_group[:group_id] > 0,
         true <- is_integer(ship_group[:category_id]) and ship_group[:category_id] > 0,
         true <- is_binary(ship_group[:name]) and ship_group[:name] != "",
         true <- is_boolean(ship_group[:published]) do
      true
    else
      _ -> false
    end
  end

  defp valid_ship_group?(_), do: false

  # ============================================================================
  # Parsing Helpers
  # ============================================================================

  defp parse_integer(""), do: nil
  defp parse_integer(nil), do: nil

  defp parse_integer(str) when is_binary(str) do
    case Integer.parse(String.trim(str)) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_integer(str, default) when is_binary(str) do
    parse_integer(str) || default
  end

  defp parse_float(""), do: 0.0
  defp parse_float(nil), do: 0.0

  defp parse_float(str) when is_binary(str) do
    case Float.parse(String.trim(str)) do
      {float, _} -> float
      :error -> 0.0
    end
  end

  defp parse_boolean("1"), do: true
  defp parse_boolean("True"), do: true
  defp parse_boolean("true"), do: true
  defp parse_boolean(_), do: false

  # ============================================================================
  # Configuration
  # ============================================================================

  defp default_ship_group_ids do
    # Load from ship_group_ids.json if available
    case load_ship_group_ids() do
      {:ok, ids} -> ids
      # Fallback to hardcoded defaults
      _ -> [6, 7, 9, 11, 16, 17, 23]
    end
  end

  defp load_ship_group_ids do
    path = Application.app_dir(:wanderer_kills, ["priv", "data", "ship_group_ids.json"])

    with {:ok, content} <- File.read(path),
         {:ok, data} <- Jason.decode(content) do
      {:ok, data["valid_group_ids"] || []}
    else
      _ -> {:error, :not_found}
    end
  end
end
