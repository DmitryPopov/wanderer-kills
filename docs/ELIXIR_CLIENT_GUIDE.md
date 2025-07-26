# Elixir Client Guide for WandererKills

This guide provides comprehensive documentation for integrating with the WandererKills API using Elixir, including WebSocket/SSE real-time connections.

## Table of Contents

1. [Installation](#installation)
2. [HTTP API Integration](#http-api-integration)
3. [WebSocket Integration](#websocket-integration)
4. [Server-Sent Events (SSE)](#server-sent-events-sse)
5. [PubSub Integration](#pubsub-integration)
6. [Advanced Patterns](#advanced-patterns)
7. [Error Handling](#error-handling)
8. [Testing](#testing)

## Installation

### Dependencies

```elixir
# In your mix.exs
defp deps do
  [
    {:req, "~> 0.5"},        # For HTTP API calls
    {:phoenix_client, "~> 0.3"},  # For WebSocket connections
    {:jason, "~> 1.4"},      # JSON parsing
    {:sse_client, "~> 1.0"}  # For Server-Sent Events (optional)
  ]
end
```

### Configuration

```elixir
# config/config.exs
config :my_app, :wanderer_kills,
  base_url: "http://localhost:4004",
  ws_url: "ws://localhost:4004/socket",
  timeout: 30_000
```

## HTTP API Integration

### Basic HTTP Client

```elixir
defmodule MyApp.WandererClient do
  @base_url Application.compile_env(:my_app, [:wanderer_kills, :base_url])

  # Fetch killmails for a single system
  def get_system_kills(system_id, opts \\ []) do
    since_hours = Keyword.get(opts, :since_hours, 24)
    limit = Keyword.get(opts, :limit, 50)
    
    Req.get("#{@base_url}/api/v1/kills/system/#{system_id}",
      params: %{since_hours: since_hours, limit: limit}
    )
  end

  # Bulk fetch multiple systems
  def get_systems_kills(system_ids, opts \\ []) do
    body = %{
      system_ids: system_ids,
      since_hours: Keyword.get(opts, :since_hours, 24),
      limit: Keyword.get(opts, :limit, 50)
    }
    
    Req.post("#{@base_url}/api/v1/kills/systems", json: body)
  end

  # Get specific killmail
  def get_killmail(killmail_id) do
    Req.get("#{@base_url}/api/v1/killmail/#{killmail_id}")
  end

  # Create webhook subscription
  def create_subscription(subscriber_id, system_ids, character_ids, callback_url) do
    body = %{
      subscriber_id: subscriber_id,
      system_ids: system_ids,
      character_ids: character_ids,
      callback_url: callback_url
    }
    
    Req.post("#{@base_url}/api/v1/subscriptions", json: body)
  end
end
```

### Usage Example

```elixir
# Get kills for Jita
{:ok, %{body: %{"data" => data}}} = MyApp.WandererClient.get_system_kills(30000142)

# Bulk fetch multiple systems
system_ids = [30000142, 30000144, 30000145]  # Jita, Perimeter, Urlen
{:ok, %{body: %{"data" => %{"systems_kills" => results}}}} = 
  MyApp.WandererClient.get_systems_kills(system_ids, since_hours: 12)

# Subscribe to webhook notifications
{:ok, %{body: %{"data" => %{"subscription_id" => sub_id}}}} = 
  MyApp.WandererClient.create_subscription(
    "my-service",
    [30000142],
    [95465499],
    "https://myapp.com/webhooks/killmails"
  )
```

## WebSocket Integration

### Using Phoenix Channels Client

### Basic WebSocket Client

```elixir
defmodule MyApp.KillmailSocket do
  use GenServer
  require Logger
  
  @url Application.compile_env(:my_app, [:wanderer_kills, :ws_url])
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @impl true
  def init(opts) do
    send(self(), :connect)
    {:ok, %{opts: opts, socket: nil, channels: []}}
  end
  
  @impl true
  def handle_info(:connect, state) do
    case PhoenixClient.Socket.start_link(@url, params: %{client_id: "my-app"}) do
      {:ok, socket} ->
        # Join the lobby channel with subscriptions
        channel_params = %{
          systems: state.opts[:systems] || [],
          character_ids: state.opts[:character_ids] || [],
          preload: %{
            enabled: true,
            limit_per_system: 50,
            since_hours: 24
          }
        }
        
        {:ok, _ref, channel} = PhoenixClient.Channel.join(socket, "killmails:lobby", channel_params)
        
        # Set up event handlers
        PhoenixClient.Channel.on(channel, "killmail_update", &handle_killmail_update/1)
        PhoenixClient.Channel.on(channel, "kill_count_update", &handle_kill_count_update/1)
        
        {:noreply, %{state | socket: socket, channels: [channel]}}
        
      {:error, reason} ->
        Logger.error("Failed to connect: #{inspect(reason)}")
        Process.send_after(self(), :connect, 5_000)
        {:noreply, state}
    end
  end
  
  defp handle_killmail_update(payload) do
    Logger.info("Received #{length(payload["killmails"])} kills for system #{payload["system_id"]}")
    # Process killmails
    Enum.each(payload["killmails"], &process_killmail/1)
  end
  
  defp handle_kill_count_update(payload) do
    Logger.debug("System #{payload["system_id"]} has #{payload["count"]} kills")
  end
  
  defp process_killmail(killmail) do
    # Your killmail processing logic here
    :ok
  end
end
```

### Dynamic Subscription Management

```elixir
defmodule MyApp.KillmailManager do
  use GenServer
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  def update_subscriptions(add_systems, remove_systems, add_characters, remove_characters) do
    GenServer.call(__MODULE__, {
      :update_subscriptions, 
      %{
        add_systems: add_systems,
        remove_systems: remove_systems,
        add_characters: add_characters,
        remove_characters: remove_characters
      }
    })
  end
  
  @impl true
  def init(opts) do
    {:ok, %{
      channel: opts[:channel],
      systems: [],
      characters: []
    }}
  end
  
  @impl true
  def handle_call({:update_subscriptions, params}, _from, state) do
    # Push subscription update to the channel
    case PhoenixClient.Channel.push(state.channel, "update_subscriptions", params) do
      {:ok, _ref} ->
        # Update local state
        new_state = %{
          state |
          systems: update_list(state.systems, params.add_systems, params.remove_systems),
          characters: update_list(state.characters, params.add_characters, params.remove_characters)
        }
        {:reply, :ok, new_state}
        
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end
  
  defp update_list(current, add, remove) do
    current
    |> Enum.concat(add || [])
    |> Enum.uniq()
    |> Enum.reject(&(&1 in (remove || [])))
  end
end
```

## Server-Sent Events (SSE)

SSE provides a simpler alternative to WebSocket for server-to-client streaming:

```elixir
defmodule MyApp.SSEClient do
  require Logger
  
  @base_url Application.compile_env(:my_app, [:wanderer_kills, :base_url])
  
  def stream_killmails(filters \\ %{}) do
    url = build_sse_url(filters)
    
    Req.get!(url, 
      receive_timeout: :infinity,
      into: fn {:data, data}, {req, resp} ->
        handle_sse_data(data)
        {:cont, {req, resp}}
      end
    )
  end
  
  defp build_sse_url(filters) do
    query = URI.encode_query(filters)
    "#{@base_url}/api/v1/kills/stream?#{query}"
  end
  
  defp handle_sse_data(data) do
    data
    |> String.split("\n")
    |> Enum.each(&process_sse_line/1)
  end
  
  defp process_sse_line("data: " <> json) do
    case Jason.decode(json) do
      {:ok, killmail} ->
        Logger.debug("Received killmail: #{killmail["killmail_id"]}")
        # Process the killmail
        process_killmail(killmail)
      
      {:error, _} ->
        Logger.error("Failed to parse SSE data: #{json}")
    end
  end
  
  defp process_sse_line("event: " <> event_type) do
    Logger.debug("SSE event: #{event_type}")
  end
  
  defp process_sse_line(_), do: :ok
  
  defp process_killmail(killmail) do
    # Your processing logic here
    :ok
  end
end

### Enhanced SSE with Character Preloading

```elixir
defmodule MyApp.EnhancedSSEClient do
  use GenServer
  require Logger
  
  @base_url Application.compile_env(:my_app, [:wanderer_kills, :base_url])
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @impl true
  def init(opts) do
    send(self(), :connect)
    {:ok, %{opts: opts, task: nil}}
  end
  
  @impl true
  def handle_info(:connect, state) do
    # Build URL with enhanced endpoint
    params = %{
      character_ids: Enum.join(state.opts[:character_ids] || [], ","),
      system_ids: Enum.join(state.opts[:system_ids] || [], ","),
      preload_days: state.opts[:preload_days] || 30
    }
    
    url = "#{@base_url}/api/v1/kills/stream/enhanced?#{URI.encode_query(params)}"
    
    task = Task.async(fn ->
      Req.get!(url,
        receive_timeout: :infinity,
        into: &handle_sse_chunk/2
      )
    end)
    
    {:noreply, %{state | task: task}}
  end
  
  defp handle_sse_chunk({:data, data}, acc) do
    data
    |> String.split("\n")
    |> Enum.each(fn line ->
      case parse_sse_line(line) do
        {:event, "batch", data} ->
          Logger.info("Historical batch #{data["batch_number"]}/#{data["total_batches"]}")
          Enum.each(data["kills"], &process_killmail/1)
          
        {:event, "transition", data} ->
          Logger.info("Transitioned to realtime mode after #{data["total_historical"]} historical kills")
          
        {:event, "killmail", killmail} ->
          process_killmail(killmail)
          
        _ -> :ok
      end
    end)
    
    {:cont, acc}
  end
  
  defp parse_sse_line("event: " <> event), do: {:event_type, event}
  defp parse_sse_line("data: " <> json) do
    case Jason.decode(json) do
      {:ok, data} -> {:event, "killmail", data}
      _ -> :error
    end
  end
  defp parse_sse_line(_), do: :skip
  
  defp process_killmail(killmail) do
    # Your processing logic
    :ok
  end
end
```

## PubSub Integration

For Elixir applications in the same cluster:

```elixir
defmodule MyApp.KillmailListener do
  use GenServer
  require Logger

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    # Subscribe to specific systems
    Phoenix.PubSub.subscribe(WandererKills.PubSub, "killmails:system:30000142")
    
    # Subscribe to specific characters
    Phoenix.PubSub.subscribe(WandererKills.PubSub, "killmails:character:95465499")
    
    {:ok, %{}}
  end

  @impl true
  def handle_info({:killmail, killmail}, state) do
    Logger.info("New killmail: #{killmail.killmail_id}")
    # Process killmail
    {:noreply, state}
  end

  @impl true
  def handle_info({:kill_count_update, %{system_id: system_id, count: count}}, state) do
    Logger.info("System #{system_id} now has #{count} kills")
    {:noreply, state}
  end
end
```

## Advanced Patterns

### Connection Pooling for HTTP Requests

```elixir
defmodule MyApp.ConnectionPool do
  @moduledoc """  
  Connection pool using Finch for efficient HTTP requests
  """
  
  def child_spec(_opts) do
    base_uri = URI.parse(base_url())
    port = base_uri.port || get_default_port(base_uri.scheme)
    
    Finch.child_spec(
      name: __MODULE__,
      pools: %{
        default: [size: 10, count: 1],
        # Specific pool for WandererKills API
        {base_uri.host, port} => [
          size: 5,
          count: 1,
          conn_opts: [keepalive: :timer.minutes(5)]
        ]
      }
    )
  end
  
  def request(method, url, headers \\ [], body \\ nil) do
    request = Finch.build(method, url, headers, body)
    
    case Finch.request(request, __MODULE__) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        Jason.decode(body)
        
      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}
        
      {:error, reason} ->
        {:error, reason}
    end
  end
  
  defp base_url do
    Application.get_env(:my_app, [:wanderer_kills, :base_url])
  end
  
  defp get_default_port("http"), do: 80
  defp get_default_port("https"), do: 443
  defp get_default_port(_), do: 80
end
```

### Local Caching with ETS

```elixir
defmodule MyApp.LocalCache do
  @moduledoc """
  Local ETS cache following WandererKills' 4-namespace pattern
  """
  use GenServer
  
  @namespaces %{
    killmails: :timer.minutes(5),
    systems: :timer.hours(1),
    esi_data: :timer.hours(24),
    temp_data: :timer.minutes(5)
  }
  
  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end
  
  def get(namespace, key) do
    case :ets.lookup(table_name(namespace), key) do
      [{^key, value, expiry}] ->
        if DateTime.compare(DateTime.utc_now(), expiry) == :lt do
          {:ok, value}
        else
          :ets.delete(table_name(namespace), key)
          {:error, :not_found}
        end
      [] ->
        {:error, :not_found}
    end
  end
  
  def put(namespace, key, value) do
    ttl = Map.get(@namespaces, namespace, :timer.minutes(5))
    expiry = DateTime.add(DateTime.utc_now(), ttl, :millisecond)
    :ets.insert(table_name(namespace), {key, value, expiry})
    :ok
  end
  
  @impl true
  def init(_) do
    tables = for {namespace, _ttl} <- @namespaces do
      table = table_name(namespace)
      :ets.new(table, [:set, :named_table, :public, read_concurrency: true])
      table
    end
    
    schedule_cleanup()
    {:ok, %{tables: tables}}
  end
  
  @impl true
  def handle_info(:cleanup, state) do
    Enum.each(state.tables, &cleanup_table/1)
    schedule_cleanup()
    {:noreply, state}
  end
  
  defp table_name(namespace), do: :"#{__MODULE__}_#{namespace}"
  
  defp cleanup_table(table) do
    now = DateTime.utc_now()
    :ets.select_delete(table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
  end
  
  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, :timer.minutes(1))
  end
end
```

## Error Handling

### Standardized Error Handling

```elixir
defmodule MyApp.ErrorHandler do
  @moduledoc """
  Error handling following WandererKills' standardized error patterns
  """
  require Logger
  
  # Handle standardized WandererKills API errors
  def handle_api_error({:ok, %{status: 429} = response}) do
    retry_after = get_retry_after(response.headers)
    Logger.warning("Rate limited, retrying after #{retry_after}ms")
    Process.sleep(retry_after)
    :retry
  end
  
  def handle_api_error({:ok, %{status: status}}) when status >= 500 do
    Logger.error("Server error: #{status}")
    {:error, :server_error}
  end
  
  def handle_api_error({:ok, %{status: 404}}) do
    {:error, :not_found}
  end
  
  def handle_api_error({:ok, %{status: 400, body: body}}) do
    case Jason.decode(body) do
      {:ok, %{"error" => error, "code" => code}} ->
        {:error, %{type: String.to_atom(code), message: error}}
      _ ->
        {:error, :bad_request}
    end
  end
  
  def handle_api_error({:error, %Mint.TransportError{reason: :timeout}}) do
    {:error, :timeout}
  end
  
  def handle_api_error({:error, reason}) do
    Logger.error("Unexpected error: #{inspect(reason)}")
    {:error, :unknown}
  end
  
  # Retry logic with exponential backoff
  def with_retry(func, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, 3)
    base_delay = Keyword.get(opts, :base_delay, 1_000)
    
    do_with_retry(func, max_attempts, base_delay, 1)
  end
  
  defp do_with_retry(func, max_attempts, delay, attempt) do
    case func.() do
      {:ok, _} = success -> success
      {:error, _} = error when attempt < max_attempts ->
        case handle_api_error(error) do
          :retry ->
            Process.sleep(delay)
            do_with_retry(func, max_attempts, delay * 2, attempt + 1)
          other ->
            other
        end
      error -> error
    end
  end
  
  defp get_retry_after(headers) do
    case List.keyfind(headers, "retry-after", 0) do
      {_, value} -> String.to_integer(value) * 1000
      nil -> 60_000  # Default to 1 minute
    end
  end
end
```

## Testing

### Testing HTTP API Calls

```elixir
# test/my_app/wanderer_client_test.exs
defmodule MyApp.WandererClientTest do
  use ExUnit.Case, async: true
  
  alias MyApp.WandererClient
  
  # Using Bypass for HTTP mocking
  setup do
    bypass = Bypass.open()
    Application.put_env(:my_app, [:wanderer_kills, :base_url], "http://localhost:#{bypass.port}")
    {:ok, bypass: bypass}
  end
  
  test "fetches system killmails successfully", %{bypass: bypass} do
    killmails = [
      %{"killmail_id" => 123, "solar_system_id" => 30000142},
      %{"killmail_id" => 124, "solar_system_id" => 30000142}
    ]
    
    Bypass.expect_once(bypass, "GET", "/api/v1/kills/system/30000142", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"data" => %{"kills" => killmails}}))
    end)
    
    assert {:ok, %{body: %{"data" => %{"kills" => ^killmails}}}} = 
      WandererClient.get_system_kills(30000142)
  end
  
  test "handles rate limiting with retry", %{bypass: bypass} do
    Bypass.expect(bypass, "GET", "/api/v1/kills/system/30000142", fn conn ->
      case Bypass.Pass.call_count(conn) do
        1 ->
          conn
          |> Plug.Conn.put_resp_header("retry-after", "1")
          |> Plug.Conn.resp(429, "Rate limited")
        2 ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(%{"data" => %{"kills" => []}}))
      end
    end)
    
    # With retry handler
    result = MyApp.ErrorHandler.with_retry(fn ->
      WandererClient.get_system_kills(30000142)
    end)
    
    assert {:ok, _} = result
  end
end
```

### Testing WebSocket Connections

```elixir
defmodule MyApp.KillmailSocketTest do
  use ExUnit.Case
  
  test "processes killmail updates" do
    # Start the socket
    {:ok, _pid} = MyApp.KillmailSocket.start_link(
      systems: [30000142],
      character_ids: [95465499]
    )
    
    # Simulate receiving a killmail update
    # In a real test, you'd use a mock WebSocket server
    killmail_payload = %{
      "system_id" => 30000142,
      "killmails" => [
        %{
          "killmail_id" => 123456,
          "solar_system_id" => 30000142,
          "kill_time" => "2024-01-15T14:30:00Z"
        }
      ],
      "preload" => false
    }
    
    # Test that the killmail was processed
    # Your assertions here based on your processing logic
  end
end
```

## Best Practices

1. **Connection Management**: Always implement reconnection logic with exponential backoff
2. **Error Handling**: Follow WandererKills' standardized error format
3. **Caching**: Use 4-namespace pattern (killmails, systems, esi_data, temp_data)
4. **Rate Limiting**: Handle 429 responses with retry-after header
5. **Performance**: Leverage sub-10μs cache operations
6. **Monitoring**: Use telemetry events for observability
7. **Testing**: Use Bypass for HTTP mocking, mock channels for WebSocket

## Complete Example Application

```elixir
# lib/my_app/application.ex
defmodule MyApp.Application do
  use Application
  
  @impl true
  def start(_type, _args) do
    children = [
      # HTTP connection pool
      MyApp.ConnectionPool,
      
      # Local cache with 4 namespaces
      MyApp.LocalCache,
      
      # WebSocket connection
      {MyApp.KillmailSocket, [
        systems: [30000142, 30000143],
        character_ids: [],
        preload: true
      ]},
      
      # Enhanced SSE stream (optional)
      {MyApp.EnhancedSSEClient, [
        character_ids: [95465499],
        preload_days: 30
      ]},
      
      # PubSub listener (if in same cluster)
      MyApp.KillmailListener
    ]
    
    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

## Summary

This guide covers all integration methods for WandererKills:

- **HTTP API**: RESTful endpoints with bulk operations
- **WebSocket**: Real-time updates via Phoenix channels
- **SSE**: Server-sent events with enhanced character preloading
- **PubSub**: Direct integration for Elixir apps in the same cluster

The simplified architecture provides:
- Sub-10μs cache operations
- 10,000+ concurrent WebSocket connections
- 50,000 character subscription support
- Standardized error handling
- 4-namespace caching pattern

For more details, see the [API & Integration Guide](API_AND_INTEGRATION_GUIDE.md).