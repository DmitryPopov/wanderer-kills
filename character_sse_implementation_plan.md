# Character-Specific SSE Implementation Plan

## Overview

This document outlines the implementation plan for enhancing the SSE (Server-Sent Events) endpoint to provide character-specific killmail streaming with historical data preloading capabilities.

## Implementation Status: COMPLETED ✅

### Completed Components

1. **Backend Infrastructure** ✅
   - Extended Preloader with `preload_kills_for_characters/2` function
   - Created SSE Event Formatter module for consistent event formatting
   - Enhanced Filter Parser to support `preload_days` parameter
   - Created Filter Handler for server-side killmail filtering
   - Updated Broadcaster to publish to character-specific topics

2. **Enhanced SSE Controller** ✅
   - Created `EnhancedKillStreamController` with custom SSE implementation
   - Supports historical data preloading with batch events
   - Implements transition signals between historical and real-time modes
   - Provides heartbeats with mode indicators
   - Added route: `/api/v1/kills/stream/enhanced`

3. **Character-Specific Topics** ✅
   - Broadcasts killmails to `zkb:character:{character_id}` topics
   - Efficient routing without subscribing to all_systems topic
   - Server-side filtering reduces bandwidth usage

4. **Testing** ✅
   - Created comprehensive tests for EventFormatter
   - Created tests for FilterHandler with various scenarios
   - All tests passing

## Requirements

1. SSE clients need to retrieve killmails for specific characters for the past 90 days on-demand
2. Clients should receive historical data first, then transition to real-time updates
3. Server-side filtering to reduce bandwidth usage
4. Clear indication when historical data is complete and real-time streaming begins

## Proposed Solution

### 1. Enhanced SSE Endpoint

**Endpoint**: `GET /api/v1/kills/stream`

**New Query Parameters**:
- `preload_days`: Number of days of historical data to load (max 90, default 0)
- Existing: `character_ids`, `system_ids`, `min_value`

**Example Request**:
```
GET /api/v1/kills/stream?character_ids=12345,67890&preload_days=90
```

### 2. Event Types and Message Flow

#### Event Types
```
event: connected        # Initial connection confirmation
event: batch           # Historical killmail batch
event: killmail        # Individual killmail (real-time)
event: heartbeat       # Keep-alive with metadata
event: transition      # Explicit transition to real-time mode
event: error           # Error notifications
```

#### Message Flow Sequence
1. **Connection Established**
   ```
   event: connected
   data: {"status": "connected", "filters": {...}, "timestamp": "2025-01-01T00:00:00Z"}
   ```

2. **Historical Data Batches**
   ```
   event: batch
   data: {"kills": [...], "count": 50, "batch_number": 1, "total_batches": 5}
   ```

3. **Transition Signal**
   ```
   event: transition
   data: {"status": "historical_complete", "total_historical": 250, "timestamp": "2025-01-01T00:00:00Z"}
   ```

4. **Real-time Updates**
   ```
   event: killmail
   data: {"killmail_id": 123, "victim": {...}, "attackers": [...]}
   ```

5. **Heartbeats** (every 30 seconds)
   ```
   event: heartbeat
   data: {"timestamp": "2025-01-01T00:00:00Z", "mode": "realtime"}
   ```

### 3. Client Detection Strategy

Clients can detect the transition using multiple signals:

1. **Explicit Transition Event**: The `transition` event clearly marks the boundary
2. **Heartbeat Pattern**: Multiple consecutive heartbeats (2-3) without killmails indicate caught up to real-time
3. **Batch Completion**: The last batch event includes `total_batches` matching `batch_number`
4. **Mode Indicator**: Heartbeats include `"mode": "historical"` or `"mode": "realtime"`

## Implementation Details

### Phase 1: Backend Infrastructure (Week 1)

#### 1.1 Extend Preloader for Character Support
```elixir
# lib/wanderer_kills/subs/preloader.ex
def preload_kills_for_characters(character_ids, opts \\ []) do
  days = Keyword.get(opts, :days, 90)
  batch_size = Keyword.get(opts, :batch_size, 50)
  
  character_ids
  |> Enum.map(&fetch_character_kills(&1, days))
  |> List.flatten()
  |> Enum.sort_by(& &1.occurred_at)
  |> Enum.chunk_every(batch_size)
end

defp fetch_character_kills(character_id, days) do
  # Use ZkbClient.get_character_killmails/1
  # Filter by date range
  # Process through enrichment pipeline
end
```

