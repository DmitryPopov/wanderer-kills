# WandererKills API & Integration Guide

## Overview

WandererKills is a real-time EVE Online killmail data service that provides multiple integration patterns for consuming killmail data. The service fetches data from zKillboard's RedisQ stream and enriches it with ESI (EVE Swagger Interface) data.

**Service Information:**
- **Default Port**: 4004
- **Base URL**: `http://localhost:4004/api/v1`
- **API Version**: v1
- **Authentication**: None required (current version)

**Integration Options:**
- **REST API** - HTTP endpoints for fetching killmail data
- **WebSocket** - Real-time kill notifications via Phoenix channels  
- **Server-Sent Events (SSE)** - Simple HTTP-based real-time streaming
- **Webhook Subscriptions** - HTTP callbacks for killmail updates
- **PubSub** - Direct message broadcasting for Elixir applications
- **Client Library** - Elixir behaviour for type-safe integration

---

## REST API Integration

### Base URL
```
http://localhost:4004/api/v1
```

### Core Endpoints

| Method | Endpoint                        | Description                 |
| ------ | ------------------------------- | --------------------------- |
| GET    | `/kills/system/{system_id}`     | Get kills for a system      |
| POST   | `/kills/systems`                | Bulk fetch multiple systems |
| GET    | `/kills/cached/{system_id}`     | Get cached kills only       |
| GET    | `/killmail/{killmail_id}`       | Get specific killmail       |
| GET    | `/kills/count/{system_id}`      | Get kill count for system   |
| GET    | `/kills/stream`                 | Server-Sent Events stream   |
| POST   | `/subscriptions`                | Create webhook subscription |
| GET    | `/subscriptions`                | List all subscriptions      |
| GET    | `/subscriptions/stats`          | Get subscription statistics |
| DELETE | `/subscriptions/{subscriber_id}`| Delete subscription         |

### Infrastructure Endpoints (No versioning)

| Method | Endpoint            | Description                 |
| ------ | ------------------- | --------------------------- |
| GET    | `/ping`             | Simple health check         |
| GET    | `/health`           | Detailed health status      |
| GET    | `/status`           | Service status              |
| GET    | `/metrics`          | Service metrics             |
| GET    | `/websocket`        | WebSocket connection info   |
| GET    | `/websocket/status` | WebSocket server statistics |
| GET    | `/api/openapi`      | OpenAPI specification (JSON)|

### System Kills

#### Single System
```http
GET /api/v1/kills/system/{system_id}?since_hours={hours}&limit={limit}
```

**Parameters:**
- `system_id` (required) - EVE Online solar system ID
- `since_hours` (optional) - Hours to look back for kills (default: "24")
- `limit` (optional) - Maximum kills to return (default: 50, max: 1000)

**Example:**
```bash
curl "http://localhost:4004/api/v1/kills/system/30000142?since_hours=24&limit=50"
```

**Response:**
```json
{
  "data": {
    "kills": [
      {
        "killmail_id": 123456789,
        "kill_time": "2024-01-15T14:30:00Z",
        "system_id": 30000142,
        "victim": {
          "character_id": 987654321,
          "character_name": "Victim Name",
          "corporation_id": 123456789,
          "corporation_name": "Victim Corp",
          "ship_type_id": 671,
          "ship_name": "Raven",
          "damage_taken": 2847
        },
        "attackers": [
          {
            "character_id": 111222333,
            "character_name": "Attacker Name", 
            "corporation_id": 444555666,
            "corporation_name": "Attacker Corp",
            "ship_type_id": 17918,
            "ship_name": "Rattlesnake",
            "damage_done": 2847,
            "final_blow": true
          }
        ],
        "zkb": {
          "location_id": 50000001,
          "hash": "abc123def456",
          "fitted_value": 150000000.0,
          "total_value": 152000000.0,
          "points": 15,
          "npc": false,
          "solo": true,
          "awox": false
        }
      }
    ],
    "timestamp": "2024-01-15T15:00:00Z",
    "cached": false
  },
  "timestamp": "2024-01-15T15:00:00Z"
}
```

