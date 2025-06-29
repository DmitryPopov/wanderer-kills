import Config

# Set environment for runtime checks
config :wanderer_kills, env: :prod

# For production, configure the endpoint to load runtime configuration
# Note: Port and check_origin should be configured in runtime.exs
config :wanderer_kills, WandererKillsWeb.Endpoint,
  url: [host: "localhost", port: 443, scheme: "https"],
  server: true

# Configure logger for production
config :logger,
  level: :info,
  format: "$time $metadata[$level] $message\n"

# Runtime configuration should be loaded from runtime.exs
