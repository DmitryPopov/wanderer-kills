defmodule WandererKills.Core.ShipTypes.Cache do
  @moduledoc """
  Caching functionality for ship types data.

  This module handles all caching operations for ship types,
  including storage, retrieval, and warming of cache data.
  """

  require Logger
  alias WandererKills.Core.Cache
  alias WandererKills.Core.Support.Error

  @type ship_type :: map()
  @type cache_result :: {:ok, term()} | {:error, Error.t()}

  # Cache configuration - using default TTL from Helper module

  @doc """
  Stores a single ship type in the cache.
  """
  @spec put_ship_type(integer(), ship_type()) :: cache_result()
  def put_ship_type(type_id, ship_type) when is_integer(type_id) and is_map(ship_type) do
    case Cache.put(:esi_data, "ship_type:#{type_id}", ship_type) do
      {:ok, true} ->
        Logger.debug("Cached ship type #{type_id}")
        {:ok, ship_type}

      {:error, reason} ->
        Logger.error("Failed to cache ship type #{type_id}: #{inspect(reason)}")

        {:error,
         Error.cache_error(:write_failed, "Failed to cache ship type", %{
           type_id: type_id,
           reason: reason
         })}
    end
  end

  @doc """
  Retrieves a ship type from the cache by ID.
  """
  @spec get_ship_type(integer()) :: cache_result()
  def get_ship_type(type_id) when is_integer(type_id) do
    case Cache.get(:esi_data, "ship_type:#{type_id}") do
      {:error, %Error{type: :not_found}} ->
        {:error, Error.cache_error(:miss, "Ship type not found in cache", %{type_id: type_id})}

      {:ok, ship_type} ->
        {:ok, ship_type}

      {:error, reason} ->
        Logger.error("Failed to get ship type #{type_id} from cache: #{inspect(reason)}")

        {:error,
         Error.cache_error(:read_failed, "Failed to read from cache", %{
           type_id: type_id,
           reason: reason
         })}
    end
  end

  @doc """
  Stores the complete ship types map in cache.

  This is used for quick lookups of all ship types at once.
  """
  @spec put_ship_types_map(map()) :: cache_result()
  def put_ship_types_map(ship_types_map) when is_map(ship_types_map) do
    case Cache.put(:esi_data, "ship_types_map", ship_types_map) do
      {:ok, true} ->
        Logger.debug("Successfully cached #{map_size(ship_types_map)} ship types")
        {:ok, ship_types_map}

      {:error, reason} ->
        Logger.error("Failed to cache ship types map: #{inspect(reason)}")

        {:error,
         Error.cache_error(:write_failed, "Failed to cache ship types map", %{
           count: map_size(ship_types_map),
           reason: reason
         })}
    end
  end

  @doc """
  Retrieves the complete ship types map from cache.
  """
  @spec get_ship_types_map() :: cache_result()
  def get_ship_types_map do
    case Cache.get(:esi_data, "ship_types_map") do
      {:error, %Error{type: :not_found}} ->
        {:error, Error.cache_error(:miss, "Ship types map not found in cache")}

      {:ok, ship_types_map} ->
        {:ok, ship_types_map}

      {:error, reason} ->
        Logger.error("Failed to get ship types map from cache: #{inspect(reason)}")

        {:error,
         Error.cache_error(:read_failed, "Failed to read ship types map", %{
           reason: reason
         })}
    end
  end

  @doc """
  Stores multiple ship types in cache efficiently.

  Uses batch operations for better performance.
  """
  @spec put_ship_types_batch([{integer(), ship_type()}]) :: cache_result()
  def put_ship_types_batch(ship_types) when is_list(ship_types) do
    results =
      ship_types
      |> Enum.map(fn {type_id, ship_type} ->
        put_ship_type(type_id, ship_type)
      end)

    failed =
      Enum.count(results, fn
        {:error, _} -> true
        _ -> false
      end)

    if failed > 0 do
      Logger.warning("Failed to cache #{failed} out of #{length(ship_types)} ship types")
    end

    {:ok, length(ship_types) - failed}
  end

  @doc """
  Checks if a ship type exists in cache.
  """
  @spec has_ship_type?(integer()) :: boolean()
  def has_ship_type?(type_id) when is_integer(type_id) do
    case Cache.exists?(:esi_data, "ship_type:#{type_id}") do
      {:ok, exists} -> exists
      {:error, _} -> false
    end
  end

  @doc """
  Warms the cache with ship types data.

  This is typically called during application startup or
  after updating ship type data.
  """
  @spec warm_cache(map()) :: cache_result()
  def warm_cache(ship_types_map) when is_map(ship_types_map) do
    Logger.debug("Warming ship types cache with #{map_size(ship_types_map)} entries")

    # Store the complete map for quick access
    case put_ship_types_map(ship_types_map) do
      {:ok, _} ->
        # Also store individual ship types for direct lookups
        ship_types_list = Map.to_list(ship_types_map)

        {:ok, count} = put_ship_types_batch(ship_types_list)
        Logger.debug("Cache warming complete: #{count} ship types cached")
        {:ok, count}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Clears all ship type data from cache.
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    Logger.info("Clearing ship types cache")

    # Clear the map
    Cache.delete(:esi_data, "ship_types_map")

    # Note: Individual ship type entries will expire naturally
    # due to TTL. Clearing them all would require pattern matching
    # which is expensive in most cache implementations.

    :ok
  end

  @doc """
  Gets cache statistics for ship types.
  """
  @spec get_cache_stats() :: map()
  def get_cache_stats do
    map_exists =
      case get_ship_types_map() do
        {:ok, map} -> %{exists: true, count: map_size(map)}
        _ -> %{exists: false, count: 0}
      end

    %{
      namespace: :ship_types,
      ship_types_map: map_exists
    }
  end
end
