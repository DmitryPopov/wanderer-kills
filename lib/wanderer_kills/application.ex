# lib/wanderer_kills/application.ex

defmodule WandererKills.Application do
  @moduledoc """
  OTP Application entry point for WandererKills.

  Supervises:
    1. EtsOwner for WebSocket stats tracking
    2. A Task.Supervisor for background jobs
    3. Phoenix.PubSub for event broadcasting
    4. SubscriptionSupervisor and related components for subscription handling
    5. Cachex instance for unified caching
    6. Observability/monitoring processes
    7. Phoenix Endpoint (WandererKillsWeb.Endpoint)
    8. Telemetry.Poller for periodic measurements
    9. RedisQ for real-time killmail streaming (conditionally)
  """

  use Application
  require Logger

  alias WandererKills.Config
  alias WandererKills.Core.Observability.Telemetry
  alias WandererKills.Core.ShipTypes.Updater
  alias WandererKills.Core.Storage.KillmailStore
  alias WandererKills.Core.Support.SupervisedTask
  import Cachex.Spec

  # Compile-time configuration
  @esi_ttl Application.compile_env(:wanderer_kills, [:cache, :esi_ttl], 3600)

  @impl true
  def start(_type, _args) do
    # 1) Initialize ETS for our unified KillmailStore
    KillmailStore.init_tables!()

    # 2) Attach telemetry handlers
    Telemetry.attach_handlers()

    # 3) Build children list
    children =
      (core_children() ++ cache_children() ++ observability_children())
      |> maybe_web_components()
      |> maybe_redisq()

    # 4) Start the supervisor
    opts = [strategy: :one_for_one, name: WandererKills.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Logger.info("[Application] Supervisor started successfully")
        # Start ship type update asynchronously without blocking application startup
        Task.Supervisor.start_child(WandererKills.TaskSupervisor, fn ->
          # Give the system a moment to fully start
          Process.sleep(1000)
          start_ship_type_update()
        end)

        Logger.info("[Application] Application startup completed successfully")
        {:ok, pid}

      error ->
        Logger.error("[Application] Supervisor failed to start: #{inspect(error)}")
        error
    end
  end

  # Core OTP processes that don't depend on web functionality
  defp core_children do
    base_children = [
      WandererKills.Core.EtsOwner,
      Task.Supervisor.child_spec(name: WandererKills.TaskSupervisor),
      {Phoenix.PubSub, name: WandererKills.PubSub},
      WandererKills.Subs.Subscriptions.CharacterIndex,
      WandererKills.Subs.Subscriptions.SystemIndex,
      WandererKills.Subs.SubscriptionRegistry,
      WandererKills.Subs.SubscriptionSupervisor,
      WandererKills.Ingest.RateLimiter,
      WandererKills.Ingest.HistoricalFetcher,
      WandererKills.Core.Storage.CleanupWorker
    ]

    # Add smart rate limiting components if enabled
    base_children ++ maybe_smart_rate_limiting_children()
  end

  defp maybe_smart_rate_limiting_children do
    features = Application.get_env(:wanderer_kills, :features, [])

    []
    |> maybe_add_request_coalescer(features[:request_coalescing])
    |> maybe_add_smart_rate_limiter(features[:smart_rate_limiting])
  end

  defp maybe_add_request_coalescer(children, true) do
    config = Application.get_env(:wanderer_kills, :request_coalescer, [])
    [{WandererKills.Ingest.RequestCoalescer, config} | children]
  end

  defp maybe_add_request_coalescer(children, _), do: children

  defp maybe_add_smart_rate_limiter(children, true) do
    config = Application.get_env(:wanderer_kills, :smart_rate_limiter, [])
    [{WandererKills.Ingest.SmartRateLimiter, config} | children]
  end

  defp maybe_add_smart_rate_limiter(children, _), do: children

  # Observability and monitoring processes
  defp observability_children do
    [
      WandererKills.Core.Observability.ApiTracker,
      WandererKills.Core.Observability.Metrics,
      WandererKills.Core.Observability.Monitoring,
      WandererKills.Core.Observability.TelemetryMetrics,
      WandererKills.Core.Observability.WebSocketStats,
      WandererKills.Core.Observability.UnifiedStatus,
      {:telemetry_poller, measurements: telemetry_measurements(), period: :timer.seconds(10)}
    ]
  end

  # Create a single Cachex instance with namespace support
  defp cache_children do
    default_ttl_ms = @esi_ttl * 1_000

    opts = [
      default_ttl: default_ttl_ms,
      expiration:
        expiration(
          interval: :timer.seconds(60),
          default: default_ttl_ms,
          lazy: true
        ),
      hooks: [
        hook(module: Cachex.Stats)
      ]
    ]

    [
      {Cachex, [:wanderer_cache, opts]}
    ]
  end

  defp telemetry_measurements do
    [
      {WandererKills.Core.Observability.Monitoring, :measure_http_requests, []},
      {WandererKills.Core.Observability.Monitoring, :measure_cache_operations, []},
      {WandererKills.Core.Observability.Monitoring, :measure_fetch_operations, []},
      {WandererKills.Core.Observability.Monitoring, :measure_system_resources, []},
      {WandererKills.Core.Observability.WebSocketStats, :measure_websocket_metrics, []}
    ]
  end

  # Conditionally include web components based on configuration
  defp maybe_web_components(children) do
    if start_web_components?() do
      children ++
        [
          WandererKillsWeb.Endpoint
        ]
    else
      children
    end
  end

  defp maybe_redisq(children) do
    if Config.start_redisq?() do
      children ++ [WandererKills.Ingest.RedisQ]
    else
      children
    end
  end

  # Check if web components should start
  # Can be disabled by setting WANDERER_KILLS_HEADLESS=true or :wanderer_kills, :headless = true
  defp start_web_components? do
    case System.get_env("WANDERER_KILLS_HEADLESS") do
      "true" -> false
      _ -> !Application.get_env(:wanderer_kills, :headless, false)
    end
  end

  @spec start_ship_type_update() :: :ok
  defp start_ship_type_update do
    task_result =
      SupervisedTask.start_child(
        &execute_ship_type_update/0,
        task_name: "ship_type_update",
        metadata: %{module: __MODULE__}
      )

    handle_task_start_result(task_result)
    :ok
  end

  defp execute_ship_type_update do
    case Updater.update_ship_types() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to update ship types: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp handle_task_start_result({:ok, _pid}) do
    Logger.debug("Ship type update task started successfully")
  end

  defp handle_task_start_result({:error, reason}) do
    Logger.error("Failed to start ship type update task: #{inspect(reason)}")
  end
end
