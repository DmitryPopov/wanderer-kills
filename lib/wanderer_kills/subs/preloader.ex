defmodule WandererKills.Subs.Preloader do
  @moduledoc """
  Shared preload logic for killmails across different channels.

  This module consolidates the common preload functionality used by:
  - WebSocket channels (KillmailChannel)
  - Webhook subscriptions (SubscriptionManager)

  It provides consistent killmail preloading with:
  - Cache-first approach
  - Fallback to fresh fetch from ZKillboard
  - Enrichment through the pipeline
  - Time-based filtering
  - Consistent logging
  """

  require Logger

  alias WandererKills.Core.Cache
  alias WandererKills.Core.Systems.KillmailProcessor
  alias WandererKills.Domain.Killmail
  alias WandererKills.Ingest.Killmails.{ZkbClient, UnifiedProcessor}
  alias WandererKills.Ingest.{SmartRateLimiter, RequestCoalescer}

  @type system_id :: integer()
  @type character_id :: integer()
  @type killmail :: Killmail.t()
  @type limit :: pos_integer()
  @type hours :: pos_integer()
  @type days :: pos_integer()

  @doc """
  Preloads kills for a system with a specified limit.

  This function:
  1. Checks cache for existing killmail IDs
  2. If not found, fetches fresh kills from ZKillboard
  3. Enriches the killmails through the pipeline
  4. Returns the most recent enriched killmails up to the limit

  ## Parameters
    - `system_id` - The EVE Online solar system ID
    - `limit` - Maximum number of kills to return
    - `since_hours` - How many hours back to fetch (for fresh fetches)

  ## Returns
    - List of enriched killmail structs
  """
  @spec preload_kills_for_system(system_id(), limit(), hours()) :: [Killmail.t()]
  def preload_kills_for_system(system_id, limit, since_hours \\ 24) do
    Logger.debug("[DEBUG] Preloading kills for system",
      system_id: system_id,
      limit: limit,
      since_hours: since_hours
    )

    result =
      case Cache.list_system_killmails(system_id) do
        {:ok, killmail_ids} when is_list(killmail_ids) and killmail_ids != [] ->
          Logger.debug("[DEBUG] Found cached killmails, using cache",
            system_id: system_id,
            cached_count: length(killmail_ids)
          )

          get_enriched_killmails(killmail_ids, limit)

        _ ->
          Logger.debug("[DEBUG] No cached killmails found, fetching fresh data",
            system_id: system_id
          )

          fetch_and_cache_fresh_kills(system_id, limit, since_hours)
      end

    Logger.debug("[DEBUG] Preload completed",
      system_id: system_id,
      returned_count: length(result),
      requested_limit: limit
    )

    result
  end

  @doc """
  Preloads kills for characters with specified options.

  This function:
  1. Fetches killmails for each character from ZKillboard
  2. Enriches the killmails through the pipeline
  3. Returns killmails sorted by timestamp in batches

  ## Parameters
    - `character_ids` - List of EVE Online character IDs
    - `opts` - Keyword list of options:
      - `:days` - Number of days of history (default: 90, max: 90)
      - `:batch_size` - Size of batches to return (default: 50)

  ## Returns
    - List of lists, where each inner list is a batch of enriched killmails
  """
  @spec preload_kills_for_characters([character_id()], keyword()) :: [[Killmail.t()]]
  def preload_kills_for_characters(character_ids, opts \\ []) do
    days = Keyword.get(opts, :days, 90) |> min(90) |> max(1)
    batch_size = Keyword.get(opts, :batch_size, 50) |> max(1)

    Logger.info("[Preloader] Starting character killmail preload",
      character_ids: character_ids,
      days: days,
      batch_size: batch_size
    )

    # Fetch killmails for all characters in parallel
    all_killmails =
      character_ids
      |> Task.async_stream(
        fn char_id -> fetch_character_kills(char_id, days) end,
        max_concurrency: 3,
        timeout: 60_000
      )
      |> Enum.reduce([], fn
        {:ok, kills}, acc ->
          acc ++ kills

        {:exit, reason}, acc ->
          Logger.error("[Preloader] Task failed", reason: inspect(reason))
          acc
      end)
      |> Enum.uniq_by(& &1.killmail_id)
      |> Enum.sort_by(& &1.kill_time, {:desc, DateTime})

    # Split into batches
    batches = Enum.chunk_every(all_killmails, batch_size)

    Logger.info("[Preloader] Character preload complete",
      total_kills: length(all_killmails),
      batch_count: length(batches)
    )

    batches
  end

  @doc """
  Preloads kills for systems with specified options.

  This function:
  1. Fetches killmails for each system
  2. Enriches the killmails through the pipeline
  3. Returns killmails sorted by timestamp in batches

  ## Parameters
    - `system_ids` - List of EVE Online system IDs
    - `opts` - Keyword list of options:
      - `:days` - Number of days of history (default: 90, max: 90)
      - `:batch_size` - Size of batches to return (default: 50)

  ## Returns
    - List of lists, where each inner list is a batch of enriched killmails
  """
  @spec preload_kills_for_systems([system_id()], keyword()) :: [[Killmail.t()]]
  def preload_kills_for_systems(system_ids, opts \\ []) do
    days = Keyword.get(opts, :days, 90) |> min(90) |> max(1)
    batch_size = Keyword.get(opts, :batch_size, 50) |> max(1)
    hours = days * 24

    Logger.info("[Preloader] Starting system killmail preload",
      system_ids: system_ids,
      days: days,
      batch_size: batch_size
    )

    # For systems, we can fetch more efficiently using the existing function
    system_limit =
      Application.get_env(:wanderer_kills, :preloader)[:system_historical_limit] || 1000

    all_killmails =
      system_ids
      |> Enum.flat_map(fn system_id ->
        # Use configurable limit for historical data
        preload_kills_for_system(system_id, system_limit, hours)
      end)
      |> Enum.uniq_by(& &1.killmail_id)
      |> Enum.sort_by(& &1.kill_time, {:desc, DateTime})

    # Split into batches
    batches = Enum.chunk_every(all_killmails, batch_size)

    Logger.info("[Preloader] System preload complete",
      total_kills: length(all_killmails),
      batch_count: length(batches)
    )

    batches
  end

  defp fetch_character_kills(character_id, days) do
    Logger.debug("[Preloader] Fetching kills for character",
      character_id: character_id,
      days: days
    )

    past_seconds = days * 24 * 60 * 60

    case fetch_character_kills_smart(character_id, past_seconds) do
      {:ok, raw_kills} when is_list(raw_kills) ->
        Logger.debug("[Preloader] Processing character kills",
          character_id: character_id,
          kill_count: length(raw_kills)
        )

        # Process through enrichment pipeline
        enriched_kills =
          raw_kills
          |> Enum.map(&enrich_single_killmail/1)
          |> Enum.filter(&match?({:ok, _}, &1))
          |> Enum.map(fn {:ok, kill} -> kill end)

        Logger.debug("[Preloader] Character kills enriched",
          character_id: character_id,
          enriched_count: length(enriched_kills)
        )

        enriched_kills

      {:error, reason} ->
        Logger.error("[Preloader] Failed to fetch character kills",
          character_id: character_id,
          error: inspect(reason)
        )

        []
    end
  end

  defp fetch_character_kills_smart(character_id, _past_seconds) do
    # For now, just use ZkbClient directly for character killmails
    # TODO: Implement smart rate limiting for character endpoints
    #   - Similar to SmartRateLimiter.request_system_killmails/3
    #   - Support character-specific rate limiting to prevent API exhaustion
    #   - Integrate with RequestCoalescer for deduplication
    #   - Consider character-specific circuit breakers
    #   - Tracking issue: Character rate limiting implementation needed
    ZkbClient.get_character_killmails(character_id)
  end

  defp enrich_single_killmail(raw_kill) do
    # Use a far future cutoff time to ensure we don't filter by age
    cutoff_time = DateTime.add(DateTime.utc_now(), 365 * 24 * 60 * 60, :second)

    case UnifiedProcessor.process_killmail(raw_kill, cutoff_time, store: false, enrich: true) do
      {:ok, enriched} ->
        {:ok, enriched}

      {:error, reason} ->
        Logger.warning("[Preloader] Failed to enrich killmail",
          killmail_id: raw_kill["killmail_id"],
          error: inspect(reason)
        )

        {:error, reason}
    end
  end

  @doc """
  Gets enriched killmails from cache by their IDs.

  ## Parameters
    - `killmail_ids` - List of killmail IDs to get
    - `limit` - Maximum number of kills to return
    - `filter_recent` - Whether to filter by recency (default: true)

  ## Returns
    - List of enriched killmail structs
  """
  @spec get_enriched_killmails([integer()], limit(), boolean()) :: [Killmail.t()]
  def get_enriched_killmails(killmail_ids, limit, filter_recent \\ true) do
    Logger.debug("[DEBUG] get_enriched_killmails called", %{
      killmail_ids_count: length(killmail_ids),
      limit: limit,
      filter_recent: filter_recent
    })

    # Only include kills from the last hour if filtering is enabled
    cutoff_time =
      if filter_recent do
        now = DateTime.utc_now()
        cutoff = DateTime.add(now, -1 * 60 * 60, :second)

        Logger.debug("[DEBUG] Calculated cutoff time for filtering", %{
          current_time: DateTime.to_iso8601(now),
          cutoff_time: DateTime.to_iso8601(cutoff),
          hours_back: 1
        })

        cutoff
      else
        nil
      end

    fetched_kills =
      killmail_ids
      # Take more to account for filtering
      |> Enum.take(limit * 2)
      |> Enum.map(&get_single_enriched_killmail/1)
      |> Enum.reduce([], fn
        {:ok, killmail}, acc ->
          Logger.debug("[DEBUG] Retrieved killmail from cache", %{
            killmail_id: killmail["killmail_id"]
          })

          [killmail | acc]

        {:error, reason}, acc ->
          Logger.debug("[DEBUG] Failed to retrieve killmail from cache", %{
            error: inspect(reason)
          })

          acc
      end)

    Logger.debug("[DEBUG] Fetched kills before filtering",
      count: length(fetched_kills)
    )

    result =
      fetched_kills
      |> Enum.reverse()
      |> maybe_filter_recent(cutoff_time)
      |> Enum.take(limit)

    Logger.debug("[DEBUG] Final result after filtering",
      count: length(result)
    )

    result
  end

  @doc """
  Extracts kill times from a list of killmails.

  Handles both `kill_time` and legacy `killmail_time` fields.
  """
  @spec extract_kill_times([Killmail.t() | map()]) :: [String.t()]
  def extract_kill_times(kills) do
    Enum.map(kills, fn
      %Killmail{kill_time: time} ->
        if time, do: to_string(time), else: "unknown"

      kill_map when is_map(kill_map) ->
        # Handle map case - try to extract kill_time directly
        case kill_map["kill_time"] || kill_map[:kill_time] do
          nil -> "unknown"
          time -> to_string(time)
        end

      _ ->
        "unknown"
    end)
  end

  @doc """
  Counts how many kills have enriched data (character names).

  A kill is considered enriched if it has:
  - Victim character name, OR
  - At least one attacker with a character name
  """
  @spec count_enriched_kills([Killmail.t() | map()]) :: non_neg_integer()
  def count_enriched_kills(kills) do
    Enum.count(kills, &enriched_kill?/1)
  end

  defp enriched_kill?(kill) do
    case ensure_killmail_struct(kill) do
      %Killmail{} = killmail -> has_character_names?(killmail)
      _ -> false
    end
  end

  defp has_character_names?(%Killmail{victim: victim, attackers: attackers}) do
    has_victim_name?(victim) or has_attacker_with_name?(attackers)
  end

  defp has_victim_name?(nil), do: false
  defp has_victim_name?(victim), do: victim.character_name != nil

  defp has_attacker_with_name?(attackers) do
    Enum.any?(attackers, fn attacker -> attacker.character_name != nil end)
  end

  @doc """
  Checks if a killmail is recent enough based on cutoff time.
  """
  @spec killmail_recent?(Killmail.t() | map(), DateTime.t()) :: boolean()

  # Handle map input by converting to struct first
  def killmail_recent?(killmail_map, cutoff_time)
      when is_map(killmail_map) and not is_struct(killmail_map) do
    case ensure_killmail_struct(killmail_map) do
      %Killmail{} = killmail ->
        killmail_recent?(killmail, cutoff_time)

      _ ->
        Logger.warning("[WARNING] Failed to convert killmail map to struct in killmail_recent?",
          killmail_id: killmail_map["killmail_id"] || killmail_map[:killmail_id]
        )

        false
    end
  end

  def killmail_recent?(%Killmail{killmail_id: killmail_id, kill_time: kill_time}, cutoff_time) do
    case kill_time do
      %DateTime{} = dt ->
        result = DateTime.compare(dt, cutoff_time) == :gt

        Logger.debug("[DEBUG] Checking if killmail is recent",
          killmail_id: killmail_id,
          kill_time: DateTime.to_iso8601(dt),
          cutoff_time: DateTime.to_iso8601(cutoff_time),
          comparison_result: DateTime.compare(dt, cutoff_time),
          is_recent: result
        )

        result

      time_string when is_binary(time_string) ->
        case DateTime.from_iso8601(time_string) do
          {:ok, dt, _offset} ->
            result = DateTime.compare(dt, cutoff_time) == :gt

            Logger.debug("[DEBUG] Checking if killmail is recent (parsed from string)",
              killmail_id: killmail_id,
              kill_time_string: time_string,
              kill_time_parsed: DateTime.to_iso8601(dt),
              cutoff_time: DateTime.to_iso8601(cutoff_time),
              comparison_result: DateTime.compare(dt, cutoff_time),
              is_recent: result
            )

            result

          {:error, _} ->
            Logger.error("Failed to parse kill_time",
              killmail_id: killmail_id,
              kill_time: time_string
            )

            false
        end

      nil ->
        Logger.error("Enriched killmail missing kill_time",
          killmail_id: killmail_id
        )

        false

      other ->
        Logger.error("Enriched killmail has invalid kill_time format",
          killmail_id: killmail_id,
          kill_time_type: inspect(other),
          kill_time_value: inspect(other, limit: 100)
        )

        false
    end
  end

  @doc """
  Logs a summary of preloaded kills.
  """
  @spec log_preload_summary(map(), system_id(), [Killmail.t()]) :: :ok
  def log_preload_summary(context, system_id, kills) do
    killmail_ids = Enum.map(kills, & &1.killmail_id)
    kill_times = extract_kill_times(kills)
    enriched_count = count_enriched_kills(kills)

    Logger.debug(
      "[DEBUG] Preload summary",
      Map.merge(context, %{
        system_id: system_id,
        kill_count: length(kills),
        killmail_ids: killmail_ids,
        enriched_count: enriched_count,
        unenriched_count: length(kills) - enriched_count,
        kill_time_range: kill_time_range(kill_times)
      })
    )

    log_sample_kill(kills)
    :ok
  end

  # Private functions

  defp ensure_killmail_struct(%Killmail{} = killmail), do: killmail

  defp ensure_killmail_struct(killmail_map) when is_map(killmail_map) do
    case Killmail.new(killmail_map) do
      {:ok, killmail} ->
        killmail

      {:error, reason} ->
        Logger.warning("[WARNING] Failed to convert killmail map to struct",
          killmail_id: killmail_map["killmail_id"] || killmail_map[:killmail_id],
          error: inspect(reason)
        )

        nil
    end
  end

  defp ensure_killmail_struct(_), do: nil

  defp fetch_and_cache_fresh_kills(system_id, limit, since_hours) do
    Logger.debug("[DEBUG] Fetching fresh kills from ZKillboard",
      system_id: system_id,
      limit: limit,
      since_hours: since_hours
    )

    # Convert since_hours to options for the new API
    past_seconds = since_hours * 3600
    opts = [past_seconds: past_seconds, limit: 50]

    case fetch_system_kills_smart(system_id, opts, :preload) do
      {:ok, fresh_kills} when is_list(fresh_kills) ->
        # Only process the number of kills we need for preload
        kills_to_cache = Enum.take(fresh_kills, limit)

        Logger.debug("[DEBUG] Processing fresh kills through pipeline",
          system_id: system_id,
          fetched_count: length(fresh_kills),
          processing_count: length(kills_to_cache)
        )

        # Cache the kills through the pipeline
        KillmailProcessor.process_system_killmails(system_id, kills_to_cache)

        Logger.debug("[DEBUG] Fresh kills cached successfully",
          system_id: system_id,
          cached_count: length(kills_to_cache)
        )

        # Now get the enriched killmails from cache
        case Cache.list_system_killmails(system_id) do
          {:ok, killmail_ids} when is_list(killmail_ids) ->
            Logger.debug("[DEBUG] Found killmail IDs for system",
              system_id: system_id,
              killmail_ids: killmail_ids,
              count: length(killmail_ids)
            )

            result = get_enriched_killmails(killmail_ids, limit)

            Logger.debug("[DEBUG] Fetched enriched killmails",
              system_id: system_id,
              requested_count: length(killmail_ids),
              returned_count: length(result)
            )

            result

          {:error, %{type: :not_found}} ->
            # This is expected when no killmails passed validation (e.g., all too old)
            Logger.debug("[DEBUG] No killmails were cached for system (likely all filtered out)",
              system_id: system_id
            )

            []

          {:error, reason} ->
            # Only warn for actual errors, not expected "not found" cases
            Logger.warning("[WARNING] Failed to get cached killmail IDs after caching",
              system_id: system_id,
              error: reason
            )

            []
        end

      {:error, reason} ->
        Logger.warning("[WARNING] Failed to fetch fresh kills for preload",
          system_id: system_id,
          error: reason
        )

        []
    end
  end

  defp fetch_system_kills_smart(system_id, opts, priority) do
    features = Application.get_env(:wanderer_kills, :features, [])

    if features[:smart_rate_limiting] do
      request_key = {:preload, system_id, opts}

      RequestCoalescer.request(request_key, fn ->
        SmartRateLimiter.request_system_killmails(
          system_id,
          opts,
          priority: priority,
          timeout: 30_000
        )
      end)
    else
      ZkbClient.fetch_system_killmails(system_id, opts)
    end
  end

  defp get_single_enriched_killmail(killmail_id) do
    result = Cache.get(:killmails, killmail_id)

    case result do
      {:ok, killmail} ->
        Logger.debug("[DEBUG] Successfully retrieved killmail from cache",
          killmail_id: killmail_id,
          has_kill_time: Map.has_key?(killmail, "kill_time"),
          kill_time: Map.get(killmail, "kill_time")
        )

      {:error, reason} ->
        Logger.debug("[DEBUG] Failed to retrieve killmail from cache",
          killmail_id: killmail_id,
          error: inspect(reason)
        )
    end

    result
  end

  defp maybe_filter_recent(kills, nil), do: kills

  defp maybe_filter_recent(kills, cutoff_time) do
    Enum.filter(kills, fn killmail ->
      # Convert map to struct if needed
      killmail_struct = ensure_killmail_struct(killmail)

      case killmail_struct do
        %Killmail{} = km -> killmail_recent?(km, cutoff_time)
        # Skip if conversion fails
        _ -> false
      end
    end)
  end

  defp kill_time_range([]), do: "no kills"

  defp kill_time_range(times) do
    "#{List.first(times)} to #{List.last(times)}"
  end

  defp log_sample_kill([]), do: :ok

  defp log_sample_kill([sample | _]) do
    # Convert to struct if needed
    case ensure_killmail_struct(sample) do
      %Killmail{} = killmail ->
        Logger.debug("[DEBUG] Sample kill data",
          killmail_id: killmail.killmail_id,
          victim_character: killmail.victim.character_name,
          victim_corp: killmail.victim.corporation_name,
          attacker_count: length(killmail.attackers),
          solar_system_id: killmail.system_id,
          total_value: killmail.zkb && killmail.zkb.total_value
        )

      _ ->
        Logger.debug("[DEBUG] Sample kill data (raw map)",
          data: inspect(sample, limit: 200)
        )
    end
  end
end
