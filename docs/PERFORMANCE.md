# Performance Guide

WandererKills is optimized for high-throughput killmail processing and low-latency real-time subscriptions. This guide covers performance characteristics, monitoring capabilities, and optimization tips.

## Performance Overview

The service leverages Elixir's actor model, ETS-based storage, and comprehensive telemetry to achieve:
- Sub-second API response times
- Real-time killmail delivery via WebSocket and SSE
- Efficient memory usage with automatic caching
- Horizontal scalability through Phoenix PubSub

## Key Performance Metrics

### API Performance

| Metric | Target | Monitoring |
|--------|--------|------------|
| **REST API Latency** | < 100ms p95 | `[:wanderer_kills, :http, :request, :stop]` |
| **WebSocket Latency** | < 50ms | Real-time delivery |
| **SSE Latency** | < 50ms | Phoenix PubSub integration |
| **Bulk Operations** | < 500ms for 100 items | Parallel processing |
| **Cache Hit Rate** | > 80% | `[:wanderer_kills, :cache, :hit]` |

### Processing Performance

| Component | Throughput | Monitoring |
|-----------|------------|------------|
| **RedisQ Consumer** | 1000+ kills/minute | `[:wanderer_kills, :parser, :stored]` |
| **ESI Enrichment** | 100+ requests/second | Rate limited with backoff |
| **Batch Processing** | Parallel with supervised tasks | `[:wanderer_kills, :task, :stop]` |
| **WebSocket Broadcast** | 10,000+ clients | Phoenix PubSub |
| **SSE Connections** | 1000+ concurrent | sse_phoenix_pubsub library |

### Resource Usage

| Resource | Typical Usage | Monitoring |
|----------|---------------|------------|
| **Memory** | 200-500MB | System metrics every 5 minutes |
| **CPU** | 10-30% | Scheduler usage percentage |
| **ETS Tables** | < 100MB | Cache size monitoring |
| **Processes** | < 1000 | Process count tracking |

## Telemetry Events

The service emits comprehensive telemetry events for monitoring:

### HTTP Performance
```elixir
# Track external API calls
[:wanderer_kills, :http, :request, :start]
[:wanderer_kills, :http, :request, :stop]    # Includes duration
[:wanderer_kills, :http, :request, :error]   # Includes duration
```

### Cache Performance
```elixir
[:wanderer_kills, :cache, :hit]
[:wanderer_kills, :cache, :miss]
[:wanderer_kills, :cache, :error]
```

### Processing Performance
```elixir
[:wanderer_kills, :parser, :stored]   # Count of stored killmails
[:wanderer_kills, :parser, :skipped]  # Count of skipped killmails
[:wanderer_kills, :parser, :failed]   # Count of failed killmails
[:wanderer_kills, :parser, :summary]  # Aggregate statistics
```

### Subscription Performance
```elixir
[:wanderer_kills, :character, :match]   # Character matching duration
[:wanderer_kills, :character, :filter]  # Character filtering duration
[:wanderer_kills, :system, :filter]     # System filtering duration
```

### Task Performance
```elixir
[:wanderer_kills, :task, :start]
[:wanderer_kills, :task, :stop]   # Includes duration
[:wanderer_kills, :task, :error]  # Includes duration
```

## Performance Monitoring

### Real-time Metrics

Access current performance metrics via the API:

```bash
# Overall metrics
curl http://localhost:4004/metrics

# Service status with 5-minute aggregates
curl http://localhost:4004/status

# WebSocket statistics
curl http://localhost:4004/websocket/status
```

### 5-Minute Status Reports

The service logs comprehensive status reports every 5 minutes including:

- **API Metrics**: Requests/minute, error rates, p95/p99 latencies
- **Processing Metrics**: RedisQ stats, parser success rates, lag
- **Cache Metrics**: Hit rates, efficiency, operations/minute
- **System Metrics**: Memory, CPU, processes, garbage collection

### Integrating with Monitoring Tools

Attach Telemetry handlers for external monitoring:

```elixir
# Example: Send metrics to StatsD
:telemetry.attach(
  "wanderer-kills-statsd",
  [:wanderer_kills, :http, :request, :stop],
  &MyApp.Telemetry.handle_event/4,
  nil
)
```

## Performance Optimization

### Caching Strategy

