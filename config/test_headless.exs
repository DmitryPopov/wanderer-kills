import Config

# Headless configuration for core functionality tests
# This allows testing business logic without Phoenix web components

# Core application configuration (subset of test.exs)
config :wanderer_kills,
  # Use ETS adapter for tests instead of Cachex
  cache_adapter: WandererKills.Core.Cache.ETSAdapter,
  # Run in headless mode
  headless: true,
  # Service configuration
  services: [
    start_preloader: false,
    start_redisq: false
  ],

  # Cache configuration - stable TTL for tests
  cache: [
    killmails_ttl: 10,
    system_ttl: 10,
    esi_ttl: 10,
    esi_killmail_ttl: 10,
    system_recent_fetch_threshold: 5
  ],

  # HTTP retry configuration
  http: [
    client: WandererKills.Http.ClientMock,
    request_timeout_ms: 1_000,
    default_timeout_ms: 1_000,
    retry: [
      max_retries: 1,
      base_delay: 100,
      max_delay: 1_000
    ]
  ],

  # Storage configuration
  storage: [
    enable_event_streaming: false,
    gc_interval_ms: 100,
    max_events_per_system: 100
  ],

  # Mock clients for testing
  zkb_client: WandererKills.Ingest.Killmails.ZkbClient.Mock,
  esi_client: WandererKills.Ingest.ESI.Client.Mock

# Logger configuration for headless tests
config :logger, :default_handler, level: :warn

# Configure Mox - use global mode if available
if Code.ensure_loaded?(Mox) do
  config :mox, global: true
end
