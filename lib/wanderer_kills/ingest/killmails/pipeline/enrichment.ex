defmodule WandererKills.Ingest.Killmails.Pipeline.Enrichment do
  @moduledoc """
  Unified enrichment stage for killmail processing.

  This module consolidates the functionality of the old DataBuilder and Enricher
  modules into a single, more efficient stage that:

  - Enriches victim data with character/corporation/alliance info
  - Enriches attacker data (sequential or parallel based on count)
  - Adds ship type information and names
  - Adds system information and names
  - Optimizes API calls and caching
  - Handles errors gracefully with fallbacks

  ## Enrichment Strategy

  - **Small killmails** (< 3 attackers): Sequential processing
  - **Large killmails** (≥ 3 attackers): Parallel processing
  - **Caching**: All ESI responses are cached to reduce API calls
  - **Fallbacks**: Missing data doesn't fail the entire enrichment
  """

  require Logger

  alias WandererKills.Ingest.ESI.Client, as: EsiClient
  alias WandererKills.Ingest.Killmails.Transformations

  # Configuration from compile time
  @min_attackers_for_parallel Application.compile_env(
                                :wanderer_kills,
                                [:enricher, :min_attackers_for_parallel],
                                3
                              )
  @max_concurrency Application.compile_env(:wanderer_kills, [:enricher, :max_concurrency], 10)
  @task_timeout_ms Application.compile_env(:wanderer_kills, [:enricher, :task_timeout_ms], 30_000)

  @type killmail :: map()
  @type enrichment_result :: {:ok, killmail()} | {:error, term()}

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Enriches a validated killmail with additional information from ESI.

  ## Enrichment Process

  1. Enrich victim with character/corporation/alliance data
  2. Enrich attackers (parallel if many, sequential if few)
  3. Add ship type information and names
  4. Add system information and names
  5. Flatten and optimize the final structure

  ## Parameters
  - `killmail` - Validated killmail from the Validation stage

  ## Returns
  - `{:ok, enriched_killmail}` - On successful enrichment
  - `{:error, reason}` - On enrichment failure (rarely fails completely)
  """
  @spec enrich_killmail(killmail()) :: enrichment_result()
  def enrich_killmail(killmail) when is_map(killmail) do
    killmail_id = killmail["killmail_id"]
    attacker_count = length(killmail["attackers"] || [])

    Logger.debug("Starting killmail enrichment",
      killmail_id: killmail_id,
      attacker_count: attacker_count,
      parallel: attacker_count >= @min_attackers_for_parallel
    )

    start_time = System.monotonic_time(:millisecond)

    result =
      {:ok, killmail}
      |> enrich_victim()
      |> enrich_attackers()
      |> enrich_ship_information()
      |> enrich_system_information()
      |> finalize_enrichment()

    duration = System.monotonic_time(:millisecond) - start_time

    # Since all enrichment functions return {:ok, _} even on failure,
    # we can directly pattern match
    {:ok, enriched} = result

    Logger.debug("Enrichment completed successfully",
      killmail_id: killmail_id,
      duration_ms: duration
    )

    {:ok, enriched}
  end

  # ============================================================================
  # Private Enrichment Functions
  # ============================================================================

  # Step 1: Enrich victim data
  defp enrich_victim({:ok, killmail}) do
    victim = killmail["victim"] || %{}

    enriched_victim =
      victim
      |> enrich_character_data()
      |> enrich_corporation_data()
      |> enrich_alliance_data()

    {:ok, Map.put(killmail, "victim", enriched_victim)}
  rescue
    error ->
      Logger.warning("Failed to enrich victim data",
        killmail_id: killmail["killmail_id"],
        error: inspect(error)
      )

      # Don't fail the entire enrichment for victim enrichment failures
      {:ok, killmail}
  end

  # Step 2: Enrich attackers data
  defp enrich_attackers({:ok, killmail}) do
    attackers = killmail["attackers"] || []

    enriched_attackers =
      if length(attackers) >= @min_attackers_for_parallel do
        enrich_attackers_parallel(attackers)
      else
        enrich_attackers_sequential(attackers)
      end

    {:ok, Map.put(killmail, "attackers", enriched_attackers)}
  rescue
    error ->
      Logger.warning("Failed to enrich attackers data",
        killmail_id: killmail["killmail_id"],
        error: inspect(error)
      )

      # Don't fail the entire enrichment for attacker enrichment failures
      {:ok, killmail}
  end

  # Step 3: Enrich ship information
  defp enrich_ship_information({:ok, killmail}) do
    enriched =
      killmail
      |> Transformations.enrich_with_ship_names()
      |> case do
        {:ok, with_ship_names} ->
          with_ship_names

        {:error, _} ->
          Logger.warning("Failed to enrich ship names", killmail_id: killmail["killmail_id"])
          killmail
      end

    {:ok, enriched}
  end

  # Step 4: Enrich system information
  defp enrich_system_information({:ok, killmail}) do
    {:ok, enriched} = Transformations.enrich_with_system_name(killmail)
    {:ok, enriched}
  end

  # Step 5: Finalize enrichment
  defp finalize_enrichment({:ok, killmail}) do
    # Flatten any nested enrichment data and ensure consistent structure
    finalized =
      killmail
      |> flatten_enriched_data()
      |> add_computed_fields()
      |> clean_temporary_fields()

    {:ok, finalized}
  end

  # ============================================================================
  # Character/Corporation/Alliance Enrichment
  # ============================================================================

  defp enrich_character_data(entity) do
    case Map.get(entity, "character_id") do
      nil ->
        entity

      character_id ->
        case get_character_info(character_id) do
          {:ok, character_info} -> Map.put(entity, "character", character_info)
          {:error, _} -> entity
        end
    end
  end

  defp enrich_corporation_data(entity) do
    case Map.get(entity, "corporation_id") do
      nil ->
        entity

      corp_id ->
        case get_corporation_info(corp_id) do
          {:ok, corp_info} -> Map.put(entity, "corporation", corp_info)
          {:error, _} -> entity
        end
    end
  end

  defp enrich_alliance_data(entity) do
    case Map.get(entity, "alliance_id") do
      nil ->
        entity

      alliance_id ->
        case get_alliance_info(alliance_id) do
          {:ok, alliance_info} -> Map.put(entity, "alliance", alliance_info)
          # Alliance is optional
          {:error, _} -> entity
        end
    end
  end

  # ============================================================================
  # Attacker Enrichment (Sequential vs Parallel)
  # ============================================================================

  defp enrich_attackers_sequential(attackers) do
    Enum.map(attackers, fn attacker ->
      attacker
      |> enrich_character_data()
      |> enrich_corporation_data()
      |> enrich_alliance_data()
    end)
  end

  defp enrich_attackers_parallel(attackers) do
    attackers
    |> Task.async_stream(
      fn attacker ->
        attacker
        |> enrich_character_data()
        |> enrich_corporation_data()
        |> enrich_alliance_data()
      end,
      max_concurrency: @max_concurrency,
      timeout: @task_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, enriched_attacker} ->
        enriched_attacker

      {:exit, _reason} ->
        Logger.warning("Attacker enrichment task timed out")
        # Return empty map for failed enrichment
        %{}
    end)
  end

  # ============================================================================
  # ESI API Calls with Error Handling
  # ============================================================================

  defp get_character_info(character_id) when is_integer(character_id) do
    case EsiClient.get_character(character_id) do
      {:ok, character_data} ->
        {:ok, character_data}

      {:error, reason} ->
        Logger.debug("Failed to fetch character info",
          character_id: character_id,
          reason: reason
        )

        {:error, reason}
    end
  end

  defp get_character_info(_), do: {:error, :invalid_character_id}

  defp get_corporation_info(corp_id) when is_integer(corp_id) do
    case EsiClient.get_corporation(corp_id) do
      {:ok, corp_data} ->
        {:ok, corp_data}

      {:error, reason} ->
        Logger.debug("Failed to fetch corporation info",
          corporation_id: corp_id,
          reason: reason
        )

        {:error, reason}
    end
  end

  defp get_corporation_info(_), do: {:error, :invalid_corporation_id}

  defp get_alliance_info(alliance_id) when is_integer(alliance_id) do
    case EsiClient.get_alliance(alliance_id) do
      {:ok, alliance_data} ->
        {:ok, alliance_data}

      {:error, reason} ->
        Logger.debug("Failed to fetch alliance info",
          alliance_id: alliance_id,
          reason: reason
        )

        {:error, reason}
    end
  end

  defp get_alliance_info(_), do: {:error, :invalid_alliance_id}

  # ============================================================================
  # Data Structure Optimization
  # ============================================================================

  defp flatten_enriched_data(killmail) do
    # Flatten any deeply nested structures that may have been created
    # during enrichment to keep the final structure clean
    killmail
    |> flatten_victim_data()
    |> flatten_attackers_data()
  end

  defp flatten_victim_data(killmail) do
    victim = killmail["victim"] || %{}

    # Move character name to top level for easier access
    flattened_victim =
      case get_in(victim, ["character", "name"]) do
        nil -> victim
        name -> Map.put(victim, "character_name", name)
      end

    Map.put(killmail, "victim", flattened_victim)
  end

  defp flatten_attackers_data(killmail) do
    attackers = killmail["attackers"] || []

    # Add character names to top level for easier access
    flattened_attackers =
      Enum.map(attackers, fn attacker ->
        case get_in(attacker, ["character", "name"]) do
          nil -> attacker
          name -> Map.put(attacker, "character_name", name)
        end
      end)

    Map.put(killmail, "attackers", flattened_attackers)
  end

  defp add_computed_fields(killmail) do
    # Add commonly accessed computed fields
    killmail
    |> add_final_blow_attacker()
    |> add_damage_statistics()
    |> add_involved_parties_count()
  end

  defp add_final_blow_attacker(killmail) do
    final_blow =
      killmail["attackers"]
      |> Enum.find(&Map.get(&1, "final_blow", false))

    case final_blow do
      nil -> killmail
      attacker -> Map.put(killmail, "final_blow_attacker", attacker)
    end
  end

  defp add_damage_statistics(killmail) do
    total_damage =
      killmail["attackers"]
      |> Enum.map(&Map.get(&1, "damage_done", 0))
      |> Enum.sum()

    Map.put(killmail, "total_damage", total_damage)
  end

  defp add_involved_parties_count(killmail) do
    # +1 for victim
    involved_count = length(killmail["attackers"] || []) + 1
    Map.put(killmail, "involved_parties", involved_count)
  end

  defp clean_temporary_fields(killmail) do
    # Remove any temporary fields that were used during processing
    # but shouldn't be in the final structure
    killmail
    |> Map.delete("_temp_enrichment_data")
    |> Map.delete("_processing_metadata")
  end
end