#### Multiple Systems (Bulk)
```http
POST /api/v1/kills/systems
Content-Type: application/json

{
  "system_ids": [30000142, 30000144, 30000145],
  "since_hours": 24,
  "limit": 50
}
```

**Parameters:**
- `system_ids` (required) - Array of EVE Online solar system IDs
- `since_hours` (optional) - Hours to look back for kills (default: 24)
- `limit` (optional) - Maximum kills per system (default: 50, max: 1000)

**Response:**
```json
{
  "data": {
    "systems_kills": {
      "30000142": [...],
      "30000144": [...],
      "30000145": [...]
    },
    "timestamp": "2024-01-15T15:00:00Z"
  },
  "timestamp": "2024-01-15T15:00:00Z"
}
```

### Cached Data
```http
GET /api/v1/kills/cached/{system_id}
```
Returns only cached kills without triggering a fresh fetch.

**Response:**
```json
{
  "data": {
    "kills": [...],
    "timestamp": "2024-01-15T15:00:00Z",
    "cached": true
  },
  "timestamp": "2024-01-15T15:00:00Z"
}
```

### Specific Killmail
```http
GET /api/v1/killmail/{killmail_id}
```

**Response:**
```json
{
  "data": {
    "killmail_id": 123456789,
    "kill_time": "2024-01-15T14:30:00Z",
    "system_id": 30000142,
    "victim": {...},
    "attackers": [...],
    "zkb": {...}
  },
  "timestamp": "2024-01-15T15:00:00Z"
}
```

### Kill Count
```http
GET /api/v1/kills/count/{system_id}
```

**Response:**
```json
{
  "data": {
    "system_id": 30000142,
    "count": 47,
    "timestamp": "2024-01-15T15:00:00Z"
  },
  "timestamp": "2024-01-15T15:00:00Z"
}
```

### Server-Sent Events (SSE) Stream

```http
GET /api/v1/kills/stream
```

Real-time streaming of killmail data using Server-Sent Events protocol. Perfect for server-side applications that need a simple, unidirectional stream of killmail updates. 

The SSE implementation uses the `sse_phoenix_pubsub` library to seamlessly integrate with Phoenix PubSub, ensuring consistent message delivery across all subscription types.

**Query Parameters:**
- `system_ids` - Comma-separated list of system IDs to filter (e.g., `30000142,30000144`)
- `character_ids` - Comma-separated list of character IDs to track as victim/attacker
- `min_value` - Minimum ISK value threshold for killmails

**Example Request:**
```bash
curl -N -H "Accept: text/event-stream" \
  "http://localhost:4004/api/v1/kills/stream?system_ids=30000142&min_value=100000000"
```

**Response Headers:**

```http
Content-Type: text/event-stream
Cache-Control: no-cache
Connection: keep-alive
```

**Event Types:**

1. **Connected Event** (sent immediately on connection):

```
event: connected
data: SSE stream connected
```

2. **Killmail Event** (new killmail data):

```
event: killmail
data: {"killmail_id": 123456789, "kill_time": "2024-01-15T14:30:00Z", "solar_system_id": 30000142, ...}
id: 123456789
```

3. **Batch Event** (historical data on connection):

```
event: batch
data: [{"killmail_id": 123456789, ...}, {"killmail_id": 123456790, ...}]
```

4. **Heartbeat Event** (every 30 seconds):

```
event: heartbeat
data: {"timestamp": "2024-01-15T14:30:00Z"}
```

5. **Error Event** (on error conditions):

```
event: error
data: {"error": "connection_limit", "message": "Too many connections", "timestamp": "2024-01-15T14:30:00Z"}
```

