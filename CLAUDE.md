# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

WandererKills is a real-time EVE Online killmail data service built with Elixir/Phoenix that:

- Fetches killmail data from zKillboard API  
- Provides caching and enrichment of killmail data with ESI (EVE Swagger Interface)
- Offers REST API endpoints, WebSocket support, and Server-Sent Events for real-time updates
- Uses ETS-based storage with event streaming capabilities
- Supports character-based and system-based subscriptions with high-performance indexing
- Implements boundary-driven architecture with strict module separation

## Essential Commands

### Development
```bash
mix deps.get              # Install dependencies
mix compile              # Compile the project
mix phx.server           # Start Phoenix server (port 4004)
iex -S mix phx.server    # Start with interactive shell
```

### Testing
```bash
mix test                 # Run all tests
mix test path/to/test.exs  # Run specific test file
mix test path/to/test.exs:42  # Run specific test at line 42
mix test.coverage        # Generate HTML coverage report
mix test.coverage.ci     # Generate JSON coverage for CI
```

### Code Quality
```bash
mix format               # Format code
mix credo              # Run static analysis
mix dialyzer           # Run type checking
mix check             # Run format check, credo, and dialyzer
```

### Docker Development
```bash
docker build -t wanderer-kills-dev -f Dockerfile.dev .
docker-compose up        # Start with Redis and all services
make dev                 # Alternative development setup
```

### Monitoring & Dashboard
```bash
# Access real-time dashboard at http://localhost:4004/dashboard
# Includes ETS statistics, WebSocket connections, and RedisQ metrics
```

## Architecture Overview

### Boundary-Driven Architecture

The project implements strict architectural boundaries using the `boundary` library:

- **Core** (`/lib/wanderer_kills/core/`) - Foundational infrastructure and shared utilities
- **Domain** (`/lib/wanderer_kills/domain/`) - Pure domain models and business logic
- **Ingest** (`/lib/wanderer_kills/ingest/`) - External API processing and rate limiting
- **Subs** (`/lib/wanderer_kills/subs/`) - Subscription management and indexing
- **Web** (`/lib/wanderer_kills_web/`) - HTTP/WebSocket/SSE interfaces

### Core Components

1. **OTP Application** (`WandererKills.App.Application`)
   - Supervises all child processes
   - Manages Cachex, Phoenix endpoint, and data fetchers
   - Handles telemetry and monitoring

2. **Data Flow Pipeline**
   - `RedisQ` - Real-time killmail stream consumer from zKillboard
   - `ZkbClient` - Historical data fetcher with smart rate limiting
   - `UnifiedProcessor` - Processes both full and partial killmails
   - `Storage.KillmailStore` - ETS-based storage with event streaming
   - `ESI.Client` - Enriches data with EVE API information

3. **Advanced Rate Limiting**
   - `SmartRateLimiter` - Intelligent rate limiting with circuit breaker
   - `RequestCoalescer` - Request deduplication and coalescing
   - Feature flags for gradual rollout of optimization features

4. **Caching Layer**
   - Single Cachex instance (`:wanderer_cache`) with namespace support
   - TTL configuration: killmails (5min), systems (1hr), ESI data (24hr)
   - Ship type data preloaded from CSV files

5. **API & Real-time**
   - REST endpoints via Phoenix Router with OpenAPI 3.0 documentation
   - WebSocket channels for live subscriptions (10,000+ concurrent clients)
   - Server-Sent Events (SSE) for streaming with filter support
   - Standardized error responses using `Support.Error`

6. **Enhanced Observability**
   - Real-time dashboard with system metrics and visualization
   - Unified status reporting with batch telemetry
   - Character and system subscription health monitoring
   - API usage tracking and connection leak detection

### Module Organization

#### Core Infrastructure (`/core/`)
- `Core.SupervisedTask` - Supervised async tasks with telemetry
- `Core.Error` - Standardized error structures
- `Core.BatchProcessor` - Parallel batch processing with Flow
- `Core.Observability.*` - Comprehensive monitoring and health checks

#### Domain Models (`/domain/`)
- `Domain.Killmail` - Core killmail data structures
- `Domain.Character` - Character-related models
- `Domain.System` - Solar system models
- `Domain.ShipType` - Ship type definitions

#### Data Ingestion (`/ingest/`)
- `Ingest.UnifiedProcessor` - Main killmail processing logic
- `Ingest.Pipeline.*` - Processing pipeline stages (Parser, Validator, Enricher)
- `Ingest.SmartRateLimiter` - Advanced rate limiting with circuit breaker
- `Ingest.RequestCoalescer` - Request deduplication
- `Ingest.ZkbClient` - zKillboard API client
- `Ingest.RedisQ` - Real-time data stream consumer

#### Subscription Management (`/subs/`)
- `Subs.SubscriptionManager` - Core subscription orchestration
- `Subs.Subscriptions.CharacterIndex` - Character subscription indexing (50k+ characters)
- `Subs.Subscriptions.SystemIndex` - System subscription indexing (10k+ systems)
- `Subs.Broadcaster` - PubSub message broadcasting
- `Subs.WebhookNotifier` - HTTP webhook delivery
- `Subs.Preloader` - Historical data preloading

#### External Services
- `ESI.Client` - EVE Swagger Interface client with Req HTTP library
- `Storage.KillmailStore` - ETS-based storage with event streaming
- `Http.Client` - Centralized HTTP client with retry logic