#### 1.2 Create Character-Specific PubSub Topics
```elixir
# lib/wanderer_kills/subs/subscriptions/broadcaster.ex
defp broadcast_to_characters(killmail, character_ids) do
  character_ids
  |> Enum.each(fn char_id ->
    Phoenix.PubSub.broadcast(
      WandererKills.PubSub,
      "zkb:character:#{char_id}",
      {:killmail, killmail}
    )
  end)
end
```

#### 1.3 Implement SSE Event Formatter
```elixir
# lib/wanderer_kills/sse/event_formatter.ex
defmodule WandererKills.SSE.EventFormatter do
  def format_event(type, data) do
    %{
      event: to_string(type),
      data: Jason.encode!(data)
    }
  end
  
  def connected_event(filters) do
    format_event(:connected, %{
      status: "connected",
      filters: filters,
      timestamp: DateTime.utc_now()
    })
  end
  
  def batch_event(kills, batch_info) do
    format_event(:batch, %{
      kills: kills,
      count: length(kills),
      batch_number: batch_info.number,
      total_batches: batch_info.total
    })
  end
  
  def transition_event(total_historical) do
    format_event(:transition, %{
      status: "historical_complete",
      total_historical: total_historical,
      timestamp: DateTime.utc_now()
    })
  end
  
  def heartbeat_event(mode) do
    format_event(:heartbeat, %{
      timestamp: DateTime.utc_now(),
      mode: mode
    })
  end
end
```

### Phase 2: SSE Controller Enhancement (Week 1-2)

#### 2.1 Enhance Filter Parser
```elixir
# lib/wanderer_kills/sse/filter_parser.ex
def parse_filters(params) do
  %{
    character_ids: parse_character_ids(params["character_ids"]),
    system_ids: parse_system_ids(params["system_ids"]),
    min_value: parse_min_value(params["min_value"]),
    preload_days: parse_preload_days(params["preload_days"])
  }
end

defp parse_preload_days(nil), do: 0
defp parse_preload_days(days) do
  days
  |> String.to_integer()
  |> min(90)  # Cap at 90 days
  |> max(0)
end
```

#### 2.2 Modify KillStreamController
```elixir
# lib/wanderer_kills_web/controllers/kill_stream_controller.ex
def stream(conn, params) do
  filters = FilterParser.parse_filters(params)
  
  conn
  |> put_resp_header("cache-control", "no-cache")
  |> put_resp_header("x-accel-buffering", "no")
  |> SSEPhoenix.stream(
    event_builder: &build_event/2,
    init: fn ->
      init_connection(filters)
    end
  )
end

defp init_connection(filters) do
  # Send connected event
  send_event(:connected, EventFormatter.connected_event(filters))
  
  # Handle historical preload if requested
  if filters.character_ids && filters.preload_days > 0 do
    spawn_link(fn -> 
      preload_historical_data(filters)
    end)
  end
  
  # Subscribe to appropriate topics
  subscribe_to_topics(filters)
  
  %{filters: filters, mode: :historical, historical_count: 0}
end

defp preload_historical_data(filters) do
  batches = Preloader.preload_kills_for_characters(
    filters.character_ids,
    days: filters.preload_days
  )
  
  total_batches = length(batches)
  total_count = 0
  
  batches
  |> Enum.with_index(1)
  |> Enum.each(fn {kills, batch_num} ->
    send_event(:batch, EventFormatter.batch_event(kills, %{
      number: batch_num,
      total: total_batches
    }))
    total_count = total_count + length(kills)
    Process.sleep(100)  # Prevent overwhelming client
  end)
  
  # Send transition event
  send_event(:transition, EventFormatter.transition_event(total_count))
  
  # Update state to realtime mode
  update_connection_mode(:realtime)
end
```

### Phase 3: Server-Side Filtering (Week 2)

#### 3.1 Implement Filtering Layer
```elixir
# lib/wanderer_kills/sse/filter_handler.ex
defmodule WandererKills.SSE.FilterHandler do
  def should_send_killmail?(killmail, filters) do
    cond do
      # Character filter
      filters.character_ids != [] ->
        character_matches?(killmail, filters.character_ids)
      
      # System filter  
      filters.system_ids != [] ->
        system_matches?(killmail, filters.system_ids)
        
      # No filters - send all
      true -> true
    end
  end
  
  defp character_matches?(killmail, character_ids) do
    character_set = MapSet.new(character_ids)
    
    # Check victim
    victim_matches = MapSet.member?(character_set, killmail.victim.character_id)
    
    # Check attackers
    attacker_matches = Enum.any?(killmail.attackers, fn attacker ->
      MapSet.member?(character_set, attacker.character_id)
    end)
    
    victim_matches or attacker_matches
  end
end
```

