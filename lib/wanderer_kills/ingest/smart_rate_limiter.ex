defmodule WandererKills.Ingest.SmartRateLimiter do
  @moduledoc """
  Intelligent rate limiter that queues requests when rate limits are hit
  and processes them with priority-based scheduling.

  Features:
  - Priority-based request queuing
  - Request deduplication and coalescing
  - Adaptive rate window detection
  - Circuit breaker for persistent rate limiting
  - Backpressure management
  """

  use GenServer
  require Logger

  alias WandererKills.Core.Support.Error
  alias WandererKills.Ingest.Killmails.ZkbClient

  # Request priorities (lower number = higher priority)
  @priorities %{
    # Real-time killmail fetches
    realtime: 1,
    # WebSocket preload requests
    preload: 2,
    # Background system updates
    background: 3,
    # Historical streaming (low priority)
    historical: 4,
    # Bulk operations
    bulk: 5
  }

  defmodule State do
    @moduledoc "Internal state for SmartRateLimiter GenServer"
    defstruct [
      # Mode: :simple or :advanced
      mode: :simple,

      # Simple mode state (backward compatible with RateLimiter)
      service_buckets: %{},

      # Advanced mode state
      # Request queue (priority queue)
      request_queue: :queue.new(),
      # Pending requests (for deduplication)
      pending_requests: %{},
      # Rate limit state
      current_tokens: 0,
      max_tokens: 100,
      refill_rate: 50,
      last_refill: nil,
      # Circuit breaker
      circuit_state: :closed,
      failure_count: 0,
      last_failure: nil,
      # 30 seconds
      circuit_timeout: 30_000,
      # Rate window detection
      rate_limit_history: [],
      # Default 1 minute
      detected_window_ms: 60_000,

      # Configuration
      config: %{}
    ]
  end

  defmodule Request do
    @moduledoc "Request structure for rate-limited API calls"
    defstruct [
      :id,
      # :system_killmails, :killmail, etc.
      :type,
      # %{system_id: 123, opts: []}
      :params,
      # :realtime, :preload, :background, :bulk
      :priority,
      :requester_pid,
      :reply_ref,
      :created_at,
      :timeout_ref,
      # Timeout in milliseconds for this request
      :timeout
    ]
  end

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check rate limit for a service or URL.

  ## Examples

      check_rate_limit(:zkillboard)
      check_rate_limit("https://zkillboard.com/api/...")

  Returns :ok if a token was available, {:error, _} otherwise.
  """
  @spec check_rate_limit(:zkillboard | :esi) :: :ok | {:error, Error.t()}
  def check_rate_limit(service) when service in [:zkillboard, :esi] do
    GenServer.call(__MODULE__, {:consume_token, service})
  end

  @spec check_rate_limit(String.t()) :: :ok | {:error, :rate_limited}
  def check_rate_limit(url) when is_binary(url) do
    service =
      cond do
        String.contains?(url, "zkillboard.com") -> :zkillboard
        String.contains?(url, "zkillredisq.stream") -> :zkillboard
        String.contains?(url, "esi.evetech.net") -> :esi
        true -> nil
      end

    if service do
      case check_rate_limit(service) do
        :ok -> :ok
        {:error, _} -> {:error, :rate_limited}
      end
    else
      # Unknown service, allow it
      :ok
    end
  end

  @doc """
  Gets the current state of a bucket (simple mode, for monitoring/debugging).
  """
  @spec get_bucket_state(:zkillboard | :esi) :: map()
  def get_bucket_state(service) when service in [:zkillboard, :esi] do
    GenServer.call(__MODULE__, {:get_bucket_state, service})
  end

  @doc """
  Resets a bucket to full capacity (simple mode, useful for testing).
  """
  @spec reset_bucket(:zkillboard | :esi) :: :ok
  def reset_bucket(service) when service in [:zkillboard, :esi] do
    GenServer.cast(__MODULE__, {:reset_bucket, service})
  end

  @doc """
  Request system killmails with intelligent rate limiting.

  ## Options
    * `:priority` - Request priority (:realtime, :preload, :background, :bulk)
    * `:timeout` - Request timeout in milliseconds (default: 30_000)
    * `:coalesce` - Whether to coalesce with existing identical requests (default: true)
  """
  def request_system_killmails(system_id, opts \\ [], request_opts \\ []) do
    priority = Keyword.get(request_opts, :priority, :background)
    timeout = Keyword.get(request_opts, :timeout, 30_000)
    coalesce = Keyword.get(request_opts, :coalesce, true)

    request = %Request{
      id: generate_request_id(),
      type: :system_killmails,
      params: %{system_id: system_id, opts: opts},
      priority: priority,
      requester_pid: self(),
      reply_ref: make_ref(),
      created_at: System.monotonic_time(:millisecond),
      timeout: timeout
    }

    GenServer.call(__MODULE__, {:request, request, coalesce}, timeout)
  end

  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    # Get mode from configuration or default to simple
    mode = Keyword.get(opts, :mode, get_mode_from_config())

    case mode do
      :simple ->
        init_simple_mode(opts)

      :advanced ->
        init_advanced_mode(opts)

      _ ->
        Logger.warning("[SmartRateLimiter] Unknown mode #{inspect(mode)}, defaulting to simple")
        init_simple_mode(opts)
    end
  end

  defp get_mode_from_config do
    Application.get_env(:wanderer_kills, :smart_rate_limiter, [])
    |> Keyword.get(:mode, :simple)
  end

  defp init_simple_mode(opts) do
    # Get configuration from smart_rate_limiter application env or opts
    app_config = Application.get_env(:wanderer_kills, :smart_rate_limiter, [])

    zkb_capacity = app_config[:zkb_capacity] || Keyword.get(opts, :zkb_capacity, 10)
    zkb_refill_rate = app_config[:zkb_refill_rate] || Keyword.get(opts, :zkb_refill_rate, 10)
    esi_capacity = app_config[:esi_capacity] || Keyword.get(opts, :esi_capacity, 100)
    esi_refill_rate = app_config[:esi_refill_rate] || Keyword.get(opts, :esi_refill_rate, 100)

    service_buckets = %{
      zkillboard: %{
        tokens: zkb_capacity * 1.0,
        capacity: zkb_capacity,
        refill_rate: zkb_refill_rate,
        last_refill: System.monotonic_time(:millisecond)
      },
      esi: %{
        tokens: esi_capacity * 1.0,
        capacity: esi_capacity,
        refill_rate: esi_refill_rate,
        last_refill: System.monotonic_time(:millisecond)
      }
    }

    state = %State{
      mode: :simple,
      service_buckets: service_buckets,
      config: %{
        zkb_capacity: zkb_capacity,
        zkb_refill_rate: zkb_refill_rate,
        esi_capacity: esi_capacity,
        esi_refill_rate: esi_refill_rate
      }
    }

    # Schedule periodic token refill every second
    Process.send_after(self(), :refill_tokens, 1_000)

    Logger.info("[SmartRateLimiter] Started in simple mode",
      zkb_capacity: zkb_capacity,
      zkb_refill_rate: zkb_refill_rate,
      esi_capacity: esi_capacity,
      esi_refill_rate: esi_refill_rate
    )

    {:ok, state}
  end

  defp init_advanced_mode(opts) do
    config = %{
      max_tokens: Keyword.get(opts, :max_tokens, 100),
      refill_rate: Keyword.get(opts, :refill_rate, 50),
      refill_interval_ms: Keyword.get(opts, :refill_interval_ms, 1000),
      circuit_failure_threshold: Keyword.get(opts, :circuit_failure_threshold, 5),
      circuit_timeout_ms: Keyword.get(opts, :circuit_timeout_ms, 30_000),
      queue_timeout_ms: Keyword.get(opts, :queue_timeout_ms, 60_000)
    }

    state = %State{
      mode: :advanced,
      current_tokens: config.max_tokens,
      max_tokens: config.max_tokens,
      refill_rate: config.refill_rate,
      last_refill: System.monotonic_time(:millisecond),
      circuit_timeout: config.circuit_timeout_ms,
      config: config
    }

    # Schedule token refill
    schedule_token_refill(config.refill_interval_ms)

    Logger.info("[SmartRateLimiter] Started in advanced mode with config: #{inspect(config)}")

    {:ok, state}
  end

  @impl true
  def handle_call({:request, request, _coalesce}, _from, %{mode: :simple} = state) do
    # In simple mode, immediately execute the request without queueing
    case ZkbClient.fetch_system_killmails(request.params.system_id, request.params.opts) do
      {:ok, kills} ->
        {:reply, {:ok, kills}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:consume_token, service}, _from, %{mode: :simple} = state) do
    handle_simple_token_consumption(service, state)
  end

  def handle_call({:get_bucket_state, service}, _from, %{mode: :simple} = state) do
    bucket = Map.get(state.service_buckets, service)

    if bucket do
      # Calculate current tokens with refill
      now = System.monotonic_time(:millisecond)
      elapsed_ms = now - bucket.last_refill
      elapsed_minutes = elapsed_ms / 60_000

      tokens_to_add = elapsed_minutes * bucket.refill_rate
      current_tokens = min(bucket.tokens + tokens_to_add, bucket.capacity * 1.0)

      bucket_info = %{bucket | tokens: current_tokens}
      {:reply, bucket_info, state}
    else
      {:reply, %{tokens: 0, capacity: 0, refill_rate: 0, last_refill: 0}, state}
    end
  end

  def handle_call({:request, request, coalesce}, from, %{mode: :advanced} = state) do
    case state.circuit_state do
      :open ->
        # Circuit is open, reject immediately
        {:reply,
         {:error, Error.rate_limit_error("Circuit breaker is open", %{reason: :circuit_open})},
         state}

      _ ->
        # Try to process request or queue it
        handle_request(request, from, coalesce, state)
    end
  end

  def handle_call(:get_stats, _from, %{mode: :simple} = state) do
    stats = %{
      mode: :simple,
      service_buckets: state.service_buckets,
      zkb_tokens: get_in(state.service_buckets, [:zkillboard, :tokens]) || 0,
      esi_tokens: get_in(state.service_buckets, [:esi, :tokens]) || 0
    }

    {:reply, {:ok, stats}, state}
  end

  def handle_call(:get_stats, _from, %{mode: :advanced} = state) do
    stats = %{
      mode: :advanced,
      circuit_state: state.circuit_state,
      current_tokens: state.current_tokens,
      queue_size: :queue.len(state.request_queue),
      pending_requests: map_size(state.pending_requests),
      failure_count: state.failure_count,
      detected_window_ms: state.detected_window_ms
    }

    {:reply, {:ok, stats}, state}
  end

  @impl true
  def handle_cast({:reset_bucket, service}, %{mode: :simple} = state) do
    case Map.get(state.service_buckets, service) do
      nil ->
        {:noreply, state}

      bucket ->
        updated_bucket = %{
          bucket
          | tokens: bucket.capacity * 1.0,
            last_refill: System.monotonic_time(:millisecond)
        }

        new_buckets = Map.put(state.service_buckets, service, updated_bucket)
        new_state = %{state | service_buckets: new_buckets}

        Logger.info("[SmartRateLimiter] Simple mode bucket reset",
          service: service,
          tokens: bucket.capacity
        )

        {:noreply, new_state}
    end
  end

  def handle_cast({:request_complete, request_id, result}, %{mode: :advanced} = state) do
    # Handle completed request and reply to all waiters
    case find_and_remove_pending_request(state.pending_requests, request_id) do
      {nil, pending_requests} ->
        # Request not found (maybe timed out already)
        {:noreply, %{state | pending_requests: pending_requests}}

      {pending_request, pending_requests} ->
        # Cancel timeout if it exists
        if pending_request[:timeout_ref] do
          Process.cancel_timer(pending_request.timeout_ref)
        end

        # Reply to all waiters
        Enum.each(pending_request.waiters, fn waiter ->
          GenServer.reply(waiter, result)
        end)

        # Update circuit breaker state based on result
        updated_state =
          update_circuit_breaker_state(result, %{state | pending_requests: pending_requests})

        # Try to process more requests from queue
        final_state = process_queue(updated_state)

        {:noreply, final_state}
    end
  end

  @impl true
  def handle_info(:refill_tokens, %{mode: :simple} = state) do
    new_state = refill_simple_tokens(state)

    # Schedule next refill
    Process.send_after(self(), :refill_tokens, 1_000)

    {:noreply, new_state}
  end

  def handle_info(:refill_tokens, %{mode: :advanced} = state) do
    new_state = refill_tokens(state)

    # Try to process queued requests
    final_state = process_queue(new_state)

    # Schedule next refill
    schedule_token_refill(state.config.refill_interval_ms)

    {:noreply, final_state}
  end

  def handle_info(:process_queue, %{mode: :advanced} = state) do
    # Process queued requests after delay
    new_state = process_queue(state)
    {:noreply, new_state}
  end

  def handle_info(:check_circuit, %{mode: :advanced} = state) do
    new_state =
      if state.circuit_state == :open do
        # Try to transition to half-open
        %{state | circuit_state: :half_open, failure_count: 0}
      else
        state
      end

    {:noreply, new_state}
  end

  def handle_info({:request_timeout, request_id}, %{mode: :advanced} = state) do
    # Handle request timeout
    new_state = handle_request_timeout(request_id, state)
    {:noreply, new_state}
  end

  # Catch-all for other messages in simple mode
  def handle_info(_msg, %{mode: :simple} = state) do
    {:noreply, state}
  end

  ## Private Functions

  # Simple mode functions (backward compatible with RateLimiter)

  defp handle_simple_token_consumption(service, state) do
    bucket = Map.get(state.service_buckets, service)

    if bucket && bucket.tokens >= 1.0 do
      # Consume a token
      updated_bucket = %{bucket | tokens: bucket.tokens - 1.0}
      new_buckets = Map.put(state.service_buckets, service, updated_bucket)
      new_state = %{state | service_buckets: new_buckets}

      # Emit telemetry for successful token consumption
      :telemetry.execute(
        [:wanderer_kills, :rate_limiter, :token_consumed],
        %{tokens_remaining: updated_bucket.tokens},
        %{service: service}
      )

      {:reply, :ok, new_state}
    else
      # No tokens available
      tokens_available = if bucket, do: bucket.tokens, else: 0
      capacity = if bucket, do: bucket.capacity, else: 0
      refill_rate = if bucket, do: bucket.refill_rate, else: 0

      Logger.warning("[SmartRateLimiter] Simple mode rate limit exceeded",
        service: service,
        available_tokens: tokens_available,
        capacity: capacity
      )

      # Emit telemetry for rate limit exceeded
      :telemetry.execute(
        [:wanderer_kills, :rate_limiter, :rate_limited],
        %{tokens_available: tokens_available},
        %{service: service}
      )

      # Calculate time until next token is available
      tokens_needed = 1.0 - tokens_available
      minutes_to_wait = if refill_rate > 0, do: tokens_needed / refill_rate, else: 1.0
      retry_after_ms = ceil(minutes_to_wait * 60_000)

      {:reply,
       {:error,
        Error.rate_limit_error("Rate limit exceeded for #{service}", %{
          service: service,
          tokens_available: tokens_available,
          retry_after_ms: retry_after_ms
        })}, state}
    end
  end

  defp refill_simple_tokens(state) do
    now = System.monotonic_time(:millisecond)

    new_buckets =
      Enum.reduce(state.service_buckets, %{}, fn {service, bucket}, acc ->
        elapsed_ms = now - bucket.last_refill
        elapsed_minutes = elapsed_ms / 60_000

        tokens_to_add = elapsed_minutes * bucket.refill_rate
        new_tokens = min(bucket.tokens + tokens_to_add, bucket.capacity * 1.0)

        updated_bucket = %{bucket | tokens: new_tokens, last_refill: now}
        Map.put(acc, service, updated_bucket)
      end)

    %{state | service_buckets: new_buckets}
  end

  # Advanced mode functions

  defp handle_request(request, from, coalesce, state) do
    request_key = request_key(request)

    cond do
      # Check if we can coalesce with existing request
      coalesce and Map.has_key?(state.pending_requests, request_key) ->
        # Add to existing request's waiters
        updated_pending = add_waiter_to_pending(state.pending_requests, request_key, from)
        new_state = %{state | pending_requests: updated_pending}
        {:noreply, new_state}

      # Check if we have tokens available
      state.current_tokens > 0 ->
        # Process immediately
        execute_request(request, from, state)

      true ->
        # Queue the request
        queue_request(request, from, state)
    end
  end

  defp execute_request(request, from, state) do
    # Consume a token
    new_state = %{state | current_tokens: state.current_tokens - 1}

    # Add to pending requests
    request_key = request_key(request)

    # Set timeout for request
    timeout_ms = request.timeout || 30_000
    timeout_ref = Process.send_after(self(), {:request_timeout, request.id}, timeout_ms)

    pending_requests =
      Map.put(state.pending_requests, request_key, %{
        request: request,
        waiters: [from],
        started_at: System.monotonic_time(:millisecond),
        timeout_ref: timeout_ref
      })

    # Execute the actual request asynchronously
    Task.start(fn ->
      result =
        try do
          perform_zkb_request(request)
        rescue
          error -> {:error, error}
        catch
          :exit, reason -> {:error, {:exit, reason}}
        end

      GenServer.cast(__MODULE__, {:request_complete, request.id, result})
    end)

    updated_state = %{new_state | pending_requests: pending_requests}

    {:noreply, updated_state}
  end

  defp queue_request(request, from, state) do
    # Add timeout for queued request
    timeout_ref =
      Process.send_after(self(), {:request_timeout, request.id}, state.config.queue_timeout_ms)

    # Create priority queue item
    queue_item = {priority_value(request.priority), request, from, timeout_ref}

    # Add to priority queue
    new_queue = :queue.in(queue_item, state.request_queue)
    new_state = %{state | request_queue: new_queue}

    Logger.debug("[SmartRateLimiter] Queued request",
      request_id: request.id,
      priority: request.priority,
      queue_size: :queue.len(new_queue)
    )

    {:noreply, new_state}
  end

  defp process_queue(state), do: process_queue(state, 0)

  defp process_queue(state, depth) when depth >= 10 do
    # Prevent infinite recursion - schedule another process later
    Process.send_after(self(), :process_queue, 10)
    state
  end

  defp process_queue(state, depth) do
    if state.current_tokens > 0 and not :queue.is_empty(state.request_queue) do
      new_state = execute_next_queued_request(state)
      # Continue processing with incremented depth
      process_queue(new_state, depth + 1)
    else
      state
    end
  end

  defp execute_next_queued_request(state) do
    case :queue.out(state.request_queue) do
      {{:value, {_priority, request, from, timeout_ref}}, new_queue} ->
        # Cancel timeout
        Process.cancel_timer(timeout_ref)

        # Execute the request
        {:noreply, new_state} =
          execute_request(request, from, %{state | request_queue: new_queue})

        new_state

      {:empty, _} ->
        state
    end
  end

  defp perform_zkb_request(request) do
    alias WandererKills.Ingest.Killmails.ZkbClient

    case request.type do
      :system_killmails ->
        ZkbClient.fetch_system_killmails(
          request.params.system_id,
          request.params.opts
        )

      :killmail ->
        ZkbClient.fetch_killmail(request.params.killmail_id)

      _ ->
        {:error, Error.validation_error(:unknown_request_type, "Unknown request type")}
    end
  end

  defp refill_tokens(state) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - state.last_refill

    # Calculate tokens to add based on elapsed time
    tokens_to_add = trunc(elapsed * state.refill_rate / 1000)
    new_tokens = min(state.current_tokens + tokens_to_add, state.max_tokens)

    %{state | current_tokens: new_tokens, last_refill: now}
  end

  defp request_key(request) do
    # Create a key for request deduplication
    case request.type do
      :system_killmails ->
        {request.type, request.params.system_id, request.params.opts}

      :killmail ->
        {request.type, request.params.killmail_id}

      _ ->
        {request.type, request.params}
    end
  end

  defp priority_value(priority) do
    Map.get(@priorities, priority, 999)
  end

  defp generate_request_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp schedule_token_refill(interval) do
    Process.send_after(self(), :refill_tokens, interval)
  end

  defp add_waiter_to_pending(pending_requests, request_key, from) do
    case Map.get(pending_requests, request_key) do
      nil ->
        pending_requests

      pending ->
        updated_waiters = [from | pending.waiters]
        Map.put(pending_requests, request_key, %{pending | waiters: updated_waiters})
    end
  end

  defp handle_request_timeout(request_id, state) do
    # Find and remove timed out request from queue or pending
    Logger.warning("[SmartRateLimiter] Request timeout", request_id: request_id)

    # Check if it's in pending requests
    pending_key = find_pending_request_key(state.pending_requests, request_id)

    if pending_key do
      handle_pending_timeout(state, pending_key)
    else
      # Check if it's in the queue
      new_queue = remove_from_queue(state.request_queue, request_id)
      %{state | request_queue: new_queue}
    end
  end

  defp handle_pending_timeout(state, pending_key) do
    case Map.get(state.pending_requests, pending_key) do
      nil ->
        state

      pending ->
        Enum.each(pending.waiters, fn from ->
          GenServer.reply(from, {:error, Error.timeout_error("Request timed out")})
        end)

        %{state | pending_requests: Map.delete(state.pending_requests, pending_key)}
    end
  end

  defp find_pending_request_key(pending_requests, request_id) do
    Enum.find_value(pending_requests, fn {key, pending} ->
      if pending.request.id == request_id, do: key, else: nil
    end)
  end

  defp remove_from_queue(queue, request_id) do
    items = :queue.to_list(queue)

    filtered =
      Enum.reject(items, fn {_priority, request, from, _timeout_ref} ->
        if request.id == request_id do
          # Reply with timeout error
          GenServer.reply(from, {:error, Error.timeout_error("Request timed out in queue")})
          true
        else
          false
        end
      end)

    :queue.from_list(filtered)
  end

  defp find_and_remove_pending_request(pending_requests, request_id) do
    case Enum.find(pending_requests, fn {_key, pending} ->
           pending.request.id == request_id
         end) do
      nil ->
        {nil, pending_requests}

      {request_key, pending_request} ->
        updated_pending = Map.delete(pending_requests, request_key)
        {pending_request, updated_pending}
    end
  end

  defp update_circuit_breaker_state({:ok, _}, state) do
    # Success - reset failure count
    %{state | failure_count: 0, circuit_state: :closed}
  end

  defp update_circuit_breaker_state({:error, %{type: :rate_limited}}, state) do
    # Rate limited - increment failure count
    new_failure_count = state.failure_count + 1

    if new_failure_count >= state.config.circuit_failure_threshold do
      # Open circuit breaker
      Logger.warning(
        "[SmartRateLimiter] Opening circuit breaker after #{new_failure_count} failures"
      )

      Process.send_after(self(), :check_circuit, state.circuit_timeout)

      %{
        state
        | failure_count: new_failure_count,
          circuit_state: :open,
          last_failure: System.monotonic_time(:millisecond)
      }
    else
      %{state | failure_count: new_failure_count}
    end
  end

  defp update_circuit_breaker_state({:error, _}, state) do
    # Other errors - don't affect circuit breaker
    state
  end
end