#### Ship Types Management
- `ShipTypes.CSV` - Orchestrates CSV data loading
- `ShipTypes.Parser` - CSV parsing and extraction
- `ShipTypes.Validator` - Data validation rules
- `Subs.Cache` - Ship type caching operations

#### Server-Sent Events (`/sse/`)
- `SSE.FilterParser` - Query parameter parsing for SSE streams
- `SSE.Broadcaster` - SSE message broadcasting with Phoenix PubSub

#### Debug & Analysis (`/debug/`)
- `Debug.ConnectionAnalyzer` - WebSocket connection leak diagnostics
- `Debug.ConnectionCleanup` - Connection cleanup utilities

#### Web Interface (`/wanderer_kills_web/`)
- REST API controllers with OpenAPI 3.0 documentation
- WebSocket channels for real-time subscriptions
- SSE endpoints for streaming data
- Real-time dashboard for system monitoring

## Key Design Patterns

### Behaviours for Testability

All external service clients implement behaviours, allowing easy mocking in tests:
- `Http.ClientBehaviour` - HTTP client interface
- `ESI.ClientBehaviour` - ESI API interface  
- `Core.Observability.HealthCheckBehaviour` - Health check interface
- `Subs.Subscriptions.IndexBehaviour` - Subscription index interface

### Supervised Async Work

All async operations use `Core.SupervisedTask`:
```elixir
Core.SupervisedTask.start_child(
  fn -> process_data() end,
  task_name: "process_data",
  metadata: %{data_id: id}
)
```

### Standardized Error Handling

All errors use `Core.Error` for consistency:
```elixir
{:error, Core.Error.http_error(:timeout, "Request timed out", true)}
{:error, Core.Error.validation_error(:invalid_format, "Invalid data")}
```

### High-Performance Indexing

Subscription indexes provide sub-microsecond lookups:
```elixir
# Character operations: ~7.64 μs per lookup
# System operations: ~8.32 μs per lookup
# Memory efficient: ~0.13 MB per index
```

### Event-Driven Architecture

- Phoenix PubSub for internal communication
- Storage events for data changes
- Telemetry events for monitoring

## Common Development Tasks

### Adding New API Endpoints

1. Define route in `router.ex`
2. Create controller action
3. Implement context function
4. Add tests for both layers

### Adding External Service Clients

1. Define behaviour in `client_behaviour.ex`
2. Implement client using `Http.Client`
3. Configure mock in test environment
4. Use dependency injection via config

### Processing Pipeline Extensions

1. Add new stage in `pipeline/` directory
2. Implement behaviour callbacks
3. Update `UnifiedProcessor` to include stage
4. Add comprehensive tests

### Health Check Extensions

1. Implement `HealthCheckBehaviour`
2. Add to health check aggregator
3. Define metrics and thresholds
4. Test failure scenarios

## Configuration Patterns

### Environment Configuration

- Base: `config/config.exs`
- Environment: `config/{dev,test,prod}.exs`
- Runtime: `config/runtime.exs`
- Access via: `WandererKills.Config`

### Feature Flags

- Event streaming: `:storage, :enable_event_streaming`
- RedisQ start: `:start_redisq`
- Monitoring intervals: `:monitoring, :status_interval_ms`
- Smart rate limiting: `:features, :smart_rate_limiting`
- Request coalescing: `:features, :request_coalescing`

### Enhanced Configuration Options

```elixir
# Subscription limits (significantly increased)
validation: [
  max_subscribed_systems: 10_000,     # Up from 50
  max_subscribed_characters: 50_000   # Up from 1,000
]

# SSE configuration
sse: [
  max_connections: 100,
  max_connections_per_ip: 10,
  heartbeat_interval: 30_000,
  connection_timeout: 300_000
]

# Smart rate limiter
smart_rate_limiter: [
  max_tokens: 150,
  refill_rate: 75,
  circuit_failure_threshold: 10,
  max_queue_size: 5000
]
```

## Best Practices

### Naming Conventions

- Use `killmail` consistently (not `kill`)
- `get_*` for cache/local operations
- `fetch_*` for external API calls
- `list_*` for collections
- `_async` suffix for async operations

### Cache Keys

- Killmails: `"killmail:{id}"`
- Systems: `"system:{id}"`  
- ESI data: `"esi:{type}:{id}"`
- Ship types: `"ship_types:{id}"`

### Testing Strategy

- Mock external services via behaviours using Mox
- Test public APIs, not implementation details
- Use factories and StreamData for property-based testing
- Comprehensive error case coverage with edge cases
- Parallel test execution for performance
- Integration tests for end-to-end scenarios

### Performance Considerations

- Batch operations when possible using Flow
- Use ETS for high-frequency reads (sub-microsecond lookups)
- Implement circuit breakers for external services
- Monitor memory usage of GenServers and ETS tables
- Use request coalescing to reduce duplicate API calls
- Leverage smart rate limiting to prevent API exhaustion

### Scalability Metrics

- **WebSocket Support:** 10,000+ concurrent clients
- **SSE Connections:** 1,000+ concurrent streams  
- **Processing Throughput:** 1,000+ kills/minute
- **Character Subscriptions:** Up to 50,000 characters
- **System Subscriptions:** Up to 10,000 systems
- **Sub-microsecond Operations:** Character (~7.64 μs) and System (~8.32 μs) lookups

# important-instruction-reminders
Do what has been asked; nothing more, nothing less.
NEVER create files unless they're absolutely necessary for achieving your goal.
ALWAYS prefer editing an existing file to creating a new one.
NEVER proactively create documentation files (*.md) or README files. Only create documentation files if explicitly requested by the User.