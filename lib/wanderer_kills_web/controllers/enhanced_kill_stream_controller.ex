defmodule WandererKillsWeb.EnhancedKillStreamController do
  @moduledoc """
  Enhanced SSE controller for streaming killmail data with character-specific 
  historical preloading and server-side filtering.

  This controller implements a custom SSE solution that supports:
  - Historical data preloading for character killmails
  - Server-side filtering to reduce bandwidth
  - Clear event types for different phases
  - Transition signals between historical and real-time modes
  """

  use WandererKillsWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Phoenix.PubSub
  alias WandererKills.Core.Support.{Error, PubSubTopics}
  alias WandererKills.SSE.{EventFormatter, FilterHandler, FilterParser}
  alias WandererKills.Subs.Preloader

  require Logger

  # 30 seconds
  @heartbeat_interval 30_000
  # 100ms between batches
  @batch_delay 100

  operation(:stream,
    summary: "Enhanced SSE stream with character preloading",
    description: """
    Enhanced Server-Sent Events stream with support for historical data preloading.

    Preloading behavior:
    - If `character_ids` and `preload_days` are specified: loads historical character killmails
    - If `system_ids` and `preload_days` are specified: loads historical system killmails
    - Character preloading takes precedence if both character_ids and system_ids are provided

    Event types:
    - `connected`: Initial connection confirmation
    - `batch`: Historical killmail batch (when preload_days > 0)
    - `transition`: Marks switch from historical to real-time mode
    - `killmail`: Real-time killmail updates
    - `heartbeat`: Keep-alive with mode indicator
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
      ],
      preload_days: [
        in: :query,
        description: "Number of days of historical data to preload (max 90)",
        type: :integer,
        required: false,
        example: 90
      ]
    ],
    responses: %{
      200 => {"SSE stream started", "text/event-stream", WandererKillsWeb.Schemas.SSEStream},
      400 => {"Invalid parameters", "application/json", WandererKillsWeb.Schemas.Error}
    }
  )

  @doc """
  Enhanced SSE streaming endpoint with character preloading support.
  """
  def stream(conn, params) do
    case FilterParser.parse(params) do
      {:ok, filters} ->
        start_sse_stream(conn, filters, params)

      {:error, %Error{} = error} ->
        Logger.warning("Invalid SSE parameters", error: error, params: params)

        conn
        |> put_status(400)
        |> json(%{error: Error.to_map(error)})
    end
  end

  defp start_sse_stream(conn, filters, params) do
    case check_connection_limits() do
      :ok ->
        setup_and_start_sse(conn, filters)

      {:error, :connection_limit_reached} ->
        Logger.warning("SSE connection limit reached", params: params)

        conn
        |> put_status(503)
        |> json(%{
          error: %{
            type: "connection_limit_reached",
            message: "Too many active SSE connections"
          }
        })
    end
  end

  defp setup_and_start_sse(conn, filters) do
    # Set up SSE headers
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    # Start the SSE stream handler in a separate process
    Task.start_link(fn ->
      handle_sse_connection(conn, filters)
    end)

    # Return the conn (though the connection is now owned by the task)
    conn
  end

  defp handle_sse_connection(conn, filters) do
    # Track the connection start
    connection_id = track_connection_start()

    # Send connected event
    send_sse_event(conn, EventFormatter.connected_event(filters))

    # Initialize state
    state = %{
      conn: conn,
      filters: filters,
      mode: :historical,
      historical_count: 0,
      topics: [],
      connection_id: connection_id
    }

    # Handle historical preload if requested
    state =
      if should_preload?(filters) do
        preload_historical_data(state)
      else
        %{state | mode: :realtime}
      end

    # Subscribe to appropriate topics
    state = subscribe_to_topics(state)

    # Start heartbeat timer
    Process.send_after(self(), :heartbeat, @heartbeat_interval)

    # Enter event loop
    event_loop(state)
  end

  defp should_preload?(filters) do
    filters.preload_days > 0 &&
      (not Enum.empty?(filters.character_ids) || not Enum.empty?(filters.system_ids))
  end

  defp preload_historical_data(state) do
    Logger.info("[EnhancedSSE] Starting historical preload",
      character_ids: state.filters.character_ids,
      system_ids: state.filters.system_ids,
      days: state.filters.preload_days
    )

    # Fetch historical killmails based on filter type
    batches =
      cond do
        not Enum.empty?(state.filters.character_ids) ->
          # Character preloading takes precedence
          Preloader.preload_kills_for_characters(
            state.filters.character_ids,
            days: state.filters.preload_days,
            batch_size: 50
          )

        not Enum.empty?(state.filters.system_ids) ->
          # System preloading
          Preloader.preload_kills_for_systems(
            state.filters.system_ids,
            days: state.filters.preload_days,
            batch_size: 50
          )

        true ->
          # Should not happen due to should_preload? check
          []
      end

    total_batches = length(batches)
    total_count = 0

    # Send each batch with delay
    updated_count =
      batches
      |> Enum.with_index(1)
      |> Enum.reduce(total_count, fn {kills, batch_num}, acc ->
        # Convert killmail structs to maps for JSON encoding
        kills_as_maps = Enum.map(kills, &killmail_to_map/1)

        # Send batch event
        send_sse_event(
          state.conn,
          EventFormatter.batch_event(kills_as_maps, %{
            number: batch_num,
            total: total_batches
          })
        )

        # Small delay between batches
        Process.sleep(@batch_delay)

        acc + length(kills)
      end)

    # Send transition event
    send_sse_event(state.conn, EventFormatter.transition_event(updated_count))

    Logger.info("[EnhancedSSE] Historical preload complete",
      total_kills: updated_count,
      batches_sent: total_batches
    )

    %{state | mode: :realtime, historical_count: updated_count}
  end

  defp subscribe_to_topics(state) do
    topics = determine_topics(state.filters)

    # Subscribe to each topic
    Enum.each(topics, fn topic ->
      PubSub.subscribe(WandererKills.PubSub, topic)
    end)

    Logger.info("[EnhancedSSE] Subscribed to topics", topics: topics)

    %{state | topics: topics}
  end

  defp determine_topics(filters) do
    cond do
      # For character filtering, subscribe to character-specific topics
      not Enum.empty?(filters.character_ids) ->
        Enum.map(filters.character_ids, fn char_id ->
          "zkb:character:#{char_id}"
        end)

      # For system filtering, subscribe to system topics
      not Enum.empty?(filters.system_ids) ->
        Enum.map(filters.system_ids, &PubSubTopics.system_topic/1)

      # No filters, subscribe to all systems
      true ->
        [PubSubTopics.all_systems_topic()]
    end
  end

  defp event_loop(state) do
    receive do
      {:killmail, killmail} ->
        # Apply server-side filtering
        if FilterHandler.should_send_killmail?(killmail, state.filters) do
          send_sse_event(state.conn, EventFormatter.killmail_event(killmail))
        end

        event_loop(state)

      :heartbeat ->
        # Send heartbeat with current mode
        send_sse_event(state.conn, EventFormatter.heartbeat_event(state.mode))

        # Schedule next heartbeat
        Process.send_after(self(), :heartbeat, @heartbeat_interval)
        event_loop(state)

      {:DOWN, _ref, :process, _pid, _reason} ->
        # Connection closed, clean up
        Logger.info("[EnhancedSSE] Connection closed, cleaning up")
        cleanup(state)

      msg ->
        Logger.debug("[EnhancedSSE] Received unexpected message", message: inspect(msg))
        event_loop(state)
    end
  catch
    {:error, :closed} ->
      Logger.info("[EnhancedSSE] Client disconnected")
      cleanup(state)
  end

  defp send_sse_event(conn, %{event: event_type, data: data}) do
    chunk = format_sse_chunk(event_type, data)

    case Plug.Conn.chunk(conn, chunk) do
      {:ok, _conn} -> :ok
      {:error, :closed} -> throw({:error, :closed})
    end
  end

  defp format_sse_chunk(event_type, data) do
    "event: #{event_type}\ndata: #{data}\n\n"
  end

  # Connection limit enforcement
  defp check_connection_limits do
    max_connections = Application.get_env(:wanderer_kills, :sse)[:max_connections] || 100
    current_connections = get_active_sse_connections()

    if current_connections >= max_connections do
      {:error, :connection_limit_reached}
    else
      :ok
    end
  end

  defp get_active_sse_connections do
    case :ets.whereis(:sse_connections) do
      :undefined ->
        # Create table if it doesn't exist
        :ets.new(:sse_connections, [:set, :public, :named_table])
        0

      _tid ->
        :ets.info(:sse_connections, :size) || 0
    end
  end

  defp track_connection_start do
    connection_id = make_ref()

    case :ets.whereis(:sse_connections) do
      :undefined ->
        :ets.new(:sse_connections, [:set, :public, :named_table])

      _tid ->
        :ok
    end

    :ets.insert(:sse_connections, {connection_id, :active})
    connection_id
  end

  defp track_connection_stop(connection_id) do
    case :ets.whereis(:sse_connections) do
      :undefined -> :ok
      _tid -> :ets.delete(:sse_connections, connection_id)
    end
  end

  defp cleanup(state) do
    # Track connection stop
    track_connection_stop(state.connection_id)

    # Unsubscribe from all topics
    Enum.each(state.topics, fn topic ->
      PubSub.unsubscribe(WandererKills.PubSub, topic)
    end)

    :telemetry.execute([:wanderer_kills, :sse, :connection, :stop], %{count: 1}, %{
      mode: state.mode,
      historical_count: state.historical_count,
      topics: state.topics
    })
  end

  # Convert Killmail struct to map for JSON encoding
  defp killmail_to_map(%WandererKills.Domain.Killmail{} = killmail) do
    Map.from_struct(killmail)
    |> Map.drop([:__meta__, :__struct__])
    |> convert_nested_structs()
  end

  defp killmail_to_map(killmail) when is_map(killmail), do: killmail

  defp convert_nested_structs(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {k, %DateTime{} = v}, acc ->
        Map.put(acc, k, DateTime.to_iso8601(v))

      {k, %{__struct__: _} = v}, acc ->
        Map.put(acc, k, convert_nested_structs(Map.from_struct(v)))

      {k, v}, acc when is_list(v) ->
        Map.put(acc, k, Enum.map(v, &convert_nested_structs/1))

      {k, v}, acc when is_map(v) ->
        Map.put(acc, k, convert_nested_structs(v))

      {k, v}, acc ->
        Map.put(acc, k, v)
    end)
  end

  defp convert_nested_structs(list) when is_list(list) do
    Enum.map(list, &convert_nested_structs/1)
  end

  defp convert_nested_structs(value), do: value
end
