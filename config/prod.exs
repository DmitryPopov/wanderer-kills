import Config

# Set environment for runtime checks
config :wanderer_kills, env: :prod

# For production, configure the endpoint to load runtime configuration
# Note: URL, port, and check_origin are now configured in runtime.exs via environment variables
config :wanderer_kills, WandererKillsWeb.Endpoint, server: true

# Configure logger for production
config :logger,
  level: :info,
  format: "$time $metadata[$level] $message\n"

# Runtime configuration should be loaded from runtime.exs
