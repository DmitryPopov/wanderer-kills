import Config

# Register MIME type for Server-Sent Events
config :mime, :types, %{
  "text/event-stream" => ["sse"]
}

# Main application configuration with grouped settings
config :wanderer_kills,
  # Cache configuration
  cache: [
    killmails_ttl: 3600,
    system_ttl: 1800,
    esi_ttl: 3600,
    esi_killmail_ttl: 86_400,
    system_recent_fetch_threshold: 5
  ],

  # ESI (EVE Swagger Interface) configuration
  esi: [
    base_url: "https://esi.evetech.net/latest",
    request_timeout_ms: 30_000,
    batch_concurrency: 10
  ],

  # HTTP client configuration
  http: [
    client: WandererKills.Http.Client,
    request_timeout_ms: 10_000,
    default_timeout_ms: 10_000,
    redisq_conn_max_idle_time_ms: 90_000,
    retry: [
      max_retries: 3,
      base_delay: 1000,
      max_delay: 30_000
    ]
  ],

  # ZKillboard configuration
  zkb: [
    base_url: "https://zkillboard.com/api",
    request_timeout_ms: 15_000,
    batch_concurrency: 5
  ],

  # Unified smart rate limiter configuration
  smart_rate_limiter: [
    # Mode: :simple (backward compatible) or :advanced (with queuing & circuit breaker)
    mode: :simple,

    # Simple mode configuration (backward compatible with old RateLimiter)
    zkb_capacity: 300,
    zkb_refill_rate: 200,
    esi_capacity: 500,
    esi_refill_rate: 3000,

    # Advanced mode configuration (only used when mode: :advanced)
    max_tokens: 150,
    refill_rate: 75,
    refill_interval_ms: 1000,
    circuit_failure_threshold: 10,
    circuit_timeout_ms: 30_000,
    queue_timeout_ms: 60_000,
    max_queue_size: 5000
  ],

  # RedisQ stream configuration
  redisq: [
    base_url: "https://zkillredisq.stream/listen.php",
    fast_interval_ms: 1_000,
    idle_interval_ms: 5_000,
    initial_backoff_ms: 1_000,
    max_backoff_ms: 30_000,
    backoff_factor: 2,
    task_timeout_ms: 10_000,
    request_timeout_ms: 45_000,
    retry: [
      max_retries: 5,
      base_delay: 500
    ]
  ],

  # Circuit breaker monitor configuration
  circuit_breaker_monitor: [
    # Check every minute
    check_interval_ms: 60_000,
    # Alert after 10 minutes
    alert_threshold_ms: 600_000
  ],

  # Parser configuration
  parser: [
    cutoff_seconds: 3_600,
    summary_interval_ms: 60_000
  ],

  # Enricher configuration
  enricher: [
    max_concurrency: 10,
    task_timeout_ms: 30_000,
    min_attackers_for_parallel: 3
  ],

  # Batch processing configuration
  batch: [
    concurrency_size: 100,
    default_concurrency: 5
  ],

  # Storage configuration
  storage: [
    enable_event_streaming: true,
    # 15 minutes cleanup interval (reduced from 1 hour)
    gc_interval_ms: 900_000,
    max_events_per_system: 10_000,
    # Memory monitor configuration
    memory_check_interval_ms: 30_000,
    memory_threshold_mb: 1000,
    emergency_threshold_mb: 1500,
    emergency_killmail_threshold: 50_000,
    emergency_removal_percentage: 25
  ],

  # Unified observability configuration (monitoring and telemetry)
  observability: [
    # Status monitoring intervals
    # 5 minutes
    status_interval_ms: 300_000,
    # 1 minute
    health_check_interval_ms: 60_000,

    # Telemetry configuration
    enabled_metrics: [:cache, :api, :circuit, :event],
    sampling_rate: 1.0,
    # 7 days in seconds
    retention_period: 604_800
  ],

  # WebSocket configuration
  websocket: [
    degraded_threshold: 1000
  ],

  # Dashboard configuration
  dashboard: [
    ets_tables: [
      {:killmails, "🗂️", "Killmails"},
      {:system_killmails, "🌌", "System Index"},
      {:system_kill_counts, "📊", "Kill Counts"},
      {:system_fetch_timestamps, "⏰", "Fetch Times"},
      {:killmail_events, "📝", "Events"},
      {:client_offsets, "🔖", "Client Offsets"},
      {:counters, "🔢", "Counters"}
    ]
  ],

  # SSE configuration
  sse: [
    max_connections: 100,
    max_connections_per_ip: 10,
    heartbeat_interval: 30_000,
    connection_timeout: 300_000
  ],

  # Preloader configuration
  preloader: [
    system_historical_limit: 1000
  ],

  # Historical streaming configuration
  historical_streaming: [
    enabled: false,
    start_date: "20240101",
    daily_limit: 5000,
    batch_size: 50,
    batch_interval_ms: 10_000,
    max_retries: 3,
    retry_delay_ms: 5_000
  ],

  # Feature flags configuration
  features: [
    # Smart rate limiting (enables advanced features)
    smart_rate_limiting: true,
    # Request coalescing (requires smart_rate_limiting)
    request_coalescing: true
  ],

  # Service startup configuration
  services: [
    start_preloader: true,
    start_redisq: true
  ],

  # Ship types configuration - data loaded from priv/data/ship_group_ids.json
  ship_types: [
    # Validation thresholds (flattened from nested validation key)
    min_validation_rate: 0.5,
    min_record_count_for_rate_check: 10,

    # Download configuration
    auto_update: true,
    max_age_days: 30
  ],

  # WebSocket subscription validation limits
  validation: [
    # System subscription limits
    # Increased from 50 to 10,000
    max_subscribed_systems: 10_000,
    max_system_id: 50_000_000,

    # Character subscription limits
    # Increased from 1,000 to 50,000
    max_subscribed_characters: 50_000,
    # EVE character IDs can be up to ~3B
    max_character_id: 3_000_000_000
  ]

# Configure the Phoenix endpoint
config :wanderer_kills, WandererKillsWeb.Endpoint,
  http: [port: 4004, ip: {0, 0, 0, 0}],
  server: true,
  pubsub_server: WandererKills.PubSub,
  render_errors: [
    formats: [json: WandererKillsWeb.ErrorJSON],
    layout: false
  ]

# Phoenix PubSub configuration
config :wanderer_kills, WandererKills.PubSub, adapter: Phoenix.PubSub.PG

# Cachex default configuration
config :cachex, :default_ttl, :timer.hours(24)

# Configure the logger
config :logger,
  level: :info,
  format: "$time $metadata[$level] $message\n",
  metadata: :all,
  backends: [:console]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: :all

# Configure sse_phoenix_pubsub library
config :sse_phoenix_pubsub,
  # 10 seconds instead of default 20
  keep_alive: 10_000,
  retry: 2_000

# Import environment specific config
import_config "#{config_env()}.exs"
