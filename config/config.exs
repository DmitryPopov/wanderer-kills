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
    client: WandererKills.Ingest.Http.Client,
    request_timeout_ms: 10_000,
    default_timeout_ms: 10_000,
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

  # Rate limiter configuration
  rate_limiter: [
    # Increased from 30 to 100
    zkb_capacity: 100,
    # Increased from 30 to 50
    zkb_refill_rate: 50,
    esi_capacity: 100,
    esi_refill_rate: 100
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
    retry: [
      max_retries: 5,
      base_delay: 500
    ]
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
    # 1 hour cleanup interval
    gc_interval_ms: 3_600_000,
    max_events_per_system: 10_000
  ],

  # Monitoring and telemetry configuration
  monitoring: [
    # 5 minutes
    status_interval_ms: 300_000,
    health_check_interval_ms: 60_000
  ],
  telemetry: [
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

  # Service startup configuration
  services: [
    start_preloader: true,
    start_redisq: true
  ],

  # Ship types configuration
  ship_types: [
    # Valid ship group IDs for EVE Online ships
    valid_group_ids: [
      25,
      26,
      27,
      28,
      29,
      30,
      31,
      237,
      324,
      358,
      380,
      381,
      419,
      420,
      463,
      485,
      513,
      540,
      541,
      543,
      547,
      659,
      830,
      831,
      832,
      833,
      834,
      883,
      893,
      894,
      898,
      900,
      902,
      906,
      941,
      963,
      1022,
      1201,
      1202,
      1283,
      1305,
      1527,
      1534,
      1538,
      1972,
      2001
    ],
    # Validation thresholds
    validation: [
      min_validation_rate: 0.5,
      min_record_count_for_rate_check: 10
    ]
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
  ],

  # Feature flags for gradual rollout
  features: [
    # Enable smart rate limiting
    smart_rate_limiting: false,
    # Enable request coalescing
    request_coalescing: false
  ],

  # Smart rate limiter configuration
  smart_rate_limiter: [
    # Token bucket configuration
    max_tokens: 150,
    # Increased from 100
    refill_rate: 75,
    # Tokens per second
    refill_interval_ms: 1000,
    # How often to refill

    # Circuit breaker
    circuit_failure_threshold: 10,
    # Failures before opening circuit
    circuit_timeout_ms: 60_000,
    # How long circuit stays open

    # Queue management
    max_queue_size: 5000,
    # Max queued requests
    queue_timeout_ms: 300_000
    # 5 minutes max queue time
  ],

  # Request coalescing configuration
  request_coalescer: [
    # Max time to wait for coalesced request
    request_timeout_ms: 30_000
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

# Import environment specific config
import_config "#{config_env()}.exs"
