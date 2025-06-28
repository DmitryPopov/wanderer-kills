defmodule WandererKills.Core.Observability.Telemetry do
  @moduledoc """
  Handles telemetry events for the WandererKills application.

  This module provides functionality to:
  - Execute telemetry events with helper functions
  - Attach and detach telemetry event handlers
  - Process telemetry events through handlers
  - Centralized logging of telemetry events

  ## Events

  Cache events:
  - `[:wanderer_kills, :cache, :hit]` - When a cache lookup succeeds
  - `[:wanderer_kills, :cache, :miss]` - When a cache lookup fails
  - `[:wanderer_kills, :cache, :error]` - When a cache operation fails

  HTTP events:
  - `[:wanderer_kills, :http, :request, :start]` - When an HTTP request starts
  - `[:wanderer_kills, :http, :request, :stop]` - When an HTTP request completes
  - `[:wanderer_kills, :http, :request, :error]` - When an HTTP request fails with exception

  Fetch events:
  - `[:wanderer_kills, :fetch, :killmail, :success]` - When a killmail is successfully fetched
  - `[:wanderer_kills, :fetch, :killmail, :error]` - When a killmail fetch fails
  - `[:wanderer_kills, :fetch, :system, :complete]` - When a system fetch completes
  - `[:wanderer_kills, :fetch, :system, :error]` - When a system fetch fails

  Parser events:
  - `[:wanderer_kills, :parser, :stored]` - When killmails are stored
  - `[:wanderer_kills, :parser, :skipped]` - When killmails are skipped
  - `[:wanderer_kills, :parser, :failed]` - When killmail parsing fails
  - `[:wanderer_kills, :parser, :summary]` - Parser summary statistics

  WebSocket events:
  - `[:wanderer_kills, :websocket, :kills_sent]` - When killmails are sent via WebSocket
  - `[:wanderer_kills, :websocket, :connection]` - When WebSocket connections change
  - `[:wanderer_kills, :websocket, :subscription]` - When WebSocket subscriptions change

  SSE events:
  - `[:wanderer_kills, :sse, :connection, :start]` - When SSE connection is established
  - `[:wanderer_kills, :sse, :connection, :stop]` - When SSE connection is closed
  - `[:wanderer_kills, :sse, :event, :sent]` - When SSE event is sent
  - `[:wanderer_kills, :sse, :manager, :started]` - When SSE manager starts
  - `[:wanderer_kills, :sse, :error]` - When SSE error occurs

  Character subscription events:
  - `[:wanderer_kills, :character, :match]` - When character matching is performed
  - `[:wanderer_kills, :character, :filter]` - When character filtering is performed
  - `[:wanderer_kills, :character, :index]` - When character index operations occur
  - `[:wanderer_kills, :character, :cache]` - When character cache operations occur

  System subscription events:
  - `[:wanderer_kills, :system, :filter]` - When system filtering is performed
  - `[:wanderer_kills, :system, :index]` - When system index operations occur

  ZKB events:
  - `[:wanderer_kills, :zkb, :format]` - When ZKB format is detected

  System events:
  - `[:wanderer_kills, :system, :memory]` - Memory usage metrics
  - `[:wanderer_kills, :system, :cpu]` - CPU usage metrics

  ## Usage

  ```elixir
  # Execute telemetry events using helper functions:
  Telemetry.http_request_start("GET", "https://api.example.com")
  Telemetry.fetch_system_complete(12345, :success)
  Telemetry.cache_hit("my_key")

  # Attach/detach handlers during application lifecycle
  Telemetry.attach_handlers()
  Telemetry.detach_handlers()
  ```

  ## Note

  Periodic measurements and metrics collection are handled by
  `WandererKills.Core.Observability.Monitoring` module.
  """

  require Logger
  alias WandererKills.Core.Observability.BatchTelemetry
  alias WandererKills.Core.Observability.LogFormatter
  alias __MODULE__

  # -------------------------------------------------
  # Helper functions for telemetry execution
  # -------------------------------------------------

  @doc """
  Executes HTTP request start telemetry.
  """
  @spec http_request_start(String.t(), String.t()) :: :ok
  def http_request_start(method, url) do
    :telemetry.execute(
      [:wanderer_kills, :http, :request, :start],
      %{system_time: System.system_time(:native)},
      %{method: method, url: url, service: determine_service(url)}
    )
  end

  @doc """
  Executes HTTP request stop telemetry.
  """
  @spec http_request_stop(String.t(), String.t(), integer(), integer()) :: :ok
  def http_request_stop(method, url, duration, status_code) do
    :telemetry.execute(
      [:wanderer_kills, :http, :request, :stop],
      %{duration: duration},
      %{method: method, url: url, status_code: status_code, service: determine_service(url)}
    )
  end

  @doc """
  Executes HTTP request error telemetry.
  """
  @spec http_request_error(String.t(), String.t(), integer(), term()) :: :ok
  def http_request_error(method, url, duration, error) do
    :telemetry.execute(
      [:wanderer_kills, :http, :request, :stop],
      %{duration: duration},
      %{method: method, url: url, error: error, service: determine_service(url)}
    )
  end

  # Helper to determine service from URL
  defp determine_service(url) when is_binary(url) do
    # Convert to lowercase for case-insensitive comparison
    url_lower = String.downcase(url)

    cond do
      String.contains?(url_lower, "zkillboard.com") -> :zkillboard
      String.contains?(url_lower, "esi.evetech.net") -> :esi
      true -> :unknown
    end
  end

  defp determine_service(_), do: :unknown

  @doc """
  Executes fetch system start telemetry.
  """
  @spec fetch_system_start(integer(), integer(), atom()) :: :ok
  def fetch_system_start(system_id, limit, source) do
    :telemetry.execute(
      [:wanderer_kills, :fetch, :system, :start],
      %{system_id: system_id, limit: limit},
      %{source: source}
    )
  end

  @doc """
  Executes fetch system complete telemetry.
  """
  @spec fetch_system_complete(integer(), atom()) :: :ok
  def fetch_system_complete(system_id, result) do
    :telemetry.execute(
      [:wanderer_kills, :fetch, :system, :complete],
      %{system_id: system_id},
      %{result: result}
    )
  end

  @doc """
  Executes fetch system success telemetry.
  """
  @spec fetch_system_success(integer(), integer(), atom()) :: :ok
  def fetch_system_success(system_id, killmail_count, source) do
    :telemetry.execute(
      [:wanderer_kills, :fetch, :system, :success],
      %{system_id: system_id, killmail_count: killmail_count},
      %{source: source}
    )
  end

  @doc """
  Executes fetch system error telemetry.
  """
  @spec fetch_system_error(integer(), term(), atom()) :: :ok
  def fetch_system_error(system_id, error, source) do
    :telemetry.execute(
      [:wanderer_kills, :fetch, :system, :error],
      %{system_id: system_id},
      %{error: error, source: source}
    )
  end

  @doc """
  Executes cache hit telemetry.
  """
  @spec cache_hit(String.t()) :: :ok
  def cache_hit(key) do
    :telemetry.execute(
      [:wanderer_kills, :cache, :hit],
      %{},
      %{key: key}
    )
  end

  @doc """
  Executes cache miss telemetry.
  """
  @spec cache_miss(String.t()) :: :ok
  def cache_miss(key) do
    :telemetry.execute(
      [:wanderer_kills, :cache, :miss],
      %{},
      %{key: key}
    )
  end

  @doc """
  Executes cache error telemetry.
  """
  @spec cache_error(String.t(), term()) :: :ok
  def cache_error(key, reason) do
    :telemetry.execute(
      [:wanderer_kills, :cache, :error],
      %{},
      %{key: key, reason: reason}
    )
  end

  @doc """
  Executes parser telemetry.
  """
  @spec parser_stored(integer()) :: :ok
  def parser_stored(count \\ 1) do
    :telemetry.execute(
      [:wanderer_kills, :parser, :stored],
      %{count: count},
      %{}
    )
  end

  @doc """
  Executes parser skipped telemetry.
  """
  @spec parser_skipped(integer()) :: :ok
  def parser_skipped(count \\ 1) do
    :telemetry.execute(
      [:wanderer_kills, :parser, :skipped],
      %{count: count},
      %{}
    )
  end

  @doc """
  Executes parser failed telemetry.
  """
  @spec parser_failed(integer()) :: :ok
  def parser_failed(count \\ 1) do
    :telemetry.execute(
      [:wanderer_kills, :parser, :failed],
      %{count: count},
      %{}
    )
  end

  @doc """
  Executes parser summary telemetry.
  """
  @spec parser_summary(integer(), integer()) :: :ok
  def parser_summary(stored, skipped) do
    :telemetry.execute(
      [:wanderer_kills, :parser, :summary],
      %{stored: stored, skipped: skipped},
      %{}
    )
  end

  @doc """
  Executes WebSocket kills sent telemetry.
  """
  @spec websocket_kills_sent(atom(), integer()) :: :ok
  def websocket_kills_sent(type, count) when type in [:realtime, :preload] do
    :telemetry.execute(
      [:wanderer_kills, :websocket, :kills_sent],
      %{count: count},
      %{type: type}
    )
  end

  @doc """
  Executes WebSocket connection telemetry.
  """
  @spec websocket_connection(atom(), map()) :: :ok
  def websocket_connection(event, metadata \\ %{}) when event in [:connected, :disconnected] do
    :telemetry.execute(
      [:wanderer_kills, :websocket, :connection],
      %{count: 1},
      Map.put(metadata, :event, event)
    )
  end

  @doc """
  Executes WebSocket subscription telemetry.
  """
  @spec websocket_subscription(atom(), integer(), map()) :: :ok
  def websocket_subscription(event, system_count, metadata \\ %{})
      when event in [:added, :updated, :removed] do
    :telemetry.execute(
      [:wanderer_kills, :websocket, :subscription],
      %{system_count: system_count},
      Map.put(metadata, :event, event)
    )
  end

  @doc """
  Executes ZKB format detection telemetry.
  """
  @spec zkb_format(atom(), map()) :: :ok
  def zkb_format(format_type, metadata \\ %{}) do
    :telemetry.execute(
      [:wanderer_kills, :zkb, :format],
      %{count: 1},
      Map.put(metadata, :format, format_type)
    )
  end

  @doc """
  Executes character matching telemetry.
  """
  @spec character_match(integer(), boolean(), integer()) :: :ok
  def character_match(duration_native, match_found, character_count) do
    :telemetry.execute(
      [:wanderer_kills, :character, :match],
      %{
        duration: duration_native,
        character_count: character_count
      },
      %{
        match_found: match_found
      }
    )
  end

  @doc """
  Executes character filter telemetry.
  """
  @spec character_filter(integer(), integer(), integer()) :: :ok
  def character_filter(duration_native, killmail_count, match_count) do
    :telemetry.execute(
      [:wanderer_kills, :character, :filter],
      %{
        duration: duration_native,
        killmail_count: killmail_count,
        match_count: match_count
      },
      %{}
    )
  end

  @doc """
  Executes character index telemetry.
  """
  @spec character_index(atom(), integer(), map()) :: :ok
  def character_index(operation, duration_native, metadata \\ %{})
      when operation in [:add, :remove, :lookup, :batch_lookup, :update] do
    :telemetry.execute(
      [:wanderer_kills, :character, :index],
      %{duration: duration_native},
      Map.put(metadata, :operation, operation)
    )
  end

  @doc """
  Executes character cache telemetry.
  """
  @spec character_cache(atom(), String.t(), map()) :: :ok
  def character_cache(event, cache_key, metadata \\ %{})
      when event in [:hit, :miss, :put, :evict] do
    :telemetry.execute(
      [:wanderer_kills, :character, :cache],
      %{count: 1},
      Map.merge(metadata, %{event: event, cache_key: cache_key})
    )
  end

  @doc """
  Executes system filter telemetry.
  """
  @spec system_filter(integer(), integer(), integer()) :: :ok
  def system_filter(duration_native, killmail_count, match_count) do
    :telemetry.execute(
      [:wanderer_kills, :system, :filter],
      %{
        duration: duration_native,
        killmail_count: killmail_count,
        match_count: match_count
      },
      %{}
    )
  end

  @doc """
  Executes system index telemetry.
  """
  @spec system_index(atom(), integer(), map()) :: :ok
  def system_index(operation, duration_native, metadata \\ %{})
      when operation in [:add, :remove, :lookup, :batch_lookup, :update] do
    :telemetry.execute(
      [:wanderer_kills, :system, :index],
      %{duration: duration_native},
      Map.put(metadata, :operation, operation)
    )
  end

  # -------------------------------------------------
  # Handler attachment/detachment functions
  # -------------------------------------------------

  @doc """
  Attaches telemetry event handlers for all application events.

  This should be called during application startup to ensure
  all telemetry events are properly logged and processed.
  """
  @spec attach_handlers() :: :ok
  def attach_handlers do
    # Cache hit/miss handlers
    :telemetry.attach_many(
      "wanderer-kills-cache-handler",
      [
        [:wanderer_kills, :cache, :hit],
        [:wanderer_kills, :cache, :miss],
        [:wanderer_kills, :cache, :error]
      ],
      &Telemetry.handle_cache_event/4,
      nil
    )

    # HTTP request handlers
    :telemetry.attach_many(
      "wanderer-kills-http-handler",
      [
        [:wanderer_kills, :http, :request, :start],
        [:wanderer_kills, :http, :request, :stop],
        [:wanderer_kills, :http, :request, :error]
      ],
      &Telemetry.handle_http_event/4,
      nil
    )

    # Fetch handlers
    :telemetry.attach_many(
      "wanderer-kills-fetch-handler",
      [
        [:wanderer_kills, :fetch, :killmail, :success],
        [:wanderer_kills, :fetch, :killmail, :error],
        [:wanderer_kills, :fetch, :system, :start],
        [:wanderer_kills, :fetch, :system, :complete],
        [:wanderer_kills, :fetch, :system, :success],
        [:wanderer_kills, :fetch, :system, :error]
      ],
      &Telemetry.handle_fetch_event/4,
      nil
    )

    # Parser handlers
    :telemetry.attach_many(
      "wanderer-kills-parser-handler",
      [
        [:wanderer_kills, :parser, :stored],
        [:wanderer_kills, :parser, :skipped],
        [:wanderer_kills, :parser, :failed],
        [:wanderer_kills, :parser, :summary]
      ],
      &Telemetry.handle_parser_event/4,
      nil
    )

    # WebSocket handlers
    :telemetry.attach_many(
      "wanderer-kills-websocket-handler",
      [
        [:wanderer_kills, :websocket, :kills_sent],
        [:wanderer_kills, :websocket, :connection],
        [:wanderer_kills, :websocket, :subscription]
      ],
      &Telemetry.handle_websocket_event/4,
      nil
    )

    # ZKB handlers
    :telemetry.attach_many(
      "wanderer-kills-zkb-handler",
      [
        [:wanderer_kills, :zkb, :format]
      ],
      &Telemetry.handle_zkb_event/4,
      nil
    )

    # Supervised task handlers
    :telemetry.attach_many(
      "wanderer-kills-task-handler",
      [
        [:wanderer_kills, :task, :start],
        [:wanderer_kills, :task, :stop],
        [:wanderer_kills, :task, :error]
      ],
      &Telemetry.handle_task_event/4,
      nil
    )

    # Character subscription handlers
    :telemetry.attach_many(
      "wanderer-kills-character-handler",
      [
        [:wanderer_kills, :character, :match],
        [:wanderer_kills, :character, :filter],
        [:wanderer_kills, :character, :index],
        [:wanderer_kills, :character, :cache]
      ],
      &Telemetry.handle_character_event/4,
      nil
    )

    # System handlers (includes system metrics and subscription telemetry)
    :telemetry.attach_many(
      "wanderer-kills-system-handler",
      [
        [:wanderer_kills, :system, :memory],
        [:wanderer_kills, :system, :cpu],
        [:wanderer_kills, :system, :filter],
        [:wanderer_kills, :system, :index]
      ],
      &Telemetry.handle_system_event/4,
      nil
    )

    # SSE handlers
    :telemetry.attach_many(
      "wanderer-kills-sse-handler",
      [
        [:wanderer_kills, :sse, :connection, :start],
        [:wanderer_kills, :sse, :connection, :stop],
        [:wanderer_kills, :sse, :event, :sent],
        [:wanderer_kills, :sse, :manager, :started],
        [:wanderer_kills, :sse, :error]
      ],
      &Telemetry.handle_sse_event/4,
      nil
    )

    # Attach batch processing telemetry handlers
    BatchTelemetry.attach_handlers()

    :ok
  end

  @doc """
  Detaches all telemetry event handlers.

  This should be called during application shutdown to clean up
  telemetry handlers properly.
  """
  @spec detach_handlers() :: :ok
  def detach_handlers do
    :telemetry.detach("wanderer-kills-cache-handler")
    :telemetry.detach("wanderer-kills-http-handler")
    :telemetry.detach("wanderer-kills-fetch-handler")
    :telemetry.detach("wanderer-kills-parser-handler")
    :telemetry.detach("wanderer-kills-websocket-handler")
    :telemetry.detach("wanderer-kills-zkb-handler")
    :telemetry.detach("wanderer-kills-task-handler")
    :telemetry.detach("wanderer-kills-character-handler")
    :telemetry.detach("wanderer-kills-system-handler")
    :telemetry.detach("wanderer-kills-sse-handler")

    # Detach batch processing telemetry handlers
    BatchTelemetry.detach_handlers()

    :ok
  end

  # -------------------------------------------------
  # Event handlers
  # -------------------------------------------------

  @doc """
  Handles cache-related telemetry events.
  """
  def handle_cache_event([:wanderer_kills, :cache, event], _measurements, metadata, _config) do
    case event do
      :hit ->
        Logger.debug("[Cache] Hit for key: #{inspect(metadata.key)}")

      :miss ->
        Logger.debug("[Cache] Miss for key: #{inspect(metadata.key)}")

      :error ->
        Logger.error(
          "[Cache] Error for key: #{inspect(metadata.key)}, reason: #{inspect(metadata.reason)}"
        )
    end
  end

  @doc """
  Handles HTTP request telemetry events.
  """
  def handle_http_event(
        [:wanderer_kills, :http, :request, event],
        _measurements,
        metadata,
        _config
      ) do
    case event do
      :start ->
        Logger.debug("[HTTP] Starting request: #{metadata.method} #{metadata.url}")

      :stop ->
        case metadata do
          %{status_code: status} ->
            Logger.debug(
              "[HTTP] Completed request: #{metadata.method} #{metadata.url} (#{status})"
            )

          %{error: reason} ->
            Logger.error(
              "[HTTP] Failed request: #{metadata.method} #{metadata.url} (#{inspect(reason)})"
            )
        end

      :error ->
        Logger.error(
          "[HTTP] Exception in request: #{metadata.method} #{metadata.url} (#{inspect(metadata.error)})"
        )
    end
  end

  @doc """
  Handles fetch operation telemetry events.
  """
  def handle_fetch_event([:wanderer_kills, :fetch, type, event], measurements, metadata, _config) do
    case {type, event} do
      {:killmail, :success} ->
        Logger.debug("[Fetch] Successfully fetched killmail: #{measurements.killmail_id}")

      {:killmail, :error} ->
        Logger.error(
          "[Fetch] Failed to fetch killmail: #{measurements.killmail_id}, reason: #{inspect(metadata.error)}"
        )

      {:system, :start} ->
        Logger.debug(
          "[Fetch] Starting system fetch: #{measurements.system_id} (limit: #{measurements.limit})"
        )

      {:system, :complete} ->
        Logger.debug(
          "[Fetch] Completed system fetch: #{measurements.system_id} (#{metadata.result})"
        )

      {:system, :success} ->
        Logger.debug(
          "[Fetch] Successful system fetch: #{measurements.system_id} (#{measurements.killmail_count} killmails)"
        )

      {:system, :error} ->
        Logger.error(
          "[Fetch] Failed system fetch: #{measurements.system_id}, reason: #{inspect(metadata.error)}"
        )
    end
  end

  @doc """
  Handles parser telemetry events.
  """
  def handle_parser_event([:wanderer_kills, :parser, event], measurements, _metadata, _config) do
    case event do
      :stored ->
        Logger.debug("[Parser] Stored #{measurements.count} killmails")

      :skipped ->
        Logger.debug("[Parser] Skipped #{measurements.count} killmails")

      :failed ->
        Logger.debug("[Parser] Failed to parse #{measurements.count} killmails")

      :summary ->
        Logger.info(
          "[Parser] Summary - Stored: #{measurements.stored}, Skipped: #{measurements.skipped}"
        )
    end
  end

  @doc """
  Handles WebSocket telemetry events.
  """
  def handle_websocket_event(
        [:wanderer_kills, :websocket, event],
        measurements,
        metadata,
        _config
      ) do
    case event do
      :kills_sent ->
        Logger.debug("[WebSocket] Sent #{measurements.count} #{metadata.type} killmails")

      :connection ->
        Logger.debug("[WebSocket] Connection #{metadata.event} (count: #{measurements.count})")

      :subscription ->
        Logger.debug(
          "[WebSocket] Subscription #{metadata.event} with #{measurements.system_count} systems"
        )
    end
  end

  @doc """
  Handles ZKB telemetry events.
  """
  def handle_zkb_event([:wanderer_kills, :zkb, event], measurements, metadata, _config) do
    case event do
      :format ->
        Logger.debug("[ZKB] Format detected: #{metadata.format} (count: #{measurements.count})")
    end
  end

  @doc """
  Handles supervised task telemetry events.
  """
  def handle_task_event([:wanderer_kills, :task, event], measurements, metadata, _config) do
    case event do
      :start ->
        LogFormatter.format_operation("Task", "start", %{task_name: metadata.task_name})
        |> Logger.debug()

      :stop ->
        duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

        LogFormatter.format_operation("Task", "completed", %{
          task_name: metadata.task_name,
          duration_ms: duration_ms
        })
        |> Logger.debug()

      :error ->
        duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

        LogFormatter.format_error(
          "Task",
          "failed",
          %{
            task_name: metadata.task_name,
            duration_ms: duration_ms
          },
          metadata.error
        )
        |> Logger.error()

      _ ->
        :ok
    end
  end

  def handle_task_event(_, _, _, _), do: :ok

  @doc """
  Handles character subscription telemetry events.
  """
  def handle_character_event(
        [:wanderer_kills, :character, event],
        measurements,
        metadata,
        _config
      ) do
    case event do
      :match ->
        duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
        match_status = if metadata.match_found, do: "match", else: "no match"

        Logger.debug(
          "[Character] Matching completed in #{duration_ms}ms (#{match_status}) for #{measurements.character_count} characters"
        )

      :filter ->
        duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

        Logger.debug(
          "[Character] Filtered #{measurements.killmail_count} killmails in #{duration_ms}ms, found #{measurements.match_count} matches"
        )

      :index ->
        duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

        operation_details =
          case metadata do
            %{character_count: count} -> " (#{count} characters)"
            %{subscription_id: sub_id} -> " (#{sub_id})"
            _ -> ""
          end

        Logger.debug(
          "[Character] Index #{metadata.operation} completed in #{duration_ms}ms#{operation_details}"
        )

      :cache ->
        Logger.debug("[Character] Cache #{metadata.event} for key: #{metadata.cache_key}")
    end
  end

  def handle_system_event([:wanderer_kills, :system, event], measurements, metadata, _config) do
    case event do
      :memory -> handle_memory_event(measurements)
      :cpu -> handle_cpu_event(measurements)
      :filter -> handle_filter_event(measurements)
      :index -> handle_index_event(measurements, metadata)
    end
  end

  defp handle_memory_event(measurements) do
    Logger.debug(
      "[System] Memory usage - Total: #{measurements.total_memory}MB, Process: #{measurements.process_memory}MB"
    )
  end

  defp handle_cpu_event(measurements) do
    case Map.get(measurements, :total_cpu) do
      nil ->
        Logger.debug(
          "[System] System metrics - Processes: #{measurements.process_count}, Ports: #{measurements.port_count}, Schedulers: #{measurements.schedulers}, Run Queue: #{measurements.run_queue}"
        )

      total_cpu ->
        process_cpu = Map.get(measurements, :process_cpu, "N/A")
        Logger.debug("[System] CPU usage - Total: #{total_cpu}%, Process: #{process_cpu}%")
    end
  end

  defp handle_filter_event(measurements) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.debug(
      "[System] Filtered #{measurements.killmail_count} killmails in #{duration_ms}ms, found #{measurements.match_count} matches"
    )
  end

  defp handle_index_event(measurements, metadata) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    operation_details = format_operation_details(metadata)

    Logger.debug(
      "[System] Index #{metadata.operation} completed in #{duration_ms}ms#{operation_details}"
    )
  end

  defp format_operation_details(%{system_count: count}), do: " (#{count} systems)"
  defp format_operation_details(%{subscription_id: sub_id}), do: " (#{sub_id})"
  defp format_operation_details(_), do: ""

  @doc """
  Handles SSE telemetry events.
  """
  def handle_sse_event([:wanderer_kills, :sse, type | rest], measurements, metadata, _config) do
    case [type | rest] do
      [:connection, :start] ->
        Logger.info("[SSE] Connection started",
          connection_id: metadata.connection_id,
          filters: metadata.filters,
          ip: metadata.ip
        )

      [:connection, :stop] ->
        Logger.info("[SSE] Connection stopped",
          connection_id: metadata.connection_id,
          duration_seconds: Map.get(measurements, :duration_seconds, 0),
          total_connections: Map.get(measurements, :total_connections, 0)
        )

      [:event, :sent] ->
        Logger.debug("[SSE] Event sent",
          connection_id: metadata.connection_id,
          event_type: metadata.event_type
        )

      [:manager, :started] ->
        Logger.info("[SSE] Manager started")

      [:error] ->
        Logger.error("[SSE] Error occurred",
          error: metadata.error,
          connection_id: metadata[:connection_id]
        )
    end
  end
end
