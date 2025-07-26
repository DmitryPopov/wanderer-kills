# lib/wanderer_kills/ship_types/updater.ex
defmodule WandererKills.Core.ShipTypes.Updater do
  @moduledoc """
  Coordinates ship type updates from multiple sources.

  This module provides a unified interface for updating ship type data by
  delegating to source implementations. It tries CSV first for efficiency,
  then falls back to ESI if needed.

  ## Usage

  ```elixir
  # Update ship types with automatic fallback
  case WandererKills.Core.ShipTypes.Updater.update_ship_types() do
    :ok -> Logger.info("Ship types updated successfully")
    {:error, _reason} -> Logger.error("Failed to update ship types")
  end

  # Force update from specific source
  WandererKills.Core.ShipTypes.Updater.update_with_csv()
  WandererKills.Core.ShipTypes.Updater.update_with_esi()
  ```

  ## Strategy

  1. **CSV First**: Attempts to update from local/downloaded CSV files for speed
  2. **ESI Fallback**: Falls back to ESI API if CSV update fails
  3. **Error Handling**: Provides detailed error reporting for each method

  ## Dependencies

  - `WandererKills.Core.ShipTypes.CSV` - CSV-based updates
  - `WandererKills.Ingest.ESI.Client` - ESI-based updates
  """

  require Logger

  alias WandererKills.Core.ShipTypes.CSV
  alias WandererKills.Core.Support.Error
  alias WandererKills.Ingest.ESI.Client, as: EsiSource

  # ============================================================================
  # Constants
  # ============================================================================

  @doc """
  Lists all ship group IDs that contain ship types.

  These group IDs represent different categories of ships in EVE Online:
  - 6: Titan
  - 7: Dreadnought
  - 9: Battleship
  - 11: Battlecruiser
  - 16: Cruiser
  - 17: Destroyer
  - 23: Frigate

  ## Returns
  List of ship group IDs
  """
  @spec ship_group_ids() :: [pos_integer()]
  def ship_group_ids, do: [6, 7, 9, 11, 16, 17, 23]

  @doc """
  Gets the base URL for EVE DB dumps.

  ## Returns
  String URL for downloading EVE DB dump files
  """
  @spec eve_db_dump_url() :: String.t()
  def eve_db_dump_url do
    Application.get_env(:wanderer_kills, :services, [])
    |> Keyword.get(:eve_db_dump_url, "https://www.fuzzwork.co.uk/dump/latest/")
  end

  @doc """
  Lists the required CSV files for ship type data.

  ## Returns
  List of CSV file names required for ship type processing
  """
  @spec required_csv_files() :: [String.t()]
  def required_csv_files, do: ["invGroups.csv", "invTypes.csv"]

  @doc """
  Gets the default maximum concurrency for batch operations.

  ## Returns
  Integer representing maximum concurrent tasks
  """
  @spec default_max_concurrency() :: pos_integer()
  def default_max_concurrency, do: 10

  @doc """
  Gets the default task timeout in milliseconds.

  ## Returns
  Integer representing timeout in milliseconds
  """
  @spec default_task_timeout_ms() :: pos_integer()
  def default_task_timeout_ms, do: 30_000

  @doc """
  Gets the data directory path for storing CSV files.

  ## Returns
  String path to the data directory
  """
  @spec data_directory() :: String.t()
  def data_directory do
    Path.join([:code.priv_dir(:wanderer_kills), "data"])
  end

  # ============================================================================
  # Ship Type Update Operations
  # ============================================================================

  @doc """
  Updates ship types by first trying CSV download, then falling back to ESI.

  This is the main entry point for ship type updates. It implements a fallback
  strategy where CSV is attempted first for efficiency, and ESI is used as a
  backup if CSV fails.

  ## Returns
  - `:ok` - If update completed successfully (from either source)
  - `{:error, reason}` - If both update methods failed

  ## Examples

  ```elixir
  case update_ship_types() do
    :ok ->
      Logger.info("Ship types updated successfully")
    {:error, _reason} ->
      Logger.error("All update methods failed")
  end
  ```
  """
  @spec update_ship_types() :: :ok | {:error, term()}
  def update_ship_types do
    case update_with_csv() do
      :ok ->
        :ok

      {:error, _} = csv_result ->
        Logger.warning("CSV update failed, falling back to ESI", error: csv_result)

        case update_with_esi() do
          :ok ->
            Logger.info("[Ship Types] Loaded ship types", source: :esi_fallback)
            :ok

          {:error, _} = esi_result ->
            Logger.error("Both CSV and ESI updates failed", %{
              csv_error: csv_result,
              esi_error: esi_result
            })

            {:error,
             Error.ship_types_error(
               :all_update_methods_failed,
               "Both CSV and ESI update methods failed",
               false,
               %{csv_error: csv_result, esi_error: esi_result}
             )}
        end
    end
  end

  @doc """
  Updates ship types using CSV data from EVE DB dumps.

  This method downloads (if needed) and processes CSV files containing
  ship type information. It's generally faster than ESI but requires
  external file downloads.

  ## Returns
  - `:ok` - If CSV update completed successfully
  - `{:error, reason}` - If CSV update failed

  ## Examples

  ```elixir
  case update_with_csv() do
    :ok -> Logger.info("CSV update successful")
    {:error, :download_failed} -> Logger.error("Failed to download CSV files")
    {:error, :parse_failed} -> Logger.error("Failed to parse CSV data")
  end
  ```
  """
  @spec update_with_csv() :: :ok | {:error, term()}
  def update_with_csv do
    case CSV.update_ship_types() do
      :ok ->
        :ok

      {:error, _reason} = error ->
        Logger.error("CSV ship type update failed: #{inspect(error)}")
        error
    end
  end

  @doc """
  Updates ship types using ESI API data.

  This method fetches ship type information directly from the EVE Swagger
  Interface. It's slower than CSV but more reliable for getting current data.

  ## Returns
  - `:ok` - If ESI update completed successfully
  - `{:error, reason}` - If ESI update failed

  ## Examples

  ```elixir
  case update_with_esi() do
    :ok -> Logger.info("ESI update successful")
    {:error, :batch_processing_failed} -> Logger.error("Some ship types failed to process")
    {:error, _reason} -> Logger.error("ESI update failed")
  end
  ```
  """
  @spec update_with_esi() :: :ok | {:error, term()}
  def update_with_esi do
    case EsiSource.update() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("ESI ship type update failed: #{inspect(reason)}")

        {:error,
         Error.ship_types_error(:esi_update_failed, "ESI ship type update failed", false, %{
           underlying_error: reason
         })}
    end
  end

  @doc """
  Updates ship types for specific ship groups using ESI.

  This method allows targeted updates of specific ship categories rather
  than processing all ship types.

  ## Parameters
  - `group_ids` - List of ship group IDs to update

  ## Returns
  - `:ok` - If update completed successfully
  - `{:error, reason}` - If update failed

  ## Examples

  ```elixir
  # Update only frigates and cruisers
  update_ship_groups([23, 16])

  # Update all known ship groups
  update_ship_groups(ship_group_ids())
  ```
  """
  @spec update_ship_groups([integer()]) :: :ok | {:error, term()}
  def update_ship_groups(group_ids) when is_list(group_ids) do
    Logger.debug("Updating specific ship groups: #{inspect(group_ids)}")
    EsiSource.update(group_ids: group_ids)
  end

  @doc """
  Downloads CSV files for offline processing.

  This is a utility function to pre-download CSV files without processing them.
  Useful for ensuring files are available before attempting CSV updates.

  ## Returns
  - `:ok` - If download completed successfully
  - `{:error, reason}` - If download failed

  ## Examples

  ```elixir
  case download_csv_files() do
    :ok -> Logger.info("CSV files downloaded and ready")
    {:error, _reason} -> Logger.error("Download failed")
  end
  ```
  """
  @spec download_csv_files() :: :ok | {:error, term()}
  def download_csv_files do
    Logger.debug("Downloading CSV files for ship type data")

    case CSV.download_csv_files(force_download: true) do
      {:ok, _file_paths} ->
        Logger.debug("CSV files downloaded successfully")
        :ok

      {:error, reason} ->
        Logger.error("Failed to download CSV files: #{inspect(reason)}")

        {:error,
         Error.ship_types_error(:csv_download_failed, "Failed to download CSV files", false, %{
           underlying_error: reason
         })}
    end
  end

  @doc """
  Gets configuration information for ship type updates.

  ## Returns
  Map containing configuration details

  ## Examples

  ```elixir
  config = get_configuration()
  # => %{
  #   ship_groups: [6, 7, 9, 11, 16, 17, 23],
  #   sources: %{csv: "CSV", esi: "ESI"},
  #   csv_files: ["invGroups.csv", "invTypes.csv"]
  # }
  ```
  """
  @spec get_configuration() :: map()
  def get_configuration do
    %{
      ship_groups: EsiSource.ship_group_ids(),
      sources: %{
        csv: "CSV",
        esi: EsiSource.source_name()
      },
      csv_files: ["invGroups.csv", "invTypes.csv"]
    }
  end
end
