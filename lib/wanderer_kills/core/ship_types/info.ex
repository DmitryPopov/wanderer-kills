defmodule WandererKills.Core.ShipTypes.Info do
  @moduledoc """
  Ship type information handler for the ship types domain.

  This module provides ship type data access by leveraging
  the existing ESI caching infrastructure and CSV data sources.
  """

  require Logger
  alias WandererKills.Core.Cache
  alias WandererKills.Core.ShipTypes.Updater
  alias WandererKills.Core.Support.Error
  alias WandererKills.Ingest.ESI.Client

  @doc """
  Gets ship type information from the ESI cache.

  This function first tries to get the data from cache, and if not found,
  falls back to ESI API as needed.
  """
  @spec get_ship_type(integer()) :: {:ok, map()} | {:error, term()}
  def get_ship_type(type_id) when is_integer(type_id) and type_id > 0 do
    case Cache.get(:esi_data, "ship_type:#{type_id}") do
      {:ok, _data} = result ->
        result

      {:error, %{type: :not_found}} ->
        # Fall back to ESI for items not in the CSV (like deployables, structures, etc.)
        Logger.debug("Ship type #{type_id} not in cache, fetching from ESI")

        case fetch_from_esi(type_id) do
          {:ok, data} = result ->
            # Cache the result for future use
            Cache.put(:esi_data, "ship_type:#{type_id}", data)
            result

          error ->
            error
        end

      error ->
        error
    end
  end

  def get_ship_type(_type_id) do
    {:error, Error.ship_types_error(:invalid_type_id, "Type ID must be a positive integer")}
  end

  @doc """
  Warms the cache with CSV data if needed.

  This is called during application startup to populate the cache
  with local CSV data before relying on ESI API calls.
  """
  @spec warm_cache() :: :ok | {:error, term()}
  def warm_cache do
    Logger.debug("Warming ship type cache with CSV data")

    # Use the updater which handles downloading missing CSV files
    case Updater.update_with_csv() do
      :ok ->
        Logger.debug("Successfully warmed cache with CSV data")
        :ok

      {:error, _reason} = error ->
        Logger.warning("Failed to warm cache with CSV data: #{inspect(error)}")
        # Don't fail if CSV loading fails - ESI fallback will work
        :ok
    end
  end

  # Private function to fetch type data from ESI
  @spec fetch_from_esi(integer()) :: {:ok, map()} | {:error, term()}
  defp fetch_from_esi(type_id) do
    case Client.get_type(type_id) do
      {:ok, data} ->
        # Transform the ESI response to match our expected format
        {:ok, data}

      {:error, %{type: :not_found}} = error ->
        Logger.debug("Type #{type_id} not found in ESI")
        error

      {:error, reason} = error ->
        Logger.warning("Failed to fetch type #{type_id} from ESI: #{inspect(reason)}")
        error
    end
  end
end
