defmodule WandererKillsWeb.KillStreamController do
  @moduledoc """
  Controller for Server-Sent Events (SSE) streaming of killmail data.

  Provides real-time killmail updates via SSE protocol with optional filtering
  by system IDs, character IDs, and minimum ISK value.
  """

  use WandererKillsWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias WandererKills.SSE.FilterParser
  alias WandererKills.Core.Support.Error
  alias WandererKills.Core.Support.PubSubTopics

  require Logger

  operation(:stream,
    summary: "Stream killmail events via SSE",
    description: """
    Real-time Server-Sent Events stream of killmail data with optional filtering.

    The stream will send different types of events:
    - `connected`: Initial connection confirmation
    - `killmail`: New killmail data
    - `batch`: Historical killmails (on connection)
    - `heartbeat`: Keep-alive signal (every 30 seconds)
    - `error`: Error notifications
    """,
    parameters: [
      system_ids: [
        in: :query,
        description: "Comma-separated list of system IDs to filter",
        type: :string,
        required: false,
        example: "30000142,30000144"
      ],
      character_ids: [
        in: :query,
        description: "Comma-separated character IDs to track as victim/attacker",
        type: :string,
        required: false,
        example: "123456789,987654321"
      ],
      min_value: [
        in: :query,
        description: "Minimum ISK value threshold for killmails",
        type: :number,
        required: false,
        example: 100_000_000
      ]
    ],
    responses: %{
      200 => {"SSE stream started", "text/event-stream", WandererKillsWeb.Schemas.SSEStream},
      400 => {"Invalid parameters", "application/json", WandererKillsWeb.Schemas.Error}
    }
  )

  @doc """
  Stream killmail events via Server-Sent Events.

  Query parameters:
  - system_ids: Comma-separated list of system IDs to filter
  - character_ids: Comma-separated list of character IDs to track
  - min_value: Minimum ISK value threshold for killmails
  """
  def stream(conn, params) do
    case FilterParser.parse(params) do
      {:ok, filters} ->
        Logger.info("Starting SSE stream", filters: filters, remote_ip: get_remote_ip(conn))

        # Determine PubSub topics based on filters
        topics = determine_topics(filters)

        Logger.info("SSE subscribing to topics", topics: topics, filters: filters)

        # Stream events from PubSub topics using sse_phoenix_pubsub
        # This function hijacks the connection and never returns
        SsePhoenixPubsub.stream(conn, {WandererKills.PubSub, topics})

      {:error, %Error{} = error} ->
        Logger.warning("Invalid SSE stream parameters", error: error, params: params)

        conn
        |> put_status(400)
        |> json(%{error: Error.to_map(error)})
    end
  end

  @doc """
  Debug endpoint to cleanup dead SSE connections.
  """
  def cleanup(conn, _params) do
    # With sse_phoenix_pubsub, connections are managed automatically
    json(conn, %{message: "SSE connections are managed automatically by sse_phoenix_pubsub"})
  end

  @doc """
  Debug endpoint to get SSE statistics.
  """
  def stats(conn, _params) do
    # Basic stats - the library handles connection management internally
    json(conn, %{
      message: "SSE statistics are handled by sse_phoenix_pubsub library",
      pubsub_name: WandererKills.PubSub
    })
  end

  @doc """
  Debug endpoint to test PubSub delivery to SSE connections.
  """
  def test_broadcast(conn, _params) do
    # Create a test killmail
    test_killmail = %{
      "killmail_id" => 999_999_999,
      "system_id" => 30_000_142,
      "kill_time" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "victim" => %{"character_id" => 123_456_789},
      "attackers" => [%{"character_id" => 987_654_321}],
      "zkb" => %{"totalValue" => 500_000_000}
    }

    # Broadcast using the same mechanism as real killmails
    WandererKills.Subs.Subscriptions.Broadcaster.broadcast_killmail_update(30_000_142, [
      test_killmail
    ])

    # Also send a direct SSE test message
    alias WandererKills.SSE.Broadcaster, as: SSEBroadcaster
    alias WandererKills.Core.Support.PubSubTopics
    system_topic = PubSubTopics.system_topic(30_000_142)
    SSEBroadcaster.broadcast_test_message(system_topic)

    json(conn, %{
      message: "Test broadcast sent to system 30000142",
      killmail_id: 999_999_999,
      topics: [system_topic, PubSubTopics.all_systems_topic()]
    })
  end

  defp determine_topics(filters) do
    cond do
      filters.system_ids != [] ->
        # Subscribe to specific system topics
        Enum.map(filters.system_ids, &PubSubTopics.system_topic/1)

      filters.character_ids != [] ->
        # For character tracking, we need all systems
        [PubSubTopics.all_systems_topic()]

      true ->
        # No specific filters, subscribe to all
        [PubSubTopics.all_systems_topic()]
    end
  end

  defp get_remote_ip(conn) do
    # Handle X-Forwarded-For header if behind proxy
    case get_req_header(conn, "x-forwarded-for") do
      [ips | _] -> parse_forwarded_ip(ips, conn)
      [] -> fallback_to_conn_ip(conn)
    end
  end

  defp parse_forwarded_ip(ips_string, conn) do
    ip_string =
      ips_string
      |> String.split(",")
      |> List.first()
      |> String.trim()

    # Validate the extracted IP address
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, _parsed_ip} ->
        ip_string

      {:error, _reason} ->
        Logger.warning("Invalid IP address in X-Forwarded-For header",
          ip: ip_string,
          fallback: "using conn.remote_ip"
        )

        fallback_to_conn_ip(conn)
    end
  end

  defp fallback_to_conn_ip(conn) do
    conn.remote_ip
    |> :inet.ntoa()
    |> to_string()
  rescue
    error ->
      Logger.error("Failed to convert conn.remote_ip to string",
        remote_ip: conn.remote_ip,
        error: error
      )

      "unknown"
  end
end
