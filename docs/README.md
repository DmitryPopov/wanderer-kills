# WandererKills Documentation

Welcome to the WandererKills service documentation. WandererKills is a real-time EVE Online killmail data service built with Elixir/Phoenix.

## 🎯 Simplified Architecture

The codebase underwent major simplification across 6 sprints, achieving:
- **39% reduction** in module count (115 → ~70)
- **50% simpler** processing pipeline (6 → 3 stages)
- **50% fewer** cache namespaces (8 → 4)
- **10-194x better** performance than requirements
- **100% functionality** preserved

## 📖 [API & Integration Guide](API_AND_INTEGRATION_GUIDE.md)

**Complete documentation** - This is the primary documentation source for the WandererKills service.

**Covers everything you need:**
- REST API endpoints with examples
- WebSocket real-time integration
- Server-Sent Events (SSE) streaming
- PubSub integration for Elixir apps  
- Client library usage
- Error handling and best practices
- Code examples in Python, Node.js, and Elixir
- Rate limiting and monitoring
- Troubleshooting guide

## Quick Start

1. **For HTTP/REST integration**: See [REST API Integration](API_AND_INTEGRATION_GUIDE.md#rest-api-integration)
2. **For WebSocket real-time data**: See [WebSocket Integration](API_AND_INTEGRATION_GUIDE.md#websocket-integration)
3. **For SSE streaming**: See [Server-Sent Events](API_AND_INTEGRATION_GUIDE.md#server-sent-events-sse-stream)
4. **For Elixir applications**: See [PubSub Integration](API_AND_INTEGRATION_GUIDE.md#pubsub-integration-elixir-applications)
5. **For client library usage**: See [Client Library Integration](API_AND_INTEGRATION_GUIDE.md#client-library-integration-elixir)

## Service Information

- **Default Port**: 4004
- **Base URL**: `http://localhost:4004/api/v1`
- **Health Check**: `http://localhost:4004/health`
- **Status Endpoint**: `http://localhost:4004/status`
- **Metrics**: `http://localhost:4004/metrics`
- **WebSocket Info**: `http://localhost:4004/websocket`
- **SSE Stream**: `http://localhost:4004/api/v1/kills/stream`
- **OpenAPI Spec**: `http://localhost:4004/api/openapi`

## Architecture Overview

WandererKills provides:
- Real-time killmail data from zKillboard via RedisQ
- Historical data fetching and caching
- ESI (EVE Swagger Interface) data enrichment
- Multiple integration patterns for different use cases
- Comprehensive monitoring and observability

### Simplified Processing Pipeline
```
Killmail Data → Validation → Enrichment → Storage
```

### Key Components
- **UnifiedProcessor**: Orchestrates the 3-stage pipeline
- **SmartRateLimiter**: Unified rate limiting with dual-mode operation
- **WandererKills.Http.Client**: Foundation for all HTTP operations
- **4 Cache Namespaces**: killmails, systems, esi_data, temp_data

## Common Integration Patterns

### 1. REST API (HTTP)

Best for batch processing and simple integrations.
- Get kills by system
- Bulk fetch multiple systems
- Query specific killmails
- Manage webhook subscriptions

### 2. WebSocket

Best for real-time dashboards and low-latency applications.
- Real-time killmail updates
- System and character-based subscriptions
- Historical data preloading
- Dynamic subscription management

### 3. Server-Sent Events (SSE)

Best for simple server-to-client streaming without complex client libraries.
- HTTP-based streaming protocol
- Native browser EventSource support
- Automatic reconnection
- Proxy and firewall friendly

### 4. PubSub (Elixir)

Best for Elixir applications in the same environment requiring high throughput.
- Direct Phoenix.PubSub integration
- Minimal latency
- Event-driven architecture

### 5. Client Library (Elixir)

Best for type-safe integration with compile-time interface validation.
- Full API coverage
- Built-in error handling
- Telemetry integration

## Key Features

- **Caching**: Simplified 4-namespace caching with sub-10μs operations
- **Event Streaming**: Real-time updates via WebSocket, SSE, and PubSub
- **Batch Operations**: Efficient bulk data fetching with Flow
- **Monitoring**: Real-time dashboard, unified health checks, and telemetry
- **Ship Type Data**: Pre-loaded ship type information for enrichment
- **Error Handling**: Standardized error responses using Core.Support.Error
- **Performance**: 10-194x better than requirements across all operations
- **Scalability**: Supports 10,000+ WebSocket connections, 50,000 character subscriptions

## Getting Help

- **Comprehensive Guide**: [API_AND_INTEGRATION_GUIDE.md](API_AND_INTEGRATION_GUIDE.md)
- **Performance Guide**: [PERFORMANCE.md](PERFORMANCE.md)
- **Developer Guide**: See [CLAUDE.md](../CLAUDE.md) for architecture details
- **Example Clients**: See the `/examples` directory
- **Health Check**: Monitor service status at `GET /health`
- **Real-time Dashboard**: Access system metrics at `http://localhost:4004/dashboard`
- **GitHub Issues**: Report bugs or request features