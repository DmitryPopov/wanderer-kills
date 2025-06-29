# WandererKills

[![CI/CD](https://github.com/guarzo/wanderer-kills/actions/workflows/ci.yml/badge.svg)](https://github.com/guarzo/wanderer-kills/actions/workflows/ci.yml)
[![Tests](https://img.shields.io/github/actions/workflow/status/guarzo/wanderer-kills/ci.yml?branch=main&label=tests)](https://github.com/guarzo/wanderer-kills/actions/workflows/ci.yml)
[![Credo](https://img.shields.io/github/actions/workflow/status/guarzo/wanderer-kills/ci.yml?branch=main&label=credo)](https://github.com/guarzo/wanderer-kills/actions/workflows/ci.yml)
[![Dialyzer](https://img.shields.io/github/actions/workflow/status/guarzo/wanderer-kills/ci.yml?branch=main&label=dialyzer)](https://github.com/guarzo/wanderer-kills/actions/workflows/ci.yml)
[![Elixir](https://img.shields.io/badge/elixir-1.17%2B-purple.svg)](https://elixir-lang.org/)
[![Phoenix Framework](https://img.shields.io/badge/phoenix-1.7-orange.svg)](https://www.phoenixframework.org/)

A high-performance, real-time EVE Online killmail data service built with Elixir/Phoenix. This service provides REST API, WebSocket, and Server-Sent Events (SSE) interfaces for accessing killmail data from zKillboard.

## Features

- **Real-time Data** - Continuous killmail stream from zKillboard RedisQ
- **Multiple Integration Methods** - REST API, WebSocket channels, Server-Sent Events (SSE), and Phoenix PubSub
- **Character-Based Subscriptions** - Subscribe to killmails by character IDs (victims or attackers)
- **System-Based Subscriptions** - Traditional solar system ID filtering
- **Flexible Filtering** - Combined system and character filtering with OR logic
- **Historical Data Preloading** - Fetch up to 90 days of character or system killmails via enhanced SSE endpoint
- **Efficient Caching** - Multi-tiered caching with custom ETS-based cache for optimal performance
- **ESI Enrichment** - Automatic enrichment with character, corporation, and ship names
- **Batch Processing** - Efficient bulk operations for multiple systems and characters
- **Event Streaming** - Optional event-driven architecture with offset tracking
- **Comprehensive Monitoring** - 5-minute status reports with system-wide metrics

## Quick Start

### Using Docker

```bash
# Run the service
docker run -p 4004:4004 guarzo/wanderer-kills

# With environment variables
docker run -p 4004:4004 \
  -e PORT=4004 \
  -e MIX_ENV=prod \
  guarzo/wanderer-kills
```

### Using Docker Compose

```bash
# Start the service
docker-compose up

# Run in background
docker-compose up -d
```

### Development Setup

1. **Prerequisites**
   - Elixir 1.17+
   - OTP 26.0+

2. **Clone and Setup**

   ```bash
   git clone https://github.com/wanderer-industries/wanderer-kills.git
   cd wanderer-kills
   
   # Install dependencies
   mix deps.get
   mix compile
   
   # Optional: Copy environment template for customization
   cp env.example .env
   ```

3. **Start the Application**

   ```bash
   # Start the application
   mix phx.server
   ```

The service will be available at `http://localhost:4004`

## Configuration

### Environment Variables

WandererKills can be configured using the following environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `PORT` | HTTP port to listen on | `4004` |
| `HOST` | Hostname for production URL | `localhost` |
| `SCHEME` | URL scheme (http/https) | `https` (prod), `http` (dev) |
| `URL_PORT` | Port for production URL | `443` (prod), matches `PORT` (dev) |
| `ORIGIN_HOST` | Domain for CORS/WebSocket origin checking | none (allows all) |
| `MIX_ENV` | Elixir environment (dev/test/prod) | `prod` |
| `KILLMAIL_RETENTION_DAYS` | Number of days to retain killmail data | `2` |
| `MEMORY_THRESHOLD_MB` | Memory usage threshold (MB) before warning | `1000` |
| `EMERGENCY_MEMORY_THRESHOLD_MB` | Memory usage threshold (MB) for emergency cleanup | `1500` |

#### Example Usage

```bash
# Docker production deployment
docker run -p 4004:4004 \
  -e HOST=yourdomain.com \
  -e SCHEME=https \
  -e URL_PORT=443 \
  -e PORT=4004 \
  -e ORIGIN_HOST=https://yourdomain.com \
  -e MIX_ENV=prod \
  -e KILLMAIL_RETENTION_DAYS=7 \
  -e MEMORY_THRESHOLD_MB=2000 \
  -e EMERGENCY_MEMORY_THRESHOLD_MB=3000 \
  guarzo/wanderer-kills

# Local development
export HOST=localhost
export SCHEME=http
export URL_PORT=4004
export PORT=4004
export KILLMAIL_RETENTION_DAYS=7
export MEMORY_THRESHOLD_MB=2000
mix phx.server
```

### Data Retention

The `KILLMAIL_RETENTION_DAYS` variable controls how long killmail data is stored before automatic cleanup. Setting this to a higher value will use more memory but allow for longer historical data access.

### Memory Management

The memory threshold variables control when the system triggers cleanup operations:
- `MEMORY_THRESHOLD_MB`: When exceeded, the system logs warnings about memory usage
- `EMERGENCY_MEMORY_THRESHOLD_MB`: When exceeded, the system performs emergency cleanup of old data

## API Overview

### REST Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/v1/kills/system/{system_id}` | Get kills for a system |
| POST | `/api/v1/kills/systems` | Bulk fetch multiple systems |
| GET | `/api/v1/kills/cached/{system_id}` | Get cached kills only |
| GET | `/api/v1/killmail/{killmail_id}` | Get specific killmail |
| GET | `/api/v1/kills/count/{system_id}` | Get kill count |
| GET | `/api/v1/kills/stream` | Server-Sent Events stream |
| POST | `/api/v1/subscriptions` | Create webhook subscription |
| GET | `/api/v1/subscriptions` | List webhook subscriptions |
| DELETE | `/api/v1/subscriptions/{subscriber_id}` | Delete webhook subscription |
| GET | `/health` | Health check |
| GET | `/status` | Service status |
| GET | `/websocket` | WebSocket connection info |
| GET | `/api/openapi` | OpenAPI specification |

### WebSocket Connection

For complete WebSocket examples in multiple languages, see the [examples directory](examples/).

```javascript
// Import Phoenix Socket library
import { Socket } from 'phoenix';

// Connect to WebSocket
const socket = new Socket('ws://localhost:4004/socket', {
  params: { client_identifier: 'my_client' }
});

socket.connect();

// Join the killmail lobby channel with initial systems
const channel = socket.channel('killmails:lobby', {
  systems: [30000142, 30000144]
});

channel.join()
  .receive('ok', resp => { console.log('Joined successfully', resp) })
  .receive('error', resp => { console.log('Unable to join', resp) });

// Listen for new killmails
channel.on('killmail_update', payload => {
  console.log('New killmails:', payload);
});

// Subscribe to additional systems dynamically
channel.push('subscribe_systems', { systems: [30002187] })
  .receive('ok', resp => { console.log('Subscribed to additional systems', resp) });
```

### Character-Based Subscriptions

WandererKills supports character-based subscriptions, allowing you to receive killmails where specific characters appear as either victims or attackers.

```javascript
// Subscribe to characters (will receive killmails where these characters are involved)
const characters = [95465499, 90379338];  // Character IDs
channel.push('subscribe_characters', { character_ids: characters })
  .receive('ok', resp => { console.log('Subscribed to characters', resp) });

// Mixed subscription (systems OR characters) - can be done on channel join
const channel2 = socket.channel('killmails:lobby', { 
  systems: [30000142], 
  character_ids: [95465499, 90379338] 
});

// Unsubscribe from specific characters
channel.push('unsubscribe_characters', { character_ids: [95465499] })
  .receive('ok', resp => { console.log('Unsubscribed from character', resp) });
```

**Character Subscription Features:**
- Track specific players as victims or attackers
- Combine with system subscriptions using OR logic
- Support for up to 1000 characters per subscription
- Real-time performance monitoring and optimization

## Subscription Types

WandererKills offers three distinct subscription mechanisms for receiving killmail updates:

### WebSocket Subscriptions
**Real-time bidirectional communication**

WebSocket subscriptions provide persistent, interactive connections for real-time killmail updates.

```javascript
// Connect and subscribe via WebSocket
const socket = new Socket('ws://localhost:4004/socket', {
  params: { client_identifier: 'my-app' }
});

const channel = socket.channel('killmails:lobby', {
  systems: [30000142, 30002187],
  characters: [95465499, 90379338],
  preload: { enabled: true, since_hours: 24 }
});

// Dynamic subscription management
channel.push('subscribe_systems', { systems: [30000144] });
channel.push('unsubscribe_characters', { characters: [95465499] });
```

### Server-Sent Events (SSE) Subscriptions
**Simple unidirectional streaming**

SSE provides a lightweight, HTTP-based streaming protocol perfect for server-side applications that need real-time updates without the complexity of WebSockets.

#### Standard SSE Endpoint
```bash
# Connect to SSE stream with filters
curl -N -H "Accept: text/event-stream" \
  "http://localhost:4004/api/v1/kills/stream?system_ids=30000142,30000144&min_value=100000000"
```

#### Enhanced SSE Endpoint (NEW)
The enhanced endpoint provides historical data preloading for characters or systems:

```bash
# Connect with 90 days of historical data for specific characters
curl -N "http://localhost:4004/api/v1/kills/stream/enhanced?character_ids=123456789,987654321&preload_days=90"

# Connect with 30 days of historical data for specific systems
curl -N "http://localhost:4004/api/v1/kills/stream/enhanced?system_ids=30000142,30000143&preload_days=30"
```

**JavaScript Example (Standard):**
```javascript
const eventSource = new EventSource('/api/v1/kills/stream?system_ids=30000142&character_ids=95465499');

eventSource.addEventListener('killmail', (event) => {
  const killmail = JSON.parse(event.data);
  console.log('New killmail:', killmail);
});

eventSource.addEventListener('error', (event) => {
  if (event.readyState === EventSource.CLOSED) {
    console.log('Connection closed');
  }
});
```

**JavaScript Example (Enhanced with Character Preloading):**
```javascript
const eventSource = new EventSource('/api/v1/kills/stream/enhanced?character_ids=12345&preload_days=90');

let isRealtime = false;

eventSource.addEventListener('batch', (e) => {
  const batch = JSON.parse(e.data);
  console.log(`Historical batch ${batch.batch_number}/${batch.total_batches}: ${batch.count} kills`);
});

eventSource.addEventListener('transition', (e) => {
  console.log('Switched to real-time mode');
  isRealtime = true;
});

eventSource.addEventListener('killmail', (e) => {
  const killmail = JSON.parse(e.data);
  console.log(`${isRealtime ? 'Real-time' : 'Historical'} kill:`, killmail.killmail_id);
});
```

**JavaScript Example (Enhanced with System Preloading):**
```javascript
const eventSource = new EventSource('/api/v1/kills/stream/enhanced?system_ids=30000142,30000143&preload_days=30');

let totalHistorical = 0;

eventSource.addEventListener('batch', (e) => {
  const batch = JSON.parse(e.data);
  totalHistorical += batch.count;
  console.log(`System batch ${batch.batch_number}/${batch.total_batches}: ${batch.count} kills`);
});

eventSource.addEventListener('transition', (e) => {
  const data = JSON.parse(e.data);
  console.log(`Historical complete: ${data.total_historical} kills from last 30 days`);
});

eventSource.addEventListener('killmail', (e) => {
  const killmail = JSON.parse(e.data);
  console.log('Real-time system kill:', killmail.killmail_id, 'in system', killmail.solar_system_id);
});
```

**Key Features:**
- Simple HTTP-based protocol
- Automatic reconnection built into browsers
- Works through proxies and firewalls
- No special libraries required for most languages
- Efficient for one-way server-to-client communication
- **NEW: Historical data preloading (up to 90 days)**
- **NEW: Server-side filtering for bandwidth efficiency**
- **NEW: Clear transition signals between historical and real-time modes**
- **NEW: Configurable connection limits (max_connections, max_connections_per_ip)**

### Webhook Subscriptions
**HTTP callback-based notifications**

Webhook subscriptions send killmail updates to your HTTP endpoints via POST requests.

```bash
# Create webhook subscription
curl -X POST http://localhost:4004/api/v1/subscriptions \
  -H "Content-Type: application/json" \
  -d '{
    "subscriber_id": "my-service",
    "system_ids": [30000142, 30002187],
    "character_ids": [95465499, 90379338],
    "callback_url": "https://myapp.com/killmail-webhook"
  }'

# List active subscriptions
curl http://localhost:4004/api/v1/subscriptions

# Delete subscription
curl -X DELETE http://localhost:4004/api/v1/subscriptions/my-service
```

### Webhook Payload Format

Webhook notifications are sent as JSON POST requests:

```json
{
  "type": "killmail_update",
  "system_id": 30000142,
  "timestamp": "2024-01-01T12:00:00Z",
  "kills": [
    {
      "killmail_id": 123456,
      "solar_system_id": 30000142,
      "killmail_time": "2024-01-01T12:00:00Z",
      "victim": { "character_id": 95465499, "ship_type_id": 587 },
      "attackers": [...]
    }
  ]
}
```

### Comparison: WebSocket vs SSE vs Webhook

| Feature | WebSocket | SSE | Webhook |
|---------|-----------|-----|---------|
| **Connection** | Persistent, bidirectional | Persistent, unidirectional | Stateless HTTP requests |
| **Latency** | Very low | Very low | Higher (HTTP overhead) |
| **Reliability** | Client handles reconnects | Auto-reconnect built-in | Retryable with HTTP client |
| **Management** | Dynamic (live changes) | Query params only | Static (set at creation) |
| **Filtering** | Interactive updates | Fixed at connection | Fixed at subscription time |
| **Preloading** | Full support with batching | Batch on connection | Basic preload on creation |
| **Complexity** | Requires client library | Native browser support | Simple HTTP POST |
| **Use Case** | Interactive apps, gaming | Live feeds, dashboards | Server integrations |
| **Registration** | WebSocket channel join | HTTP GET with params | REST API endpoint |

**Choose WebSocket for:**
- Interactive applications requiring bidirectional communication
- Applications that need dynamic subscription management
- Gaming or chat-like applications

**Choose SSE for:**
- Simple real-time dashboards and monitoring
- Browser-based applications without complex client libraries
- One-way server-to-client streaming

**Choose Webhooks for:**
- Server-to-server integrations
- Reliable delivery to external systems
- Applications that can't maintain persistent connections

### Example API Call

```bash
# Get kills for Jita in the last 24 hours
curl "http://localhost:4004/api/v1/kills/system/30000142?since_hours=24&limit=50"
```

## Architecture

```
┌─────────────────┐     ┌──────────────┐     ┌─────────────┐
│   zKillboard   │────▶│    RedisQ    │────▶│  Processor  │
│     RedisQ     │     │   Consumer   │     │   Pipeline  │
└─────────────────┘     └──────────────┘     └─────────────┘
                                                     │
                              ┌──────────────────────┴───────────────┐
                              │                                      │
                              ▼                                      ▼
                    ┌─────────────────┐                    ┌─────────────────┐
                    │   ESI Enricher  │                    │  Storage Layer  │
                    │ (Names & Data)  │                    │  (ETS Tables)   │
                    └─────────────────┘                    └─────────────────┘
                              │                                      │
                              └──────────────┬───────────────────────┘
                                             ▼
                              ┌──────────────────────────┐
                              │    Distribution Layer    │
                              ├──────────────────────────┤
                              │ • REST API               │
                              │ • WebSocket Channels     │
                              │ • Server-Sent Events     │
                              │ • Phoenix PubSub         │
                              │ • Webhook Subscriptions  │
                              └──────────────────────────┘
```

### Key Components

- **RedisQ Consumer** - Continuously polls zKillboard for new killmails
- **Unified Processor** - Handles both full and partial killmail formats
- **ESI Enricher** - Adds character, corporation, and ship names
- **Storage Layer** - ETS-based storage with optional event streaming
- **Cache Layer** - Multi-tiered caching with configurable TTLs
- **Distribution Layer** - Multiple integration methods for consumers

## Configuration

### Environment Variables

See `env.example` for all available environment variables. The primary ones are:

```bash
# Port configuration
PORT=4004

# Production URL configuration
HOST=yourdomain.com
SCHEME=https
URL_PORT=443

# CORS/WebSocket origin checking (production only)
ORIGIN_HOST=https://yourdomain.com

# Application environment
MIX_ENV=prod
```

Most configuration is handled through compile-time config files rather than environment variables for better performance.

### Application Configuration

Configuration is organized by functional area in `config/config.exs`:

```elixir
# config/config.exs
config :wanderer_kills,
  # Cache TTLs (in seconds)
  cache: [
    killmails_ttl: 3600,
    system_ttl: 1800,
    esi_ttl: 3600,
    esi_killmail_ttl: 86_400
  ],
  
  # ESI configuration
  esi: [
    base_url: "https://esi.evetech.net/latest",
    request_timeout_ms: 30_000,
    batch_concurrency: 10
  ],
  
  # RedisQ stream configuration
  redisq: [
    base_url: "https://zkillredisq.stream/listen.php",
    fast_interval_ms: 1_000,
    idle_interval_ms: 5_000
  ],
  
  # Storage and event streaming
  storage: [
    enable_event_streaming: true,
    gc_interval_ms: 60_000,
    max_events_per_system: 10_000
  ],
  
  # SSE connection limits
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
  
  # Monitoring intervals
  monitoring: [
    status_interval_ms: 300_000,  # 5 minutes
    health_check_interval_ms: 60_000
  ]
```

## Monitoring

The service provides comprehensive monitoring with 5-minute status reports:

```text
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📊 WANDERER KILLS STATUS REPORT (5-minute summary)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🌐 WEBSOCKET ACTIVITY:
   Active Connections: 15
   Active Subscriptions: 12 (covering 87 systems)

📤 KILL DELIVERY:
   Total Kills Sent: 1234 (Realtime: 1150, Preload: 84)
   Delivery Rate: 4.1 kills/minute

🔄 REDISQ ACTIVITY:
   Kills Processed: 327
   Active Systems: 45

💾 CACHE PERFORMANCE:
   Hit Rate: 87.5%
   Cache Size: 2156 entries

📦 STORAGE METRICS:
   Total Killmails: 15234
   Unique Systems: 234
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Health Monitoring

- **Health Check**: `GET /health` - Basic service health
- **Status Endpoint**: `GET /status` - Detailed service metrics
- **Telemetry Events**: Integration with Prometheus/StatsD
- **Structured Logging**: Extensive metadata for debugging

## Development

### Running Tests

```bash
# Run all tests
mix test

# Generate HTML coverage report  
mix test.coverage

# Generate JSON coverage for CI
mix test.coverage.ci

# Run performance tests (normally excluded)
mix test --include perf

# Run specific test file
mix test test/wanderer_kills/ingest/killmails/unified_processor_test.exs
```

### Code Quality

This project maintains **excellent code quality**:
- ✅ **Credo**: 0 issues
- ✅ **Dialyzer**: 0 warnings
- ✅ **Tests**: 100% passing
- ✅ **Format**: Fully formatted

```bash
# Format code
mix format

# Run static analysis
mix credo

# Run type checking
mix dialyzer

# Run all checks
mix check
```

### Development Container

The project includes VS Code development container support:

1. Install [Docker](https://docs.docker.com/get-docker/) and [VS Code](https://code.visualstudio.com/)
2. Install the [Remote - Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) extension
3. Open the project in VS Code
4. Click "Reopen in Container" when prompted

The development container includes all required tools and dependencies.

## Data Management

### Ship Type Data

The service includes ship type data for enrichment:

```bash
# Ship type data is automatically loaded from CSV files on startup
# Data files are located in priv/data/ship_types/
# Validation ensures data integrity during loading
```

### Cache Management

The service uses an ETS-based caching system that is automatically managed. Caches are cleared and warmed on startup, with configurable TTLs for different data types.

## Documentation

Comprehensive documentation is available:

- [API & Integration Guide](docs/API_AND_INTEGRATION_GUIDE.md) - Complete API documentation and integration examples
- [Examples](examples/README.md) - WebSocket client examples in multiple languages
- [Architecture Overview](CLAUDE.md) - Detailed architecture documentation for developers
- [Environment Configuration](env.example) - Complete list of environment variables and settings
- [Docker Guide](DOCKER.md) - Docker deployment and development information

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Write tests for your changes
4. Ensure all tests pass (`mix test`)
5. Check code quality (`mix credo --strict`)
6. Commit your changes (`git commit -m 'Add support for amazing feature'`)
7. Push to the branch (`git push origin feature/amazing-feature`)
8. Open a Pull Request

### Development Guidelines

- Follow the [Elixir Style Guide](https://github.com/christopheradams/elixir_style_guide)
- Write comprehensive tests for new features
- Update documentation for API changes
- Use descriptive commit messages
- Keep PRs focused and atomic

## Deployment

### Docker Production Build

```bash
# Build production image
docker build -t wanderer-kills:latest .

# Run with environment variables
docker run -d \
  -p 4004:4004 \
  -e HOST=yourdomain.com \
  -e SCHEME=https \
  -e URL_PORT=443 \
  -e PORT=4004 \
  -e ORIGIN_HOST=https://yourdomain.com \
  -e MIX_ENV=prod \
  --name wanderer-kills \
  guarzo/wanderer-kills:latest
```

## Performance

The service is designed for high performance and has been thoroughly benchmarked for production readiness, with impressive sub-microsecond operations.

### Performance Benchmarks

WandererKills delivers exceptional performance with sub-microsecond operations:

- **System Operations**: 8.32 μs per lookup, 13.15 μs per bulk subscription
- **Character Operations**: 7.64 μs per lookup, 20.52 μs per batch lookup  
- **Memory Efficient**: 0.13 MB per index
- **Fast Health Checks**: Under 4 ms

> 📊 **[View Detailed Performance Benchmarks](docs/PERFORMANCE.md)**
> 
> Run benchmarks: `MIX_ENV=test mix test test/performance --include perf`

### Key Performance Features

- **Concurrent Processing** - Leverages Elixir's actor model
- **Efficient Caching** - Multi-tiered cache with smart TTLs
- **Batch Operations** - Bulk enrichment and processing
- **Connection Pooling** - Optimized HTTP client connections
- **ETS Storage** - In-memory storage for fast access

The service is optimized for:

- High-throughput kill processing
- Efficient batch operations
- Low-latency WebSocket updates
- Minimal API response times with caching

## License

This project is licensed under the [MIT License](LICENSE).

## Acknowledgments

- [zKillboard](https://zkillboard.com/) for providing the killmail data
- [EVE Online](https://www.eveonline.com/) and CCP Games
- The Elixir/Phoenix community

## Support

- **Issues**: [GitHub Issues](https://github.com/wanderer-industries/wanderer-kills/issues)
- **Discussions**: [GitHub Discussions](https://github.com/wanderer-industries/wanderer-kills/discussions)
- **Email**: [wanderer-kills@proton.me](mailto:wanderer-kills@proton.me)

---

Built with ❤️ by [Wanderer Industries](https://github.com/wanderer-industries)
