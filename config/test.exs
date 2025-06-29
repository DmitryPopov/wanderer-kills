import Config

# Configure the application for testing with nested structure
config :wanderer_kills,
  # Set environment for runtime checks
  env: :test,
  # Use ETS adapter for tests instead of Cachex
  cache_adapter: WandererKills.Core.Cache.ETSAdapter,
  # Run in headless mode by default for core tests
  headless: false,
  # Service configuration
  services: [
    start_preloader: false,
    start_redisq: false
  ],

  # Cache configuration - stable TTL for tests to prevent flakiness
  cache: [
    killmails_ttl: 10,
    system_ttl: 10,
    esi_ttl: 10,
    esi_killmail_ttl: 10,
    system_recent_fetch_threshold: 5
  ],

  # HTTP retry configuration
  http: [
    client: WandererKills.Ingest.Http.Client.Mock,
    request_timeout_ms: 1_000,
    default_timeout_ms: 1_000,
    retry: [
      max_retries: 1,
      base_delay: 100,
      max_delay: 1_000
    ]
  ],

  # ESI configuration for tests
  esi: [
    base_url: "https://esi.test.local",
    request_timeout_ms: 1_000,
    batch_concurrency: 2
  ],

  # ZKillboard configuration for tests
  zkb: [
    base_url: "https://zkb.test.local",
    request_timeout_ms: 1_000,
    batch_concurrency: 2
  ],

  # RedisQ configuration for tests
  redisq: [
    base_url: "https://redisq.test.local",
    fast_interval_ms: 100,
    idle_interval_ms: 100,
    task_timeout_ms: 1_000,
    retry: [
      max_retries: 1,
      base_delay: 100
    ]
  ],

  # Parser configuration
  parser: [
    cutoff_seconds: 60,
    summary_interval_ms: 100
  ],

  # Enricher configuration
  enricher: [
    max_concurrency: 2,
    task_timeout_ms: 1_000,
    min_attackers_for_parallel: 10
  ],

  # Storage configuration
  storage: [
    enable_event_streaming: false,
    gc_interval_ms: 100,
    max_events_per_system: 100
  ],

  # Monitoring configuration
  monitoring: [
    status_interval_ms: 60_000,
    health_check_interval_ms: 30_000
  ],

  # Telemetry configuration - disabled for tests
  telemetry: [
    enabled_metrics: [],
    sampling_rate: 0.0,
    retention_period: 60
  ],

  # Mock clients for testing (legacy flat config for now)
  zkb_client: WandererKills.Ingest.Killmails.ZkbClient.Mock,
  esi_client: WandererKills.Ingest.ESI.Client.Mock,

  # Test-specific configurations (legacy)
  start_ets_supervisor: false,

  # Test cache names (legacy)
  killmails_cache_name: :wanderer_test_killmails_cache,
  system_cache_name: :wanderer_test_system_cache,
  esi_cache_name: :wanderer_test_esi_cache

# Configure Cachex for tests
config :cachex, :default_ttl, :timer.minutes(1)

# Configure Mox - use private mode for better test isolation
# Tests can still use Mox.set_mox_global() if needed
# config :mox, global: true

# Logger configuration for tests - set to debug to allow testing of log output
# Note: runtime.exs may override this, so we'll handle it differently
config :logger, :default_handler, level: :debug
