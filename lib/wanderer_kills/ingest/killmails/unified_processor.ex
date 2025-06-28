defmodule WandererKills.Ingest.Killmails.UnifiedProcessor do
  @moduledoc """
  Unified killmail processing that handles both full and partial killmails.

  This module eliminates the duplication between full and partial killmail
  processing by providing a single entry point that automatically detects
  the killmail type and processes accordingly.
  """

  require Logger

  alias WandererKills.Core.Observability.Monitoring
  alias WandererKills.Core.Storage.KillmailStore
  alias WandererKills.Core.Support.Error
  alias WandererKills.Domain.Killmail
  alias WandererKills.Ingest.Killmails.Enrichment.BatchEnricher
  alias WandererKills.Ingest.Killmails.Pipeline.{DataBuilder, ESIFetcher, Validator}
  alias WandererKills.Ingest.Killmails.Transformations

  @type process_options :: [
          store: boolean(),
          enrich: boolean(),
          validate_only: boolean()
        ]
  @type process_result :: {:ok, Killmail.t()} | {:ok, :kill_older} | {:error, term()}

  @doc """
  Processes any killmail, automatically detecting if it's full or partial.

  ## Parameters
  - `killmail` - The killmail data (full or partial)
  - `cutoff_time` - DateTime cutoff for filtering old killmails
  - `opts` - Processing options:
    - `:store` - Whether to store the killmail (default: true)
    - `:enrich` - Whether to enrich with ESI data (default: true)
    - `:validate_only` - Only validate, don't process (default: false)

  ## Returns
  - `{:ok, processed_killmail}` - Killmail struct on successful processing
  - `{:ok, :kill_older}` - When killmail is older than cutoff
  - `{:error, reason}` - On failure
  """
  @spec process_killmail(map(), DateTime.t(), process_options()) :: process_result()
  def process_killmail(killmail, cutoff_time, opts \\ []) when is_map(killmail) do
    # Normalize field names first
    normalized = Transformations.normalize_field_names(killmail)

    # Process based on killmail type using pattern matching
    normalized
    |> determine_and_process_killmail(cutoff_time, opts)
    |> monitor_processing_result()
  end

  # Pattern match for partial killmails (zkb data but no victim/attackers)
  defp determine_and_process_killmail(%{"zkb" => _zkb} = killmail, cutoff_time, opts)
       when not is_map_key(killmail, "victim") and not is_map_key(killmail, "attackers") do
    process_partial(killmail, cutoff_time, opts)
  end

  # Pattern match for full killmails (has victim and attackers)
  defp determine_and_process_killmail(
         %{"victim" => _, "attackers" => _} = killmail,
         cutoff_time,
         opts
       )
       when is_map_key(killmail, "system_id") or is_map_key(killmail, "solar_system_id") do
    process_full(killmail, cutoff_time, opts)
  end

  # Catch-all for unknown formats
  defp determine_and_process_killmail(_killmail, _cutoff_time, _opts) do
    {:error, Error.killmail_error(:invalid_format, "Unknown killmail format")}
  end

  # Extract monitoring logic to separate function
  defp monitor_processing_result({:ok, :kill_older} = result) do
    Logger.debug("[UnifiedProcessor] Monitoring: killmail too old, incrementing skipped")
    Monitoring.increment_skipped()
    result
  end

  defp monitor_processing_result({:ok, _killmail} = result) do
    Logger.debug(
      "[UnifiedProcessor] Monitoring: killmail processed successfully, incrementing stored"
    )

    Monitoring.increment_stored()
    result
  end

  defp monitor_processing_result({:error, reason} = result) do
    Logger.debug(
      "[UnifiedProcessor] Monitoring: killmail processing failed with error: #{inspect(reason)}"
    )

    result
  end

  @doc """
  Processes a batch of killmails concurrently.

  ## Parameters
  - `killmails` - List of killmail data
  - `cutoff_time` - DateTime cutoff for filtering
  - `opts` - Processing options

  ## Returns
  - `{:ok, processed_killmails}` - List of successfully processed killmails
  """
  @spec process_batch([map()], DateTime.t(), process_options()) :: {:ok, [Killmail.t()]}
  def process_batch(killmails, cutoff_time, opts \\ []) when is_list(killmails) do
    enrich? = Keyword.get(opts, :enrich, true)
    store? = Keyword.get(opts, :store, true)
    validate_only? = Keyword.get(opts, :validate_only, false)

    # Process all killmails through validation and data building first
    validated_killmails =
      killmails
      |> Enum.map(&Transformations.normalize_field_names/1)
      |> Enum.map(&validate_and_build_killmail(&1, cutoff_time))
      |> collect_valid_killmails()

    if validate_only? do
      {:ok, convert_to_structs(validated_killmails)}
    else
      # Batch enrich all valid killmails if enrichment is enabled
      final_killmails = apply_enrichment(validated_killmails, enrich?)

      # Store killmails if requested
      if store? do
        Enum.each(final_killmails, &store_killmail_async/1)
      end

      # Convert to structs
      result_killmails = convert_to_structs(final_killmails)

      # Monitoring is handled at the entry point level
      {:ok, result_killmails}
    end
  end

  # Private functions

  defp process_partial(partial, cutoff_time, opts) do
    case {partial["killmail_id"], partial["zkb"]} do
      {id, zkb} when is_integer(id) and is_map(zkb) ->
        Logger.debug("Processing partial killmail", killmail_id: id)

        case fetch_and_merge_partial(id, zkb, partial) do
          {:ok, merged} ->
            process_full(merged, cutoff_time, opts)

          {:error, reason} ->
            Logger.error("Failed to fetch full killmail data",
              killmail_id: id,
              error: reason
            )

            {:error, reason}
        end

      _ ->
        {:error,
         Error.killmail_error(
           :invalid_partial_format,
           "Partial killmail must have killmail_id and zkb fields"
         )}
    end
  end

  defp process_full(killmail, cutoff_time, opts) do
    killmail_id = Transformations.get_killmail_id(killmail)

    Logger.debug("Processing full killmail",
      killmail_id: killmail_id,
      store: Keyword.get(opts, :store, true),
      enrich: Keyword.get(opts, :enrich, true),
      validate_only: Keyword.get(opts, :validate_only, false)
    )

    # Delegate to process_batch for consistent validation and processing
    case process_batch([killmail], cutoff_time, opts) do
      {:ok, [result]} -> {:ok, result}
      {:ok, []} -> {:ok, :kill_older}
    end
  end

  defp store_killmail_async(killmail) do
    # Convert struct to map for storage if needed
    killmail_map = ensure_map(killmail)

    case extract_system_id(killmail_map) do
      {:ok, system_id} ->
        Task.Supervisor.start_child(WandererKills.TaskSupervisor, fn ->
          Logger.debug("Storing killmail asynchronously",
            killmail_id: killmail_map["killmail_id"],
            system_id: system_id
          )

          KillmailStore.put(killmail_map["killmail_id"], system_id, killmail_map)
        end)

      {:error, reason} ->
        Logger.error("Cannot store killmail without system_id",
          killmail_id: killmail_map["killmail_id"],
          error: reason
        )

        {:error, reason}
    end
  end

  defp extract_system_id(%Killmail{system_id: id}) when not is_nil(id), do: {:ok, id}
  defp extract_system_id(%{"solar_system_id" => id}) when not is_nil(id), do: {:ok, id}
  defp extract_system_id(%{"system_id" => id}) when not is_nil(id), do: {:ok, id}

  defp extract_system_id(killmail) do
    killmail_id = get_killmail_id(killmail)
    Logger.warning("Killmail missing system_id", killmail_id: killmail_id)
    {:error, :missing_system_id}
  end

  defp get_killmail_id(%Killmail{killmail_id: id}), do: id
  defp get_killmail_id(%{"killmail_id" => id}), do: id
  defp get_killmail_id(_), do: nil

  defp validate_and_build_killmail(killmail, cutoff_time) do
    case Validator.validate_killmail(killmail, cutoff_time) do
      {:ok, validated} ->
        DataBuilder.build_killmail_data(validated)

      error ->
        error
    end
  end

  defp collect_valid_killmails(results) do
    results
    |> Enum.reduce([], fn
      {:ok, killmail}, acc -> [killmail | acc]
      {:error, %Error{type: :kill_too_old}}, acc -> acc
      {:error, _}, acc -> acc
    end)
    |> Enum.reverse()
  end

  defp fetch_and_merge_partial(id, zkb, partial) do
    case ESIFetcher.fetch_full_killmail(id, zkb) do
      {:ok, full_data} ->
        Logger.debug("ESI data fetched",
          killmail_id: id,
          esi_keys: Map.keys(full_data) |> Enum.sort(),
          has_killmail_time: Map.has_key?(full_data, "killmail_time"),
          has_kill_time: Map.has_key?(full_data, "kill_time")
        )

        # Normalize field names before merging
        normalized_data = Transformations.normalize_field_names(full_data)

        Logger.debug("After normalization",
          killmail_id: id,
          normalized_keys: Map.keys(normalized_data) |> Enum.sort(),
          has_kill_time: Map.has_key?(normalized_data, "kill_time")
        )

        DataBuilder.merge_killmail_data(normalized_data, partial)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  defp apply_enrichment(validated_killmails, enrich?) do
    # Determine which killmails to return and cache
    killmails_to_process =
      if enrich? and not Enum.empty?(validated_killmails) do
        case BatchEnricher.enrich_killmails_batch(validated_killmails) do
          {:ok, enriched} ->
            enriched

          {:error, reason} ->
            Logger.error("Failed to enrich killmails batch",
              error: reason,
              batch_size: length(validated_killmails)
            )

            # Fall back to unenriched killmails
            validated_killmails
        end
      else
        validated_killmails
      end

    # Cache all killmails once
    Enum.each(killmails_to_process, &ESIFetcher.cache_enriched_killmail/1)

    killmails_to_process
  end

  # Helper function for struct conversion

  defp convert_to_structs(killmails) do
    Enum.map(killmails, fn killmail ->
      case Killmail.new(killmail) do
        {:ok, struct} ->
          struct

        {:error, reason} ->
          # Log error but don't fail the entire batch
          Logger.error("Failed to convert killmail to struct",
            killmail_id: killmail["killmail_id"],
            error: reason
          )

          raise "Failed to convert killmail #{killmail["killmail_id"]} to struct: #{inspect(reason)}"
      end
    end)
  end

  defp ensure_map(%Killmail{} = killmail), do: Killmail.to_map(killmail)
  defp ensure_map(map) when is_map(map), do: map
end