**JavaScript Example:**
```javascript
const eventSource = new EventSource('/api/v1/kills/stream?system_ids=30000142');

eventSource.addEventListener('connected', (event) => {
  console.log('Connected to SSE stream');
});

eventSource.addEventListener('killmail', (event) => {
  const killmail = JSON.parse(event.data);
  console.log('New killmail:', killmail);
});

eventSource.addEventListener('batch', (event) => {
  const killmails = JSON.parse(event.data);
  console.log('Historical killmails:', killmails);
});

eventSource.addEventListener('error', (event) => {
  if (event.readyState === EventSource.CLOSED) {
    console.log('Connection was closed');
  } else {
    const error = JSON.parse(event.data);
    console.error('SSE error:', error);
  }
});
```

**Python Example:**
```python
import sseclient
import requests

def stream_killmails():
    url = 'http://localhost:4004/api/v1/kills/stream?system_ids=30000142'
    response = requests.get(url, stream=True, headers={'Accept': 'text/event-stream'})
    client = sseclient.SSEClient(response)
    
    for event in client.events():
        if event.event == 'killmail':
            killmail = json.loads(event.data)
            print(f"New killmail: {killmail['killmail_id']}")
        elif event.event == 'error':
            error = json.loads(event.data)
            print(f"Error: {error['message']}")
```

**Connection Limits:**
- Maximum 100 concurrent SSE connections total
- Maximum 10 connections per IP address
- Connections timeout after 5 minutes of inactivity
- Automatic reconnection with exponential backoff recommended

**Advantages over WebSocket:**
- Simpler protocol, works over standard HTTP
- Built-in reconnection in browsers
- Better proxy/firewall compatibility
- No need for bidirectional communication
- Native EventSource API in browsers

### Webhook Subscriptions

#### Create Subscription
```http
POST /api/v1/subscriptions
Content-Type: application/json

{
  "subscriber_id": "my-app-instance",
  "system_ids": [30000142, 30002187],
  "character_ids": [95465499, 90379338],
  "callback_url": "https://myapp.com/webhooks/killmails"
}
```

**Parameters:**
- `subscriber_id` (required) - Unique identifier for your subscription
- `system_ids` (optional) - Array of EVE Online system IDs to monitor (max: 100)
- `character_ids` (optional) - Array of character IDs to track (max: 1000)
- `callback_url` (required) - HTTP/HTTPS URL where webhooks will be delivered

**Note:** At least one of `system_ids` or `character_ids` must be provided.

**Response:**
```json
{
  "data": {
    "subscription_id": "sub_123456",
    "message": "Subscription created successfully"
  }
}
```

#### List Subscriptions
```http
GET /api/v1/subscriptions
```

**Response:**
```json
{
  "data": {
    "subscriptions": [
      {
        "subscriber_id": "my-app-instance",
        "system_ids": [30000142, 30002187],
        "character_ids": [95465499],
        "callback_url": "https://myapp.com/webhooks/killmails",
        "created_at": "2024-01-15T15:00:00Z"
      }
    ],
    "count": 1
  }
}
```

#### Delete Subscription
```http
DELETE /api/v1/subscriptions/{subscriber_id}
```

**Response:**
```json
{
  "data": {
    "message": "Successfully unsubscribed",
    "subscriber_id": "my-app-instance"
  }
}
```

#### Subscription Statistics
```http
GET /api/v1/subscriptions/stats
```

Returns aggregated subscription statistics.

### Error Responses

All errors follow a standardized format:

```json
{
  "error": "Resource not found",
  "code": "not_found",
  "details": {
    "resource": "killmail",
    "id": "123456789"
  },
  "timestamp": "2024-01-15T15:00:00Z"
}
```

Common error codes:
- `bad_request` - Invalid request parameters
- `not_found` - Resource not found
- `internal_server_error` - Server error
- `timeout` - Request timeout
- `validation_error` - Input validation failed

---

## WebSocket Integration

### Connection
Connect to the WebSocket endpoint using Phoenix Socket protocol:
```
ws://localhost:4004/socket
```

