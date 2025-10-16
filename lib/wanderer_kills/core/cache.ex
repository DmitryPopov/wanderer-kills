defmodule WandererKills.Core.Cache do
  @moduledoc """
  Simplified cache operations with a streamlined namespace system.

  This module provides a unified interface for all cache operations with
  a simplified 4-namespace approach that reduces complexity while maintaining
  clear separation of data types.

  ## New Simplified Approach

  All cache operations follow the same pattern:
  - `get(namespace, id)` - Get a value
  - `put(namespace, id, value)` - Store a value
  - `delete(namespace, id)` - Delete a value
  - `exists?(namespace, id)` - Check if key exists

  ## Simplified Namespaces (Reduced from 8 to 4)

  - `:killmails` - Killmail data (5min TTL)
  - `:systems` - System-related data (1hr TTL)
  - `:esi_data` - All ESI data: characters, corps, alliances, ships (24hr TTL)
  - `:temp_data` - Temporary processing data (5min TTL)

  ## Cache Strategy

  - **Hot data** (killmails, systems): Short TTL, high frequency access
  - **ESI data**: Long TTL, consolidated namespace for all external API data
  - **Temporary data**: Short TTL for processing artifacts
  """

  require Logger
  alias WandererKills.Core.Support.Error

  @cache_name :wanderer_cache
  @cache_adapter Application.compile_env(:wanderer_kills, :cache_adapter, Cachex)

  # Simplified namespace configurations with clear TTLs
  @namespace_config %{
    killmails: %{ttl: :timer.minutes(5)},
    systems: %{ttl: :timer.hours(1)},
    esi_data: %{ttl: :timer.hours(24)},
    temp_data: %{ttl: :timer.minutes(5)}
  }

  @type namespace :: :killmails | :systems | :esi_data | :temp_data
  @type id :: String.t() | integer()
  @type value :: any()
  @type error :: {:error, Error.t()}

  # ============================================================================
  # Core Operations
  # ============================================================================

  @doc """
  Get a value from cache.

  Returns `{:ok, value}` if found, `{:error, %Error{}}` if not found.
  """
  @spec get(namespace(), id()) :: {:ok, value()} | error()
  def get(namespace, id) when is_atom(namespace) do
    key = build_key(namespace, id)

    case cache_adapter().get(@cache_name, key) do
      {:ok, nil} ->
        {:error, Error.cache_error(:not_found, "Key not found", %{namespace: namespace, id: id})}

      {:ok, value} ->
        {:ok, value}

      {:error, reason} ->
        Logger.error("Cache get failed", namespace: namespace, id: id, error: reason)
        {:error, Error.cache_error(:get_failed, "Failed to get from cache", %{reason: reason})}
    end
  end

  @doc """
  Store a value in cache with namespace-specific TTL.
  """
  @spec put(namespace(), id(), value()) :: {:ok, boolean()} | error()
  def put(namespace, id, value) when is_atom(namespace) do
    key = build_key(namespace, id)
    ttl = get_ttl(namespace)

    case cache_adapter().put(@cache_name, key, value, ttl: ttl) do
      {:ok, _} = result ->
        result

      {:error, reason} ->
        Logger.error("Cache put failed", namespace: namespace, id: id, error: reason)
        {:error, Error.cache_error(:put_failed, "Failed to put to cache", %{reason: reason})}
    end
  end

  @doc """
  Delete a value from cache.
  """
  @spec delete(namespace(), id()) :: {:ok, boolean()} | error()
  def delete(namespace, id) when is_atom(namespace) do
    key = build_key(namespace, id)

    case cache_adapter().del(@cache_name, key) do
      {:ok, _} = result ->
        result

      {:error, reason} ->
        Logger.error("Cache delete failed", namespace: namespace, id: id, error: reason)

        {:error,
         Error.cache_error(:delete_failed, "Failed to delete from cache", %{reason: reason})}
    end
  end

  @doc """
  Check if a key exists in cache.
  """
  @spec exists?(namespace(), id()) :: {:ok, boolean()} | error()
  def exists?(namespace, id) when is_atom(namespace) do
    key = build_key(namespace, id)

    case cache_adapter().exists?(@cache_name, key) do
      {:ok, exists} ->
        {:ok, exists}

      {:error, reason} ->
        Logger.error("Cache exists? failed", namespace: namespace, id: id, error: reason)

        {:error,
         Error.cache_error(:exists_failed, "Failed to check existence", %{reason: reason})}
    end
  end

  # ============================================================================
  # Convenience Functions for ESI Data
  # ============================================================================

  @doc """
  Convenience function for ESI character data.
  """
  @spec get_character(integer()) :: {:ok, map()} | error()
  def get_character(character_id) when is_integer(character_id) do
    get(:esi_data, "character:#{character_id}")
  end

  @doc """
  Convenience function for storing ESI character data.
  """
  @spec put_character(integer(), map()) :: {:ok, boolean()} | error()
  def put_character(character_id, character_data) when is_integer(character_id) do
    put(:esi_data, "character:#{character_id}", character_data)
  end

  @doc """
  Convenience function for ESI corporation data.
  """
  @spec get_corporation(integer()) :: {:ok, map()} | error()
  def get_corporation(corp_id) when is_integer(corp_id) do
    get(:esi_data, "corporation:#{corp_id}")
  end

  @doc """
  Convenience function for storing ESI corporation data.
  """
  @spec put_corporation(integer(), map()) :: {:ok, boolean()} | error()
  def put_corporation(corp_id, corp_data) when is_integer(corp_id) do
    put(:esi_data, "corporation:#{corp_id}", corp_data)
  end

  @doc """
  Convenience function for ESI alliance data.
  """
  @spec get_alliance(integer()) :: {:ok, map()} | error()
  def get_alliance(alliance_id) when is_integer(alliance_id) do
    get(:esi_data, "alliance:#{alliance_id}")
  end

  @doc """
  Convenience function for storing ESI alliance data.
  """
  @spec put_alliance(integer(), map()) :: {:ok, boolean()} | error()
  def put_alliance(alliance_id, alliance_data) when is_integer(alliance_id) do
    put(:esi_data, "alliance:#{alliance_id}", alliance_data)
  end

  @doc """
  Convenience function for ship type data.
  """
  @spec get_ship_type(integer()) :: {:ok, map()} | error()
  def get_ship_type(ship_type_id) when is_integer(ship_type_id) do
    get(:esi_data, "ship:#{ship_type_id}")
  end

  @doc """
  Convenience function for storing ship type data.
  """
  @spec put_ship_type(integer(), map()) :: {:ok, boolean()} | error()
  def put_ship_type(ship_type_id, ship_data) when is_integer(ship_type_id) do
    put(:esi_data, "ship:#{ship_type_id}", ship_data)
  end

  # ============================================================================
  # Batch Operations
  # ============================================================================

  @doc """
  Get multiple values at once for better performance.
  """
  @spec get_many(namespace(), [id()]) :: %{id() => value()}
  def get_many(namespace, ids) when is_atom(namespace) and is_list(ids) do
    # Fetch cache entries concurrently for better performance
    ids
    |> Task.async_stream(
      fn id ->
        case get(namespace, id) do
          {:ok, value} -> {id, value}
          {:error, _} -> nil
        end
      end,
      max_concurrency: System.schedulers_online() * 2
    )
    |> Stream.filter(fn {:ok, result} -> result != nil end)
    |> Enum.reduce(%{}, fn {:ok, {id, value}}, acc ->
      Map.put(acc, id, value)
    end)
  end

  @doc """
  Get or set a value with a function.

  This function first attempts to retrieve a value from the cache. If the value
  is found, it is returned. If not found, the provided callback function is
  executed to generate the value, which is then stored in the cache and returned.

  ## Callback Return Values

  The callback function can return values in the following formats:

  - `{:ok, value}` - Success tuple format. The value will be cached and returned.
  - `{:error, reason}` - Error tuple format. The error is propagated without caching.
  - `value` - Raw value format. The value will be cached and wrapped in `{:ok, value}`.

  ## Examples

      # Callback returning {:ok, value}
      get_or_set(:my_namespace, "key", fn ->
        {:ok, expensive_computation()}
      end)
      
      # Callback returning raw value
      get_or_set(:my_namespace, "key", fn ->
        "simple_value"
      end)
      
      # Callback returning error
      get_or_set(:my_namespace, "key", fn ->
        {:error, :computation_failed}
      end)
  """
  @spec get_or_set(namespace(), id(), (-> {:ok, value()} | {:error, any()})) ::
          {:ok, value()} | {:error, any()}
  def get_or_set(namespace, id, fun) when is_atom(namespace) and is_function(fun, 0) do
    case get(namespace, id) do
      {:ok, value} ->
        {:ok, value}

      {:error, %Error{type: :not_found}} ->
        case fun.() do
          {:ok, value} ->
            put(namespace, id, value)
            {:ok, value}

          {:error, reason} ->
            {:error, reason}

          value ->
            # Handle functions that return raw values instead of tuples
            put(namespace, id, value)
            {:ok, value}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Clear all entries for a specific namespace.
  """
  @spec clear_namespace(namespace()) :: :ok
  def clear_namespace(namespace) when is_atom(namespace) do
    case @cache_adapter do
      Cachex ->
        # Use Cachex.stream for Cachex adapter
        stream = Cachex.stream(@cache_name, [])

        stream
        |> Stream.filter(fn {key, _} -> String.starts_with?(key, "#{namespace}:") end)
        |> Stream.each(fn {key, _} -> Cachex.del(@cache_name, key) end)
        |> Stream.run()
    end

    :ok
  end

  # ============================================================================
  # Private Helper Functions
  # ============================================================================

  # Build cache key with simplified format
  defp build_key(namespace, id) do
    "#{namespace}:#{id}"
  end

  # Get TTL for namespace
  defp get_ttl(namespace) do
    case Map.get(@namespace_config, namespace) do
      %{ttl: ttl} -> ttl
      # Default TTL
      nil -> :timer.hours(1)
    end
  end

  # Runtime function to get cache adapter
  defp cache_adapter do
    @cache_adapter
  end

  # ============================================================================
  # Statistics and Monitoring
  # ============================================================================

  @doc """
  Get cache statistics for monitoring.
  """
  @spec stats() :: map()
  def stats do
    case cache_adapter().stats(@cache_name) do
      {:ok, stats} -> stats
      {:error, _} -> %{}
    end
  end

  @doc """
  Get cache size information.
  """
  @spec size() :: integer()
  def size do
    case cache_adapter().size(@cache_name) do
      {:ok, size} -> size
      {:error, _} -> 0
    end
  end

  @doc """
  Get namespace-specific statistics.
  """
  @spec namespace_stats(namespace()) :: map()
  def namespace_stats(namespace) when is_atom(namespace) do
    {count, total_size} =
      case @cache_adapter do
        Cachex ->
          # Use Cachex.stream for Cachex adapter
          stream = Cachex.stream(@cache_name, [])
          calculate_cachex_namespace_stats(stream, namespace)
      end

    %{
      namespace: namespace,
      entry_count: count,
      total_size_bytes: total_size,
      ttl: get_ttl(namespace)
    }
  end

  # ============================================================================
  # Legacy Functions for Backward Compatibility
  # ============================================================================

  @doc """
  Health check for cache system.
  """
  @spec health() :: :ok | {:error, any()}
  def health do
    case cache_adapter().exists?(@cache_name, "health_check") do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  List system killmails (legacy compatibility).
  """
  def list_system_killmails(system_id) do
    case get(:systems, "killmails:#{system_id}") do
      {:ok, killmails} when is_list(killmails) -> {:ok, killmails}
      # Handle corrupted data
      {:ok, _invalid_data} -> {:ok, []}
      {:error, %Error{type: :not_found}} -> {:ok, []}
      {:error, _} = error -> error
    end
  end

  @doc """
  Mark system as fetched (legacy compatibility).
  """
  def mark_system_fetched(system_id, timestamp \\ DateTime.utc_now()) do
    case timestamp do
      ts when is_integer(ts) ->
        # Legacy support: store integer timestamps under "fetched:" key
        put(:systems, "fetched:#{system_id}", ts)

      %DateTime{} = dt ->
        # New behavior: store DateTime under "last_fetch:" key
        put(:systems, "last_fetch:#{system_id}", dt)

      _ ->
        # Default: convert to DateTime and use new key
        dt = DateTime.utc_now()
        put(:systems, "last_fetch:#{system_id}", dt)
    end
  end

  @doc """
  Check if system was fetched recently.
  """
  def system_fetched_recently?(system_id, threshold_seconds \\ 3600) do
    # Check new key format first
    case get(:systems, "last_fetch:#{system_id}") do
      {:ok, %DateTime{} = timestamp} ->
        # Calculate time difference in seconds
        diff = DateTime.diff(DateTime.utc_now(), timestamp)
        diff < threshold_seconds

      {:error, %Error{type: :not_found}} ->
        # Check legacy key format
        case get(:systems, "fetched:#{system_id}") do
          {:ok, timestamp} when is_integer(timestamp) ->
            # Handle legacy millisecond timestamps
            threshold_ms = threshold_seconds * 1000
            current_time = :os.system_time(:millisecond)
            current_time - timestamp < threshold_ms

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp calculate_cachex_namespace_stats(stream, namespace) do
    stream
    |> filter_namespace_keys(namespace)
    |> Enum.reduce({0, 0}, fn {_key, value}, {count, size} ->
      value_size = :erlang.external_size(value)
      {count + 1, size + value_size}
    end)
  end

  defp filter_namespace_keys(stream, namespace) do
    Stream.filter(stream, fn {key, _} -> String.starts_with?(key, "#{namespace}:") end)
  end

  @doc """
  Get active systems (legacy compatibility).
  """
  def get_active_systems do
    case get(:systems, "active_systems") do
      {:ok, systems} -> {:ok, systems}
      {:error, _} -> {:ok, []}
    end
  end

  @doc """
  Add active system (legacy compatibility).
  """
  def add_active_system(system_id) do
    {:ok, systems} = get_active_systems()

    updated_systems =
      systems
      |> MapSet.new()
      |> MapSet.put(system_id)
      |> MapSet.to_list()

    put(:systems, "active_systems", updated_systems)
  end

  @doc """
  Add system killmail (legacy compatibility).
  """
  def add_system_killmail(system_id, killmail_id) do
    current_killmails =
      case list_system_killmails(system_id) do
        {:ok, killmails} when is_list(killmails) -> killmails
        _ -> []
      end

    # Check if killmail already exists to avoid duplicates
    if killmail_id in current_killmails do
      put(:systems, "killmails:#{system_id}", current_killmails)
    else
      # Prepend new killmail to maintain reverse chronological order
      updated_killmails = [killmail_id | current_killmails]
      put(:systems, "killmails:#{system_id}", updated_killmails)
    end
  end
end
