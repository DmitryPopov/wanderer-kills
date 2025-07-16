# Historical Kill Streaming Implementation Plan

## Overview

Implementation of a background process to stream historical killmail data from zkillboard's history API. The process will fetch daily kill lists and process them through the existing pipeline to ensure consistency with real-time data.

## Key Requirements

1. **Data Consistency**: All historical kills will be processed through the existing `UnifiedProcessor` pipeline
2. **ESI Enrichment**: Full ESI data enrichment will be applied to historical kills
3. **Stream Format**: Output format will match existing killmail stream format exactly
4. **Rate Limiting**: Respect zkillboard API limits and avoid overwhelming clients

## Architecture

### New Components

#### 1. `HistoricalStreamer` GenServer
- Location: `/lib/wanderer_kills/ingest/historical/historical_streamer.ex`
- Manages historical date progression and kill fetching
- Coordinates with existing rate limiting infrastructure

#### 2. Configuration
```elixir
config :wanderer_kills, :historical_streaming,
  enabled: System.get_env("HISTORICAL_STREAMING_ENABLED", "false") == "true",
  start_date: System.get_env("HISTORICAL_START_DATE", "20240101"),
  daily_limit: String.to_integer(System.get_env("HISTORICAL_DAILY_LIMIT", "5000")),
  batch_size: String.to_integer(System.get_env("HISTORICAL_BATCH_SIZE", "50")),
  batch_interval_ms: String.to_integer(System.get_env("HISTORICAL_BATCH_INTERVAL_MS", "10000"))
```

### Processing Pipeline

1. **Fetch Daily Index**
   - GET `https://zkillboard.com/api/history/YYYYMMDD.json`
   - Returns map of killmail_id => hash

2. **Batch Processing**
   - Process kills in configurable batches
   - Each kill fetched individually via existing `ZkbClient.fetch_killmail/1`
   - Full processing through `UnifiedProcessor`:
     - Parsing and validation
     - ESI enrichment (character, corporation, ship info)
     - Storage in ETS
     - Event broadcasting

3. **Rate Limiting**
   - New priority level `:historical` (lowest priority)
   - Integration with `SmartRateLimiter`
   - Configurable batch intervals
   - Daily quotas to prevent API exhaustion

### Integration Points

1. **SmartRateLimiter**
   - Add `:historical` priority below `:bulk`
   - Ensures real-time data takes precedence

2. **UnifiedProcessor**
   - All historical kills processed identically to real-time kills
   - Guarantees format consistency
   - Applies same validation and enrichment

3. **Storage & Broadcasting**
   - Uses existing `KillmailStore`
   - Broadcasts through existing PubSub channels
   - WebSocket/SSE clients receive historical kills seamlessly

4. **Monitoring**
   - Telemetry events for progress tracking
   - Dashboard integration for visibility
   - Health checks for stuck processing

## Implementation Steps

1. Create `HistoricalStreamer` GenServer with state management
2. Add `:historical` priority to `SmartRateLimiter`
3. Implement zkillboard history API client method
4. Add configuration and environment variables
5. Integrate with supervision tree
6. Add telemetry and monitoring
7. Create tests for new functionality

## Benefits

- **Seamless Integration**: Historical kills indistinguishable from real-time
- **Full Enrichment**: Complete ESI data for all historical kills
- **Rate Limited**: Respects API limits and system resources
- **Observable**: Full telemetry and monitoring
- **Resumable**: Can stop/start at any date
- **Configurable**: Flexible batch sizes and intervals