#### 3.2 Modify Broadcasting Logic
```elixir
# Instead of subscribing to all_systems for character filters,
# implement a filtering broadcast handler
defp handle_killmail_broadcast(killmail, state) do
  if FilterHandler.should_send_killmail?(killmail, state.filters) do
    send_event(:killmail, killmail)
  end
end
```

### Phase 4: Enhanced Heartbeat System (Week 2)

#### 4.1 Custom Heartbeat Handler
```elixir
# Override default SSE heartbeat with custom implementation
defp start_heartbeat_timer(state) do
  Process.send_after(self(), :send_heartbeat, 30_000)
  state
end

defp handle_info(:send_heartbeat, state) do
  send_event(:heartbeat, EventFormatter.heartbeat_event(state.mode))
  start_heartbeat_timer(state)
  {:noreply, state}
end
```

### Phase 5: Testing & Documentation (Week 3)

#### 5.1 Test Coverage
- Unit tests for all new modules
- Integration tests for SSE streaming
- Performance tests for character filtering
- Load tests for concurrent connections

#### 5.2 Documentation Updates
- Update OpenAPI schema
- Add usage examples
- Document client-side handling patterns
- Update CLAUDE.md with new features

## Migration Strategy

1. **Backward Compatibility**: Existing SSE connections without `preload_days` continue to work as before
2. **Feature Flag**: Add `config :wanderer_kills, :features, character_sse_preload: true`
3. **Gradual Rollout**: Test with subset of clients before full deployment
4. **Monitoring**: Add telemetry for preload performance and connection patterns

## Performance Considerations

1. **Batching**: Historical data sent in chunks of 50 killmails
2. **Rate Limiting**: 100ms delay between batches to prevent client overwhelm
3. **Caching**: Leverage existing Cachex for character killmail caching
4. **Connection Limits**: Respect existing SSE connection limits

## Success Metrics

1. **Reduced Bandwidth**: 90%+ reduction in unnecessary killmail transmission
2. **Client Satisfaction**: Clear indication of historical/realtime boundary
3. **Performance**: Preload completes within 30 seconds for 90 days of data
4. **Reliability**: No dropped connections during preload phase

## Timeline

- **Week 1**: Backend infrastructure and character preloading
- **Week 2**: SSE controller enhancements and filtering
- **Week 3**: Testing, documentation, and deployment
- **Week 4**: Monitoring and optimization based on production usage

## Usage Instructions

### Enhanced Endpoint

The new enhanced SSE endpoint is available at:
```
GET /api/v1/kills/stream/enhanced
```

### Query Parameters

- `character_ids` - Comma-separated list of character IDs to track
- `system_ids` - Comma-separated list of system IDs to filter
- `min_value` - Minimum ISK value threshold for killmails
- `preload_days` - Number of days of historical data to preload (0-90)

### Example Request

```bash
curl -N "http://localhost:4004/api/v1/kills/stream/enhanced?character_ids=123456789,987654321&preload_days=90"
```

## Example Client Implementation

```javascript
const eventSource = new EventSource('/api/v1/kills/stream/enhanced?character_ids=12345&preload_days=90');

let isRealtime = false;
let heartbeatCount = 0;

eventSource.addEventListener('connected', (e) => {
  console.log('Connected to SSE stream', JSON.parse(e.data));
});

eventSource.addEventListener('batch', (e) => {
  const batch = JSON.parse(e.data);
  console.log(`Historical batch ${batch.batch_number}/${batch.total_batches}`);
  heartbeatCount = 0; // Reset on data
});

eventSource.addEventListener('transition', (e) => {
  console.log('Transitioned to realtime mode', JSON.parse(e.data));
  isRealtime = true;
});

eventSource.addEventListener('killmail', (e) => {
  const killmail = JSON.parse(e.data);
  console.log(`${isRealtime ? 'Realtime' : 'Historical'} killmail:`, killmail);
  heartbeatCount = 0; // Reset on data
});

eventSource.addEventListener('heartbeat', (e) => {
  heartbeatCount++;
  const hb = JSON.parse(e.data);
  
  // Alternative detection: 3 heartbeats without data = realtime
  if (!isRealtime && heartbeatCount >= 3) {
    console.log('Detected realtime mode via heartbeat pattern');
    isRealtime = true;
  }
});
```

## Open Questions

1. Should we implement resumable streams for interrupted connections?
2. Should character killmails be cached separately from system killmails?
3. Should we add compression for large historical batches?
4. Do we need to implement backpressure if clients can't keep up?