The service uses multi-tier caching:

| Cache Type | TTL | Purpose |
|------------|-----|---------|
| **Killmails** | 5 minutes | Recent kill data |
| **Systems** | 1 hour | System information |
| **ESI Data** | 24 hours | Character/corp names |
| **Ship Types** | Permanent | Ship type lookups |

### Batch Operations

Use bulk endpoints for better performance:

```bash
# Instead of multiple single-system calls
POST /api/v1/kills/systems
{
  "system_ids": [30000142, 30000144, 30000145],
  "since_hours": 24
}
```

### WebSocket Preloading

Configure progressive preloading for large datasets:

```javascript
const channel = socket.channel('killmails:lobby', {
  systems: [30000142],
  preload: {
    enabled: true,
    limit_per_system: 100,
    delivery_batch_size: 10,      // Smaller batches
    delivery_interval_ms: 1000    // Spread over time
  }
});
```

### SSE Connection Management

The SSE implementation uses `sse_phoenix_pubsub` for efficient connection handling:
- Automatic connection management
- Built-in heartbeat mechanism
- Phoenix PubSub integration for consistent message delivery
- HTTP/1.1 compatible for wide proxy support

### Connection Pooling

The HTTP client uses connection pooling:
- Pool size: 10 connections per service
- Keep-alive: Enabled
- Timeout: 30 seconds

## Scalability

### Horizontal Scaling

The service supports clustering via distributed Erlang:
- Phoenix PubSub for cross-node communication
- Shared-nothing architecture
- Load balancer friendly

### Resource Limits

Configure limits based on your hardware:

```elixir
# config/runtime.exs
config :wanderer_kills,
  max_concurrent_fetches: 10,
  batch_size: 50,
  cache_size_limit: 100_000
```

### Database Considerations

The service uses ETS for storage:
- In-memory performance
- No disk I/O bottlenecks
- Automatic garbage collection
- Configurable table limits

## Troubleshooting Performance

### High Memory Usage

1. Check cache sizes: `GET /metrics`
2. Review cache TTLs in configuration
3. Monitor ETS table growth
4. Check for subscription leaks

### Slow API Responses

1. Check cache hit rates
2. Monitor external API latencies
3. Review batch sizes
4. Check connection pool exhaustion

### WebSocket Lag

1. Monitor preload settings
2. Check subscription counts
3. Review broadcast batch sizes
4. Monitor PubSub performance

### High CPU Usage

1. Check killmail processing rates
2. Monitor garbage collection
3. Review supervision tree
4. Check for busy loops

## Best Practices

1. **Monitor Telemetry**: Set up dashboards for key metrics
2. **Use Caching**: Leverage cached endpoints when possible
3. **Batch Requests**: Use bulk operations for multiple items
4. **Progressive Loading**: Configure preload for large datasets
5. **Resource Limits**: Set appropriate limits for your hardware
6. **Health Checks**: Monitor `/health` endpoint regularly

## Example: Setting Up Monitoring

```elixir
# In your application
defmodule MyApp.Monitoring do
  def setup do
    # Track API latencies
    :telemetry.attach(
      "api-latency",
      [:wanderer_kills, :http, :request, :stop],
      &handle_api_latency/4,
      nil
    )
    
    # Track cache performance
    :telemetry.attach_many(
      "cache-performance",
      [
        [:wanderer_kills, :cache, :hit],
        [:wanderer_kills, :cache, :miss]
      ],
      &handle_cache_event/4,
      nil
    )
  end
  
  defp handle_api_latency(_event, measurements, metadata, _config) do
    # Send to your monitoring system
    duration_ms = measurements.duration / 1_000_000
    MyMetrics.histogram("api.latency", duration_ms, tags: [service: metadata.service])
  end
  
  defp handle_cache_event(event, _measurements, metadata, _config) do
    case event do
      [:wanderer_kills, :cache, :hit] ->
        MyMetrics.increment("cache.hits", tags: [type: metadata.cache_type])
      [:wanderer_kills, :cache, :miss] ->
        MyMetrics.increment("cache.misses", tags: [type: metadata.cache_type])
    end
  end
end
```

For detailed metrics and monitoring integration, see the [API & Integration Guide](API_AND_INTEGRATION_GUIDE.md#monitoring--observability).