### JavaScript Example
```javascript
import { Socket } from 'phoenix';

// Connect to the socket
const socket = new Socket('ws://localhost:4004/socket', {
  params: { client_identifier: 'my-app' }
});

socket.connect();

// Join the killmail lobby channel with systems and optional extended preload
const channel = socket.channel('killmails:lobby', {
  systems: [30000142, 30000144],
  character_ids: [95465499],  // Optional: track specific characters
  preload: {               // Optional: extended historical data preload
    enabled: true,
    limit_per_system: 100,
    since_hours: 168,
    delivery_batch_size: 10,
    delivery_interval_ms: 1000
  }
});

channel.join()
  .receive('ok', resp => console.log('Joined successfully', resp))
  .receive('error', resp => console.log('Unable to join', resp));

// Listen for killmail updates
channel.on('killmail_update', payload => {
  console.log(`Received ${payload.killmails.length} kills for system ${payload.system_id}`);
  console.log('Is preload:', payload.preload);
});

channel.on('kill_count_update', payload => {
  console.log(`System ${payload.system_id} has ${payload.count} kills`);
});

// Dynamic subscription management
channel.push('update_subscriptions', {
  add_systems: [30000146],
  remove_systems: [30000144],
  add_characters: [12345678],
  remove_characters: []
})
  .receive('ok', resp => console.log('Subscriptions updated'))
  .receive('error', resp => console.log('Failed to update', resp));
```

### Python Example
```python
from phoenix_client import PhoenixSocket, Channel
import asyncio

async def connect():
    # Connect to socket
    socket = PhoenixSocket("ws://localhost:4004/socket", {
        "client_identifier": "python-client"
    })
    await socket.connect()
    
    # Join channel with subscriptions
    channel = socket.channel("killmails:lobby", {
        "systems": [30000142, 30000144],
        "character_ids": [95465499],
        "preload": {
            "enabled": True,
            "limit_per_system": 50,
            "since_hours": 24
        }
    })
    
    # Set up event handlers
    def on_killmail_update(payload):
        print(f"Received {len(payload['killmails'])} kills")
        
    def on_kill_count_update(payload):
        print(f"System {payload['system_id']} has {payload['count']} kills")
    
    channel.on("killmail_update", on_killmail_update)
    channel.on("kill_count_update", on_kill_count_update)
    
    # Join the channel
    await channel.join()
    
    # Keep connection alive
    await asyncio.Event().wait()

# Run the client
asyncio.run(connect())
```

### Channel Parameters

When joining the `killmails:lobby` channel, you can specify:

- `systems` - Array of system IDs to monitor
- `character_ids` - Array of character IDs to track (as victim or attacker)
- `preload` - Optional historical data preload configuration:
  - `enabled` - Enable preload (default: false)
  - `limit_per_system` - Max kills per system to preload (default: 50)
  - `since_hours` - Hours of history to preload (default: 24)
  - `delivery_batch_size` - Kills per batch (default: 10)
  - `delivery_interval_ms` - Delay between batches (default: 1000ms)

### Events

- `killmail_update` - New killmails received
- `kill_count_update` - Kill count changed for a system
- `preload_complete` - Historical data preload finished
- `subscription_updated` - Subscription changes confirmed

---

## PubSub Integration (Elixir Applications)

For Elixir applications running in the same cluster, you can subscribe directly to the Phoenix.PubSub system:

```elixir
# Subscribe to a specific system
Phoenix.PubSub.subscribe(WandererKills.PubSub, "killmails:system:30000142")

# Subscribe to a specific character (as victim or attacker)
Phoenix.PubSub.subscribe(WandererKills.PubSub, "killmails:character:95465499")

# Handle messages
def handle_info({:killmail, killmail}, state) do
  IO.inspect(killmail, label: "New killmail")
  {:noreply, state}
end

def handle_info({:kill_count_update, %{system_id: system_id, count: count}}, state) do
  IO.puts("System #{system_id} now has #{count} kills")
  {:noreply, state}
end
```

### Available Topics

- `killmails:system:{system_id}` - Kills for a specific system
- `killmails:character:{character_id}` - Kills involving a character
- `killmails:all` - All killmails (high volume!)

---

## Client Library Integration (Elixir)

The service provides an Elixir behaviour for type-safe integration:

