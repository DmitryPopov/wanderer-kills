import Config

# Runtime configuration that can read environment variables
# This replaces the deprecated init/2 callback in the endpoint

# Helper module for port validation
defmodule RuntimeConfig.PortValidator do
  @moduledoc false

  def parse_and_validate_port(port_str, env_var_name) do
    case Integer.parse(port_str) do
      {port, ""} when port > 0 and port <= 65_535 ->
        port

      _ ->
        raise """
        Invalid #{env_var_name} environment variable: #{inspect(port_str)}
        #{env_var_name} must be a valid integer between 1 and 65535
        """
    end
  end
end

# Configure the port for the Phoenix endpoint
port_str = System.get_env("PORT") || "4004"
port = RuntimeConfig.PortValidator.parse_and_validate_port(port_str, "PORT")

config :wanderer_kills, WandererKillsWeb.Endpoint, http: [port: port]

# Configure feature flags from environment variables
smart_rate_limiting = System.get_env("SMART_RATE_LIMITING", "true") == "true"
request_coalescing = System.get_env("REQUEST_COALESCING", "true") == "true"

config :wanderer_kills, :features,
  smart_rate_limiting: smart_rate_limiting,
  request_coalescing: request_coalescing

# Configure URL settings for production deployment
# Set HOST for the application URL (defaults to localhost)
# Set SCHEME for the application URL (defaults to https in prod, http otherwise)
host = System.get_env("HOST") || "localhost"
scheme = System.get_env("SCHEME") || if(config_env() == :prod, do: "https", else: "http")

url_port =
  System.get_env("URL_PORT") || if(config_env() == :prod, do: "443", else: to_string(port))

# Parse URL port using the shared helper function
url_port_int = RuntimeConfig.PortValidator.parse_and_validate_port(url_port, "URL_PORT")

config :wanderer_kills, WandererKillsWeb.Endpoint,
  url: [host: host, port: url_port_int, scheme: scheme]

# Configure CORS/WebSocket origin checking
# In production, set ORIGIN_HOST to your actual domain
check_origin =
  case System.get_env("ORIGIN_HOST") do
    # Allow all origins in development
    nil -> false
    # Whitelist specific origin in production
    origin -> [origin]
  end

config :wanderer_kills, WandererKillsWeb.Endpoint, check_origin: check_origin

# Also configure the main application port for consistency
config :wanderer_kills, port: port

# Configure logging levels based on environment
log_level =
  case config_env() do
    :prod -> :info
    :test -> :warning
    :dev -> :debug
    _ -> :info
  end

config :logger, :default_handler, level: log_level

# Configure logger format and metadata based on environment
logger_metadata =
  case config_env() do
    :dev -> [:request_id, :file, :line]
    :test -> [:test]
    _ -> [:request_id, :operation, :killmail_id, :system_id, :application, :mfa]
  end

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: logger_metadata

# Development-specific configuration
if config_env() == :dev do
  config :wanderer_kills, WandererKillsWeb.Endpoint,
    debug_errors: true,
    code_reloader: true,
    live_reload: [
      patterns: [
        ~r"priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
        ~r"lib/wanderer_kills_web/(live|views)/.*(ex)$",
        ~r"lib/wanderer_kills_web/templates/.*(eex)$"
      ]
    ],
    socket_drainer_timeout: 60_000

  # Enable Phoenix debug logs in development
  config :phoenix, :logger, true
  config :phoenix, :stacktrace_depth, 20
end

# Test-specific configuration
if config_env() == :test do
  # Service startup flags
  config :wanderer_kills,
    services: [
      start_preloader: false,
      start_redisq: false
    ]
end

# Production-specific configuration
if config_env() == :prod do
  # Disable debug features
  config :wanderer_kills, WandererKillsWeb.Endpoint,
    debug_errors: false,
    code_reloader: false,
    socket_drainer_timeout: 60_000

  # Disable Phoenix debug logs
  config :phoenix, :logger, false
end
