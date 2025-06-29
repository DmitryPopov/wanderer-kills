defmodule WandererKillsWeb.Router do
  @moduledoc """
  Phoenix Router for WandererKills API endpoints.

  Replaces the previous Plug.Router implementation with proper Phoenix routing,
  pipelines, and better organization.
  """

  use Phoenix.Router

  import Plug.Conn
  import Phoenix.Controller

  # Pipelines

  pipeline :api do
    plug(:accepts, ["json"])
    plug(WandererKillsWeb.Plugs.ApiLogger)
  end

  pipeline :open_api_spec do
    plug(OpenApiSpex.Plug.PutApiSpec, module: WandererKillsWeb.ApiSpec)
  end

  pipeline :infrastructure do
    plug(:accepts, ["json", "text"])
  end

  pipeline :browser do
    plug(:accepts, ["html"])
  end

  pipeline :sse do
    # Don't use accepts plug for SSE - let the controller handle content type
    plug(WandererKillsWeb.Plugs.ApiLogger)
  end

  pipeline :debug do
    plug(WandererKillsWeb.Plugs.DebugOnly)
  end

  # Browser routes
  scope "/", WandererKillsWeb do
    pipe_through(:browser)

    get("/", PageController, :index)
  end

  # Health and service discovery routes (no versioning needed)
  scope "/", WandererKillsWeb do
    pipe_through(:infrastructure)

    get("/ping", HealthController, :ping)
    get("/health", HealthController, :health)
    get("/status", HealthController, :status)
    get("/metrics", HealthController, :metrics)

    # WebSocket connection info (infrastructure/service discovery)
    get("/websocket", WebSocketController, :info)
    get("/websocket/status", WebSocketController, :status)
  end

  # OpenAPI documentation
  scope "/api" do
    pipe_through([:api, :open_api_spec])

    get("/openapi", OpenApiSpex.Plug.RenderSpec, [])
  end

  # SSE streaming endpoint (separate pipeline for content-type handling)
  scope "/api/v1", WandererKillsWeb do
    pipe_through(:sse)

    get("/kills/stream", KillStreamController, :stream)
    get("/kills/stream/enhanced", EnhancedKillStreamController, :stream)
  end

  # API v1 routes
  scope "/api/v1", WandererKillsWeb do
    pipe_through(:api)

    # Kill management
    get("/kills/system/:system_id", KillsController, :list)
    post("/kills/systems", KillsController, :bulk)
    get("/kills/cached/:system_id", KillsController, :cached)
    get("/killmail/:killmail_id", KillsController, :show)
    get("/kills/count/:system_id", KillsController, :count)

    # Subscription management
    post("/subscriptions", SubscriptionController, :create)
    get("/subscriptions", SubscriptionController, :index)
    get("/subscriptions/stats", SubscriptionController, :stats)
    delete("/subscriptions/:subscriber_id", SubscriptionController, :delete)
  end

  # Debug endpoints - protected in production
  scope "/api/v1", WandererKillsWeb do
    pipe_through([:api, :debug])

    # Debug endpoints for SSE
    get("/kills/stream/cleanup", KillStreamController, :cleanup)
    get("/kills/stream/stats", KillStreamController, :stats)
    get("/kills/stream/test", KillStreamController, :test_broadcast)
  end

  # Catch-all for undefined API routes - must be last
  scope "/api/v1", WandererKillsWeb do
    pipe_through(:api)

    get("/*path", KillsController, :not_found)
    post("/*path", KillsController, :not_found)
    put("/*path", KillsController, :not_found)
    patch("/*path", KillsController, :not_found)
    delete("/*path", KillsController, :not_found)
  end
end