```elixir
# In your mix.exs
{:wanderer_kills_client, github: "wanderer-industries/wanderer-kills", sparse: "client"}

# Usage
alias WandererKills.Client

# Configure the client
config :wanderer_kills_client,
  base_url: "http://localhost:4004",
  timeout: 30_000

# Fetch kills for a system
{:ok, kills} = Client.get_system_kills(30000142, since_hours: 24, limit: 50)

# Bulk fetch multiple systems
{:ok, results} = Client.get_systems_kills([30000142, 30000144], since_hours: 24)

# Get specific killmail
{:ok, killmail} = Client.get_killmail(123456789)

# Subscribe to webhooks
{:ok, subscription} = Client.create_subscription(%{
  subscriber_id: "my-service",
  system_ids: [30000142],
  character_ids: [95465499],
  callback_url: "https://myservice.com/webhooks/kills"
})
```

---

## Rate Limiting & Best Practices

### Rate Limits
- REST API: 100 requests per minute per IP
- WebSocket: 10 subscription updates per minute per connection
- Webhooks: Retries with exponential backoff on failure

### Best Practices
1. **Use WebSocket for real-time data** instead of polling REST endpoints
2. **Cache killmail data** on your side to reduce API calls
3. **Subscribe to specific systems/characters** rather than all killmails
4. **Use bulk endpoints** when fetching multiple systems
5. **Handle webhook failures** gracefully with retries
6. **Monitor the health endpoint** to detect service issues

### Performance Tips
- For high-volume systems, use the `preload` feature with progressive delivery
- Batch webhook notifications are sent every 5 seconds or 50 kills
- The service caches killmails for 5 minutes, systems for 1 hour

---

## Error Handling

### HTTP Status Codes
- `200` - Success
- `400` - Bad request (invalid parameters)
- `404` - Resource not found
- `429` - Rate limit exceeded
- `500` - Internal server error
- `503` - Service unavailable

### WebSocket Error Events
```javascript
channel.on('error', payload => {
  console.error('Channel error:', payload.reason);
});

channel.on('subscription_error', payload => {
  console.error('Subscription error:', payload.error);
});
```

### Webhook Delivery Failures
Failed webhook deliveries are retried with exponential backoff:
- 1st retry: 1 minute
- 2nd retry: 5 minutes  
- 3rd retry: 15 minutes
- 4th retry: 1 hour
- 5th retry: Give up

---

## Monitoring & Observability

### Health Check
```bash
curl http://localhost:4004/health
```

Returns component health status and overall service health.

### Metrics
```bash
curl http://localhost:4004/metrics
```

Provides service metrics including:
- Request rates and latencies
- WebSocket connection counts
- Cache hit rates
- External API response times

### Status
```bash
curl http://localhost:4004/status
```

Detailed service status including:
- Uptime
- Version information
- Current load
- Recent errors

---

## Troubleshooting

### Common Issues

**No kills returned for a system**
- Check if the system ID is valid
- Verify the `since_hours` parameter isn't too restrictive
- The system might not have recent kills

**WebSocket connection drops**
- Check your network stability
- Implement reconnection logic
- Monitor for error events

**Webhook not receiving data**
- Ensure the callback URL is publicly accessible
- Check for SSL certificate issues
- Monitor the subscription stats endpoint

**High latency**
- Use WebSocket instead of polling
- Reduce the number of subscribed systems
- Check the service health endpoint

### Debug Mode

Enable debug logging in WebSocket:
```javascript
const socket = new Socket('ws://localhost:4004/socket', {
  params: { client_identifier: 'my-app', debug: true },
  logger: (kind, msg, data) => {
    console.log(`${kind}: ${msg}`, data);
  }
});
```

---

## Examples

Full working examples are available in the `/examples` directory:
- `websocket_client.js` - Node.js WebSocket client
- `websocket_client.py` - Python WebSocket client  
- `websocket_client.exs` - Elixir WebSocket client

Each example demonstrates connection, subscription management, and event handling.