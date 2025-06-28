defmodule WandererKillsWeb.KillsController do
  @moduledoc """
  Controller for kill-related API endpoints.

  This controller provides endpoints for fetching killmails, cached data,
  and kill counts as specified in the WandererKills API interface.
  """

  use Phoenix.Controller, namespace: WandererKillsWeb
  use OpenApiSpex.ControllerSpecs

  import WandererKillsWeb.Api.Validators
  require Logger
  alias WandererKills.Core.Client
  alias WandererKills.Core.Support.Error

  operation(:list,
    summary: "List kills for a system",
    description: "Fetches killmail data for a specific system with optional time filtering",
    parameters: [
      system_id: [
        in: :path,
        description: "EVE Online system ID",
        type: :integer,
        required: true,
        example: 30_000_142
      ],
      since_hours: [
        in: :query,
        description: "Fetch kills from the last N hours (default: 24)",
        type: :integer,
        required: false,
        example: 24
      ],
      limit: [
        in: :query,
        description: "Maximum number of kills to return",
        type: :integer,
        required: false,
        example: 100
      ]
    ],
    responses: %{
      200 => {"Success", "application/json", WandererKillsWeb.Schemas.KillsResponse},
      400 => {"Invalid parameters", "application/json", WandererKillsWeb.Schemas.Error},
      500 => {"Server error", "application/json", WandererKillsWeb.Schemas.Error}
    }
  )

  @doc """
  Lists kills for a specific system with time filtering.

  GET /api/v1/kills/system/:system_id?since_hours=X&limit=Y
  """
  @spec list(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def list(conn, %{"system_id" => system_id_str} = params) do
    with {:ok, system_id} <- validate_system_id(system_id_str),
         {:ok, since_hours} <- validate_since_hours(Map.get(params, "since_hours", "24")),
         {:ok, limit} <- validate_limit(Map.get(params, "limit")) do
      Logger.info("Fetching system kills",
        system_id: system_id,
        since_hours: since_hours,
        limit: limit
      )

      case Client.fetch_system_killmails(system_id, since_hours, limit) do
        {:ok, killmails} ->
          response = build_cached_response(killmails, false)
          render_success(conn, response)

        {:error, reason} ->
          Logger.error("Failed to fetch system kills",
            system_id: system_id,
            error: reason
          )

          render_error(conn, 500, "Failed to fetch system kills", "FETCH_ERROR", %{
            reason: inspect(reason)
          })
      end
    else
      {:error, %Error{}} ->
        render_error(conn, 400, "Invalid system ID format", "INVALID_SYSTEM_ID")
    end
  end

  @doc """
  Fetches kills for multiple systems.

  POST /api/v1/kills/systems
  Body: {"system_ids": [int], "since_hours": int, "limit": int}
  """
  @spec bulk(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def bulk(conn, params) do
    with {:ok, system_ids} <- validate_system_ids(Map.get(params, "system_ids")),
         {:ok, since_hours} <- validate_since_hours(Map.get(params, "since_hours", 24)),
         {:ok, limit} <- validate_limit(Map.get(params, "limit")) do
      Logger.info("Fetching kills for multiple systems",
        system_count: length(system_ids),
        since_hours: since_hours,
        limit: limit
      )

      {:ok, systems_killmails} = Client.fetch_systems_killmails(system_ids, since_hours, limit)

      response = %{
        systems_kills: systems_killmails,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      render_success(conn, response)
    else
      {:error, %Error{type: :invalid_system_ids}} ->
        render_error(conn, 400, "Invalid system IDs", "INVALID_SYSTEM_IDS")

      {:error, %Error{}} ->
        render_error(conn, 400, "Invalid parameters", "INVALID_PARAMETERS")
    end
  end

  @doc """
  Returns cached kills for a system.

  GET /api/v1/kills/cached/:system_id
  """
  @spec cached(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def cached(conn, %{"system_id" => system_id_str}) do
    case validate_system_id(system_id_str) do
      {:ok, system_id} ->
        Logger.debug("Fetching cached kills", system_id: system_id)

        killmails = Client.fetch_cached_killmails(system_id)
        response = build_cached_response(killmails, true)
        render_success(conn, response)

      {:error, %Error{}} ->
        render_error(conn, 400, "Invalid system ID format", "INVALID_SYSTEM_ID")
    end
  end

  @doc """
  Shows a specific killmail by ID.

  GET /api/v1/killmail/:killmail_id
  """
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"killmail_id" => killmail_id_str}) do
    case validate_killmail_id(killmail_id_str) do
      {:ok, killmail_id} ->
        Logger.debug("Fetching specific killmail", killmail_id: killmail_id)

        case Client.get_killmail(killmail_id) do
          nil ->
            render_error(conn, 404, "Killmail not found", "NOT_FOUND")

          killmail ->
            render_success(conn, killmail)
        end

      {:error, %Error{}} ->
        render_error(conn, 400, "Invalid killmail ID format", "INVALID_KILLMAIL_ID")
    end
  end

  @doc """
  Returns kill count for a system.

  GET /api/v1/kills/count/:system_id
  """
  @spec count(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def count(conn, %{"system_id" => system_id_str}) do
    case validate_system_id(system_id_str) do
      {:ok, system_id} ->
        Logger.debug("Fetching system kill count", system_id: system_id)

        count = Client.get_system_killmail_count(system_id)

        response = %{
          system_id: system_id,
          count: count,
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        render_success(conn, response)

      {:error, %Error{}} ->
        render_error(conn, 400, "Invalid system ID format", "INVALID_SYSTEM_ID")
    end
  end

  @doc """
  Handles undefined API routes.
  """
  @spec not_found(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def not_found(conn, _params) do
    render_error(conn, 404, "Not Found", "NOT_FOUND")
  end

  # Private helper functions

  @spec build_cached_response(list(), boolean(), term()) :: map()
  defp build_cached_response(killmails, cached, error \\ nil) do
    base_response = %{
      kills: killmails,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      cached: cached
    }

    if error do
      Map.put(base_response, :error, error)
    else
      base_response
    end
  end
end
