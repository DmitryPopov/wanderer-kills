defmodule WandererKills.Ingest.Killmails.Pipeline.Enricher do
  @moduledoc """
  Enriches killmails with additional information.

  This module handles the enrichment of killmail data with additional
  information such as character, corporation, alliance, and ship details.
  It supports both sequential and parallel processing of attackers
  depending on the number of attackers in the killmail.
  """

  require Logger

  alias WandererKills.Core.ShipTypes.Info, as: ShipTypeInfo
  alias WandererKills.Ingest.ESI.Client, as: EsiClient
  alias WandererKills.Ingest.Killmails.Transformations

  # Compile-time configuration
  @min_attackers_for_parallel Application.compile_env(
                                :wanderer_kills,
                                [:enricher, :min_attackers_for_parallel],
                                3
                              )
  @max_concurrency Application.compile_env(:wanderer_kills, [:enricher, :max_concurrency], 10)
  @task_timeout_ms Application.compile_env(:wanderer_kills, [:enricher, :task_timeout_ms], 30_000)

  @doc """
  Enriches a killmail with additional information.

  ## Parameters
  - `killmail` - The killmail map to enrich

  ## Returns
  - `{:ok, enriched_killmail}` - On successful enrichment
  - `{:error, reason}` - On failure

  ## Examples

  ```elixir
  {:ok, enriched} = Enricher.enrich_killmail(raw_killmail)
  ```
  """
  @spec enrich_killmail(map()) :: {:ok, map()} | {:error, term()}
  def enrich_killmail(killmail) do
    with {:ok, killmail} <- enrich_victim(killmail),
         {:ok, killmail} <- enrich_attackers(killmail),
         {:ok, killmail} <- enrich_ship(killmail),
         {:ok, killmail} <- enrich_system(killmail),
         {:ok, killmail} <- flatten_enriched_data(killmail),
         {:ok, killmail} <- Transformations.enrich_with_ship_names(killmail),
         {:ok, killmail} <- Transformations.enrich_with_system_name(killmail) do
      {:ok, killmail}
    else
      error ->
        Logger.error("Failed to enrich killmail: #{inspect(error)}")
        error
    end
  end

  defp enrich_victim(killmail) do
    victim = Map.get(killmail, "victim", %{})

    with {:ok, character} <- get_character_info(Map.get(victim, "character_id")),
         {:ok, corporation} <- get_corporation_info(Map.get(victim, "corporation_id")) do
      # Alliance is optional - handle separately
      alliance = get_alliance_info_safe(Map.get(victim, "alliance_id"))

      victim =
        victim
        |> Map.put("character", character)
        |> Map.put("corporation", corporation)
        |> Map.put("alliance", alliance)

      killmail = Map.put(killmail, "victim", victim)
      {:ok, killmail}
    end
  end

  defp enrich_attackers(killmail) do
    attackers = Map.get(killmail, "attackers", [])

    enricher_config = %{
      min_attackers_for_parallel: @min_attackers_for_parallel,
      max_concurrency: @max_concurrency,
      task_timeout_ms: @task_timeout_ms
    }

    enriched_attackers =
      if length(attackers) >= enricher_config.min_attackers_for_parallel do
        process_attackers_parallel(attackers, enricher_config)
      else
        process_attackers_sequential(attackers)
      end

    {:ok, Map.put(killmail, "attackers", enriched_attackers)}
  end

  @spec process_attackers_parallel([map()], map()) :: [map()]
  defp process_attackers_parallel(attackers, enricher_config) when is_list(attackers) do
    Task.Supervisor.async_stream_nolink(
      WandererKills.TaskSupervisor,
      attackers,
      fn attacker ->
        case enrich_attacker(attacker) do
          {:ok, enriched} -> enriched
          {:error, _} -> nil
        end
      end,
      max_concurrency: enricher_config.max_concurrency,
      timeout: enricher_config.task_timeout_ms
    )
    |> Stream.map(fn
      {:ok, result} -> result
      {:exit, _} -> nil
    end)
    |> Stream.filter(& &1)
    |> Enum.to_list()
  end

  @spec process_attackers_sequential([map()]) :: [map()]
  defp process_attackers_sequential(attackers) when is_list(attackers) do
    Enum.map(attackers, fn attacker ->
      case enrich_attacker(attacker) do
        {:ok, enriched} -> enriched
        {:error, _} -> nil
      end
    end)
    |> Enum.filter(& &1)
  end

  @spec enrich_attacker(map()) :: {:ok, map()} | {:error, term()}
  defp enrich_attacker(attacker) do
    with {:ok, character} <- get_character_info(Map.get(attacker, "character_id")),
         {:ok, corporation} <- get_corporation_info(Map.get(attacker, "corporation_id")) do
      # Alliance is optional - handle separately
      alliance = get_alliance_info_safe(Map.get(attacker, "alliance_id"))

      attacker =
        attacker
        |> Map.put("character", character)
        |> Map.put("corporation", corporation)
        |> Map.put("alliance", alliance)

      {:ok, attacker}
    else
      error ->
        Logger.warning("Failed to enrich attacker: #{inspect(error)}")
        {:error, error}
    end
  end

  defp enrich_ship(killmail) do
    victim = Map.get(killmail, "victim", %{})
    ship_type_id = Map.get(victim, "ship_type_id")

    ship =
      case ShipTypeInfo.get_ship_type(ship_type_id) do
        {:ok, ship_data} -> ship_data
        _ -> nil
      end

    victim = Map.put(victim, "ship", ship)
    killmail = Map.put(killmail, "victim", victim)
    {:ok, killmail}
  end

  defp enrich_system(killmail) do
    system_id = Map.get(killmail, "system_id")

    system =
      case get_system_info(system_id) do
        {:ok, system_data} -> system_data
        _ -> nil
      end

    killmail = Map.put(killmail, "system", system)
    {:ok, killmail}
  end

  defp get_character_info(id) when is_integer(id), do: EsiClient.get_character(id)
  defp get_character_info(_), do: {:ok, nil}

  defp get_corporation_info(id) when is_integer(id), do: EsiClient.get_corporation(id)
  defp get_corporation_info(_), do: {:ok, nil}

  defp get_alliance_info(id) when is_integer(id) and id > 0, do: EsiClient.get_alliance(id)
  defp get_alliance_info(_), do: {:ok, nil}

  defp get_system_info(id) when is_integer(id), do: EsiClient.get_system(id)
  defp get_system_info(_), do: {:ok, nil}

  defp get_alliance_info_safe(id) when is_integer(id) do
    case get_alliance_info(id) do
      {:ok, alliance} -> alliance
      _ -> nil
    end
  end

  defp get_alliance_info_safe(_), do: nil

  defp flatten_enriched_data(killmail) do
    flattened =
      killmail
      |> Transformations.flatten_enriched_data()
      |> Transformations.add_attacker_count()

    {:ok, flattened}
  rescue
    error ->
      Logger.warning("Failed to flatten enriched data",
        error: inspect(error),
        killmail_id: killmail["killmail_id"]
      )

      # Return original killmail if flattening fails
      {:ok, killmail}
  end
end
