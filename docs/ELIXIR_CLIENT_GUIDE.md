# Elixir Client Guide for WandererKills

This guide provides comprehensive documentation for integrating with the WandererKills API using Elixir, including WebSocket/SSE real-time connections using Slipstream.

## Table of Contents

1. [Installation](#installation)
2. [Type-Safe Client Library](#type-safe-client-library)
3. [WebSocket Integration with Slipstream](#websocket-integration-with-slipstream)
4. [Server-Sent Events (SSE)](#server-sent-events-sse)
5. [Advanced Patterns](#advanced-patterns)
6. [Error Handling](#error-handling)
7. [Testing](#testing)

## Installation

### Using the Built-in Client Library

The WandererKills codebase includes a type-safe client that implements behaviours for compile-time safety:

```elixir
# In your mix.exs
defp deps do
  [
    {:wanderer_kills_client, git: "https://github.com/wanderer-industries/wanderer-kills.git", 
     sparse: "client", branch: "main"}
  ]
end
```

### For WebSocket Support with Slipstream

```elixir
defp deps do
  [
    {:slipstream, "~> 1.1"},
    {:jason, "~> 1.4"},
    {:req, "~> 0.5"}  # For HTTP requests
  ]
end
```

## Type-Safe Client Library

The WandererKills project provides a type-safe client through behaviours. Here's how to use it:

### Configuration

```elixir
# config/config.exs
config :wanderer_kills_client,
  base_url: "https://kills.wanderer.com",
  timeout: 30_000
```

### Basic Usage

```elixir
defmodule MyApp.KillmailService do
  alias WandererKills.Core.Client
  
  # Fetch killmails for a single system
  def get_system_kills(system_id, hours \\ 24) do
    case Client.fetch_system_killmails(system_id, hours, 100) do
      {:ok, killmails} -> 
        # Process killmails
        Enum.map(killmails, &process_killmail/1)
      
      {:error, %{type: type, message: message}} ->
        Logger.error("Failed to fetch kills: #{type} - #{message}")
        []
    end
  end
  
  # Fetch killmails for multiple systems
  def get_multiple_system_kills(system_ids) do
    case Client.fetch_systems_killmails(system_ids, 24, 50) do
      {:ok, results} ->
        # Results is a map of %{system_id => [killmails]}
        results
      
      {:error, error} ->
        %{}
    end
  end
  
  # Get a specific killmail
  def get_killmail(killmail_id) do
    Client.get_killmail(killmail_id)
  end
  
  # Subscribe to real-time updates
  def subscribe_to_systems(subscriber_id, system_ids, callback_url \\ nil) do
    case Client.subscribe_to_killmails(subscriber_id, system_ids, callback_url) do
      {:ok, subscription_id} ->
        Logger.info("Subscribed with ID: #{subscription_id}")
        {:ok, subscription_id}
      
      {:error, error} ->
        Logger.error("Subscription failed: #{inspect(error)}")
        {:error, error}
    end
  end
end
```

## WebSocket Integration with Slipstream

Slipstream provides a robust WebSocket client for Elixir. Here's a complete implementation:

### Basic WebSocket Client

```elixir
defmodule MyApp.KillmailSocket do
  use Slipstream
  
  require Logger
  
  @url "wss://kills.wanderer.com/socket/websocket"
  
  def start_link(config) do
    Slipstream.start_link(__MODULE__, config, name: __MODULE__)
  end
  
  @impl true
  def init(config) do
    {:ok, socket} = connect(config)
    {:ok, socket}
  end
  
  @impl true
  def handle_connect(socket) do
    Logger.info("Connected to WandererKills WebSocket")
    
    # Join killmail updates channel for specific systems
    systems = socket.assigns.systems
    
    Enum.each(systems, fn system_id ->
      {:ok, _ref} = join(socket, "killmail:#{system_id}")
    end)
    
    {:ok, socket}
  end
  
  @impl true
  def handle_disconnect(_reason, socket) do
    Logger.warning("Disconnected from WandererKills WebSocket")
    
    # Implement exponential backoff
    Process.sleep(socket.assigns[:retry_delay] || 1_000)
    
    socket = 
      socket
      |> assign(:retry_delay, min((socket.assigns[:retry_delay] || 1_000) * 2, 30_000))
    
    {:ok, socket} = reconnect(socket)
    {:ok, socket}
  end
  
  @impl true
  def handle_join("killmail:" <> system_id, _reply, socket) do
    Logger.info("Joined killmail channel for system #{system_id}")
    {:ok, socket}
  end
  
  @impl true
  def handle_message("killmail:" <> system_id, "new_killmail", payload, socket) do
    # Handle new killmail
    handle_new_killmail(system_id, payload, socket)
    {:ok, socket}
  end
  
  @impl true
  def handle_message("killmail:" <> system_id, "killmail_count", %{"count" => count}, socket) do
    # Handle killmail count update
    Logger.debug("System #{system_id} has #{count} killmails")
    {:ok, socket}
  end
  
  # Helper to connect with proper configuration
  defp connect(config) do
    socket = 
      new_socket()
      |> assign(:systems, config[:systems] || [])
      |> assign(:callbacks, config[:callbacks] || %{})
    
    uri = URI.parse(@url)
    
    connect_opts = [
      uri: uri,
      headers: config[:headers] || [],
      mint_opts: [
        protocols: [:http1],
        transport_opts: [
          timeout: 30_000,
          nodelay: true
        ]
      ]
    ]
    
    connect(socket, connect_opts)
  end
  
  defp handle_new_killmail(system_id, killmail, socket) do
    Logger.debug("New killmail in system #{system_id}: #{killmail["killmail_id"]}")
    
    # Call registered callback if exists
    if callback = get_in(socket.assigns, [:callbacks, :on_killmail]) do
      callback.({system_id, killmail})
    end
    
    # You can also broadcast to other parts of your app
    Phoenix.PubSub.broadcast(
      MyApp.PubSub,
      "killmails:#{system_id}",
      {:new_killmail, killmail}
    )
  end
end
```

### Advanced WebSocket Features

```elixir
defmodule MyApp.KillmailSocketSupervisor do
  use Supervisor
  
  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end
  
  @impl true
  def init(_init_arg) do
    children = [
      {MyApp.KillmailSocket, socket_config()}
    ]
    
    Supervisor.init(children, strategy: :one_for_one)
  end
  
  defp socket_config do
    %{
      systems: [30000142, 30000143, 30000144],  # Jita, Amarr, Dodixie
      headers: [{"x-api-key", api_key()}],
      callbacks: %{
        on_killmail: &MyApp.KillmailProcessor.process/1,
        on_error: &MyApp.ErrorHandler.handle_socket_error/1
      }
    }
  end
  
  defp api_key do
    Application.get_env(:my_app, :wanderer_api_key)
  end
end

# Channel-specific subscriptions
defmodule MyApp.ChannelManager do
  use GenServer
  
  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end
  
  def subscribe_to_system(system_id) do
    GenServer.call(__MODULE__, {:subscribe, system_id})
  end
  
  def unsubscribe_from_system(system_id) do
    GenServer.call(__MODULE__, {:unsubscribe, system_id})
  end
  
  @impl true
  def handle_call({:subscribe, system_id}, _from, state) do
    # Send join message through Slipstream
    MyApp.KillmailSocket.join("killmail:#{system_id}")
    
    state = Map.update(state, :subscriptions, [system_id], &[system_id | &1])
    {:reply, :ok, state}
  end
  
  @impl true
  def handle_call({:unsubscribe, system_id}, _from, state) do
    # Send leave message through Slipstream
    MyApp.KillmailSocket.leave("killmail:#{system_id}")
    
    subscriptions = Map.get(state, :subscriptions, []) -- [system_id]
    state = Map.put(state, :subscriptions, subscriptions)
    {:reply, :ok, state}
  end
end
```

## Server-Sent Events (SSE)

For SSE connections, you can use Req with streaming support:

```elixir
defmodule MyApp.SSEClient do
  require Logger
  
  @base_url "https://kills.wanderer.com"
  
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
    "#{@base_url}/api/sse/killmails?#{query}"
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
        MyApp.KillmailProcessor.process(killmail)
      
      {:error, _} ->
        Logger.error("Failed to parse SSE data: #{json}")
    end
  end
  
  defp process_sse_line("event: " <> event_type) do
    Logger.debug("SSE event: #{event_type}")
  end
  
  defp process_sse_line(_), do: :ok
end

# GenServer wrapper for continuous streaming
defmodule MyApp.SSEStreamServer do
  use GenServer
  
  def start_link(filters) do
    GenServer.start_link(__MODULE__, filters, name: __MODULE__)
  end
  
  @impl true
  def init(filters) do
    send(self(), :start_stream)
    {:ok, %{filters: filters, task: nil}}
  end
  
  @impl true
  def handle_info(:start_stream, state) do
    task = Task.async(fn ->
      MyApp.SSEClient.stream_killmails(state.filters)
    end)
    
    {:noreply, %{state | task: task}}
  end
  
  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    # Stream ended, restart after delay
    Process.sleep(5_000)
    send(self(), :start_stream)
    {:noreply, %{state | task: nil}}
  end
  
  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.error("SSE stream crashed: #{inspect(reason)}")
    Process.sleep(10_000)
    send(self(), :start_stream)
    {:noreply, %{state | task: nil}}
  end
end
```

## Advanced Patterns

### Connection Pooling for HTTP Requests

```elixir
defmodule MyApp.KillmailAPIPool do
  use GenServer
  
  @pool_size 5
  @base_url "https://kills.wanderer.com"
  
  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end
  
  def request(method, path, body \\ nil) do
    GenServer.call(__MODULE__, {:request, method, path, body})
  end
  
  @impl true
  def init(_) do
    # Initialize connection pool
    {:ok, conn_pid} = Finch.start_link(
      name: MyApp.Finch,
      pools: %{
        {@base_url, :https} => [size: @pool_size, count: 1]
      }
    )
    
    {:ok, %{finch: MyApp.Finch}}
  end
  
  @impl true
  def handle_call({:request, method, path, body}, _from, state) do
    url = "#{@base_url}#{path}"
    
    request = Finch.build(method, url, headers(), body)
    
    result = case Finch.request(request, state.finch) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, Jason.decode!(body)}
      
      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}
      
      {:error, reason} ->
        {:error, reason}
    end
    
    {:reply, result, state}
  end
  
  defp headers do
    [
      {"content-type", "application/json"},
      {"accept", "application/json"},
      {"user-agent", "MyApp/1.0"}
    ]
  end
end
```

### Caching Layer

```elixir
defmodule MyApp.KillmailCache do
  use GenServer
  
  @cache_ttl :timer.minutes(5)
  @max_cache_size 10_000
  
  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end
  
  def get_or_fetch(killmail_id, fetch_fn) do
    case get(killmail_id) do
      nil ->
        case fetch_fn.() do
          {:ok, killmail} ->
            put(killmail_id, killmail)
            {:ok, killmail}
          
          error ->
            error
        end
      
      killmail ->
        {:ok, killmail}
    end
  end
  
  def get(killmail_id) do
    GenServer.call(__MODULE__, {:get, killmail_id})
  end
  
  def put(killmail_id, killmail) do
    GenServer.cast(__MODULE__, {:put, killmail_id, killmail})
  end
  
  @impl true
  def init(_) do
    :ets.new(:killmail_cache, [:set, :named_table, :public, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{}}
  end
  
  @impl true
  def handle_call({:get, killmail_id}, _from, state) do
    result = case :ets.lookup(:killmail_cache, killmail_id) do
      [{^killmail_id, killmail, expiry}] ->
        if DateTime.compare(DateTime.utc_now(), expiry) == :lt do
          killmail
        else
          :ets.delete(:killmail_cache, killmail_id)
          nil
        end
      
      [] ->
        nil
    end
    
    {:reply, result, state}
  end
  
  @impl true
  def handle_cast({:put, killmail_id, killmail}, state) do
    expiry = DateTime.add(DateTime.utc_now(), @cache_ttl, :millisecond)
    :ets.insert(:killmail_cache, {killmail_id, killmail, expiry})
    
    # Evict old entries if cache is too large
    if :ets.info(:killmail_cache, :size) > @max_cache_size do
      evict_oldest()
    end
    
    {:noreply, state}
  end
  
  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end
  
  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, :timer.minutes(1))
  end
  
  defp cleanup_expired do
    now = DateTime.utc_now()
    
    :ets.select_delete(:killmail_cache, [
      {
        {:"$1", :"$2", :"$3"},
        [{:<, :"$3", now}],
        [true]
      }
    ])
  end
  
  defp evict_oldest do
    # Simple FIFO eviction
    case :ets.first(:killmail_cache) do
      :"$end_of_table" -> :ok
      key -> :ets.delete(:killmail_cache, key)
    end
  end
end
```

## Error Handling

### Comprehensive Error Handling

```elixir
defmodule MyApp.KillmailErrorHandler do
  require Logger
  
  def handle_api_error({:error, %{type: :rate_limit, retry_after: retry_after}}) do
    Logger.warning("Rate limited, retrying after #{retry_after}ms")
    Process.sleep(retry_after)
    :retry
  end
  
  def handle_api_error({:error, %{type: :timeout}}) do
    Logger.error("Request timeout")
    {:error, :timeout}
  end
  
  def handle_api_error({:error, %{type: :validation_error, message: message}}) do
    Logger.error("Validation error: #{message}")
    {:error, :invalid_request}
  end
  
  def handle_api_error({:error, %{type: :not_found}}) do
    Logger.debug("Resource not found")
    {:error, :not_found}
  end
  
  def handle_api_error({:error, reason}) do
    Logger.error("Unexpected error: #{inspect(reason)}")
    {:error, :unknown}
  end
  
  def with_retry(func, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, 3)
    delay = Keyword.get(opts, :initial_delay, 1_000)
    
    do_with_retry(func, max_attempts, delay, 1)
  end
  
  defp do_with_retry(func, max_attempts, delay, attempt) do
    case func.() do
      {:ok, result} ->
        {:ok, result}
      
      {:error, _} = error when attempt < max_attempts ->
        case handle_api_error(error) do
          :retry ->
            Process.sleep(delay)
            do_with_retry(func, max_attempts, delay * 2, attempt + 1)
          
          other ->
            other
        end
      
      error ->
        error
    end
  end
end
```

## Testing

### Mocking the Client Behaviour

```elixir
# test/support/mocks.ex
Mox.defmock(MyApp.MockKillmailClient, for: WandererKills.Core.ClientBehaviour)

# test/my_app/killmail_service_test.exs
defmodule MyApp.KillmailServiceTest do
  use ExUnit.Case, async: true
  
  import Mox
  
  alias MyApp.KillmailService
  
  setup :verify_on_exit!
  
  test "fetches system killmails successfully" do
    killmails = [
      %{"killmail_id" => 123, "solar_system_id" => 30000142},
      %{"killmail_id" => 124, "solar_system_id" => 30000142}
    ]
    
    expect(MyApp.MockKillmailClient, :fetch_system_killmails, fn 30000142, 24, 100 ->
      {:ok, killmails}
    end)
    
    assert {:ok, ^killmails} = KillmailService.get_system_kills(30000142)
  end
  
  test "handles API errors gracefully" do
    expect(MyApp.MockKillmailClient, :fetch_system_killmails, fn _, _, _ ->
      {:error, %{type: :timeout, message: "Request timed out"}}
    end)
    
    assert [] = KillmailService.get_system_kills(30000142)
  end
end
```

### Testing WebSocket Connections

```elixir
defmodule MyApp.KillmailSocketTest do
  use ExUnit.Case
  
  import ExUnit.CaptureLog
  
  alias MyApp.KillmailSocket
  
  setup do
    # Start a mock WebSocket server
    {:ok, _} = MockWebSocketServer.start(port: 4001)
    
    on_exit(fn ->
      MockWebSocketServer.stop()
    end)
    
    :ok
  end
  
  test "connects and joins channels" do
    config = %{
      systems: [30000142],
      url: "ws://localhost:4001/socket/websocket"
    }
    
    {:ok, pid} = KillmailSocket.start_link(config)
    
    # Wait for connection
    Process.sleep(100)
    
    assert Process.alive?(pid)
    assert MockWebSocketServer.channel_joined?("killmail:30000142")
  end
  
  test "handles disconnections with exponential backoff" do
    config = %{systems: [], url: "ws://localhost:4001/socket/websocket"}
    
    log = capture_log(fn ->
      {:ok, pid} = KillmailSocket.start_link(config)
      
      # Simulate disconnect
      MockWebSocketServer.disconnect_client(pid)
      
      Process.sleep(200)
    end)
    
    assert log =~ "Disconnected from WandererKills WebSocket"
    assert log =~ "Connected to WandererKills WebSocket"
  end
end
```

## Best Practices

1. **Connection Management**: Always implement reconnection logic with exponential backoff
2. **Error Handling**: Use pattern matching on error tuples for specific error handling
3. **Caching**: Implement local caching to reduce API calls
4. **Rate Limiting**: Respect rate limits and implement client-side throttling
5. **Monitoring**: Add telemetry and logging for debugging production issues
6. **Testing**: Use behaviours and mocks for comprehensive testing

## Complete Example Application

```elixir
# lib/my_app/application.ex
defmodule MyApp.Application do
  use Application
  
  @impl true
  def start(_type, _args) do
    children = [
      # HTTP connection pool
      {Finch, name: MyApp.Finch},
      
      # Cache
      MyApp.KillmailCache,
      
      # WebSocket supervisor
      MyApp.KillmailSocketSupervisor,
      
      # SSE stream (optional)
      {MyApp.SSEStreamServer, %{
        solar_system_id: [30000142, 30000143],
        ship_type_id: [587, 11567]  # Rifter, Raven
      }},
      
      # Your app's PubSub
      {Phoenix.PubSub, name: MyApp.PubSub}
    ]
    
    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

This guide provides a comprehensive approach to integrating with WandererKills using both the built-in type-safe client and Slipstream for WebSocket connections. The examples demonstrate production-ready patterns including error handling, caching, connection management, and testing strategies.