defmodule WandererKills.Core.ShipTypes.CSV do
  @moduledoc """
  Orchestration module for ship types CSV data processing.

  This module coordinates the parsing, validation, and caching of
  EVE Online ship type data from CSV files. It delegates specific
  responsibilities to specialized modules:

  - `Parser` - Handles CSV parsing and data extraction
  - `Validator` - Ensures data integrity and validity
  - `Cache` - Manages caching of processed data

  ## Usage

  ```elixir
  # Load and cache ship types from CSV files
  {:ok, count} = ShipTypes.CSV.load_ship_types()

  # Get a specific ship type
  {:ok, ship_type} = ShipTypes.CSV.get_ship_type(587)  # Rifter
  ```
  """

  require Logger

  alias WandererKills.Core.ShipTypes.{Cache, DataProcessor}
  alias WandererKills.Core.Support.Error
  alias WandererKills.Http.Client, as: HttpClient

  @required_files ["invTypes.csv", "invGroups.csv"]

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Loads ship types from CSV files and caches them.

  This is the main entry point for loading ship type data.
  It handles the complete process of:
  1. Locating/downloading CSV files
  2. Parsing the data
  3. Validating ship types
  4. Caching the results
  """
  @spec load_ship_types() :: {:ok, integer()} | {:error, Error.t()}
  def load_ship_types do
    with {:ok, file_paths} <- ensure_csv_files(),
         {:ok, ship_types_map} <- process_csv_files(file_paths),
         {:ok, count} <- Cache.warm_cache(ship_types_map) do
      Logger.info("[Ship Types] Loaded ship types from CSV", count: count)
      {:ok, count}
    else
      {:error, _reason} = error ->
        Logger.error("Failed to load ship types: #{inspect(error)}")
        error
    end
  end

  @doc """
  Gets a ship type by ID from cache.
  """
  @spec get_ship_type(integer()) :: {:ok, map()} | {:error, Error.t()}
  defdelegate get_ship_type(type_id), to: Cache

  @doc """
  Gets all ship types from cache.
  """
  @spec get_all_ship_types() :: {:ok, map()} | {:error, Error.t()}
  defdelegate get_all_ship_types(), to: Cache, as: :get_ship_types_map

  @doc """
  Checks if ship types are loaded in cache.
  """
  @spec ship_types_loaded?() :: boolean()
  def ship_types_loaded? do
    case Cache.get_ship_types_map() do
      {:ok, map} when map_size(map) > 0 -> true
      _ -> false
    end
  end

  @doc """
  Reloads ship types from CSV files.

  This clears the cache and reloads all data.
  """
  @spec reload_ship_types() :: {:ok, integer()} | {:error, Error.t()}
  def reload_ship_types do
    Logger.info("Reloading ship types")
    Cache.clear_cache()
    load_ship_types()
  end

  @doc """
  Compatibility function for Updater module.
  Updates ship types by loading them from CSV files.
  """
  @spec update_ship_types() :: :ok | {:error, Error.t()}
  def update_ship_types do
    case load_ship_types() do
      {:ok, _count} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  Downloads CSV files if missing.

  Options:
  - `:force_download` - Download even if files exist (default: false)
  """
  @spec download_csv_files(keyword()) :: {:ok, map()} | {:error, term()}
  def download_csv_files(opts \\ []) do
    force_download = Keyword.get(opts, :force_download, false)
    data_dir = get_data_directory()

    if force_download do
      Logger.info("Force downloading CSV files")
      # Delete existing files
      @required_files
      |> Enum.each(fn file ->
        data_dir
        |> Path.join(file)
        |> File.rm()
      end)
    end

    ensure_csv_files()
  end

  # ============================================================================
  # Private Functions - File Management
  # ============================================================================

  @spec ensure_csv_files() :: {:ok, map()} | {:error, Error.t()}
  defp ensure_csv_files do
    data_dir = get_data_directory()

    case get_missing_files(data_dir) do
      [] ->
        {:ok, get_file_paths(data_dir)}

      missing_files ->
        Logger.info("Missing CSV files: #{inspect(missing_files)}")

        case download_files(missing_files, data_dir) do
          :ok -> {:ok, get_file_paths(data_dir)}
          {:error, _} = error -> error
        end
    end
  end

  defp get_data_directory do
    Path.join([:code.priv_dir(:wanderer_kills), "data"])
  end

  defp get_missing_files(data_dir) do
    @required_files
    |> Enum.reject(fn file_name ->
      data_dir
      |> Path.join(file_name)
      |> File.exists?()
    end)
  end

  defp get_file_paths(data_dir) do
    %{
      types_path: Path.join(data_dir, "invTypes.csv"),
      groups_path: Path.join(data_dir, "invGroups.csv")
    }
  end

  @spec download_files(list(String.t()), String.t()) :: :ok | {:error, Error.t()}
  defp download_files(file_names, data_dir) do
    Logger.info("Downloading missing CSV files from fuzzwork.co.uk")

    # Ensure directory exists
    File.mkdir_p!(data_dir)

    results =
      file_names
      |> Enum.map(&download_single_file(&1, data_dir))

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> :ok
      error -> error
    end
  end

  defp download_single_file(file_name, data_dir) do
    url = "https://www.fuzzwork.co.uk/dump/latest/#{file_name}.bz2"
    output_path = Path.join(data_dir, file_name)

    Logger.info("Downloading #{file_name} from #{url}")

    with {:ok, compressed_data} <- download_file(url),
         {:ok, decompressed} <- decompress_bz2(compressed_data),
         :ok <- File.write(output_path, decompressed) do
      Logger.info("Successfully downloaded and saved #{file_name}")
      :ok
    else
      error ->
        Logger.error("Failed to download #{file_name}: #{inspect(error)}")

        {:error,
         Error.csv_error(:download_failed, "Failed to download #{file_name}", %{
           url: url,
           error: error
         })}
    end
  end

  defp download_file(url) do
    # Use centralized HTTP client for consistent error handling and rate limiting
    case HttpClient.get(url, [], timeout: 30_000) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decompress_bz2(compressed_data) do
    # Check if bzip2 is available
    case System.find_executable("bzip2") do
      nil ->
        {:error, "bzip2 command not found - please install bzip2 to decompress files"}

      _path ->
        # Use external bzip2 command since :bz2 module may not be available
        case write_temp_file(compressed_data, ".bz2") do
          {:ok, temp_path} ->
            try do
              case run_bzip2_decompress(temp_path) do
                {:ok, decompressed} -> {:ok, decompressed}
                error -> error
              end
            after
              # Always clean up temp file
              File.rm(temp_path)
            end

          error ->
            error
        end
    end
  end

  defp write_temp_file(data, extension) do
    # Use UUID for unique filename to avoid collisions
    uuid = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    temp_path = Path.join(System.tmp_dir!(), "wanderer_kills_#{uuid}#{extension}")

    case File.write(temp_path, data) do
      :ok -> {:ok, temp_path}
      error -> error
    end
  end

  defp run_bzip2_decompress(file_path) do
    case System.cmd("bzip2", ["-dc", file_path], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {error, _} -> {:error, "bzip2 decompression failed: #{error}"}
    end
  end

  # ============================================================================
  # Private Functions - Data Processing
  # ============================================================================

  @spec process_csv_files(map()) :: {:ok, map()} | {:error, Error.t()}
  defp process_csv_files(%{types_path: types_path, groups_path: groups_path}) do
    with {:ok, groups} <- parse_groups_file(groups_path),
         {:ok, types} <- parse_types_file(types_path),
         {:ok, ship_types_map} <- build_ship_types_map(types, groups) do
      {:ok, ship_types_map}
    else
      {:error, _} = error -> error
    end
  end

  @spec parse_groups_file(String.t()) :: {:ok, map()} | {:error, Error.t()}
  defp parse_groups_file(groups_path) do
    with {:ok, groups} <- DataProcessor.process_ship_groups(groups_path) do
      {:ok, build_groups_map(groups)}
    end
  end

  @spec parse_types_file(String.t()) :: {:ok, list()} | {:error, Error.t()}
  defp parse_types_file(types_path) do
    case DataProcessor.process_ship_types(types_path) do
      {:ok, %{ship_types: types_map, stats: _stats}} ->
        # Convert map values to list
        {:ok, Map.values(types_map)}

      error ->
        error
    end
  end

  @spec build_groups_map(map()) :: map()
  defp build_groups_map(groups_map) when is_map(groups_map) do
    valid_group_ids = DataProcessor.get_valid_ship_group_ids()

    groups_map
    |> Enum.reduce(%{}, fn {group_id, group}, acc ->
      if group_id in valid_group_ids do
        Map.put(acc, group_id, group.name)
      else
        acc
      end
    end)
  end

  @spec build_ship_types_map(list(), map()) :: {:ok, map()}
  defp build_ship_types_map(types, groups_map) do
    valid_group_ids = DataProcessor.get_valid_ship_group_ids()

    ship_types_map =
      types
      |> Enum.filter(fn type -> type.group_id in valid_group_ids end)
      |> Enum.reduce(%{}, fn type, acc ->
        # Add group name from groups map
        enhanced_type = Map.put(type, :group_name, Map.get(groups_map, type.group_id, "Unknown"))
        Map.put(acc, type.type_id, enhanced_type)
      end)

    {:ok, ship_types_map}
  end
end
