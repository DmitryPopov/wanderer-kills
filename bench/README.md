# WandererKills Performance Benchmarks

This directory contains comprehensive performance benchmarks for the WandererKills system, designed to validate that the Sprint 4-6 simplifications have not degraded performance.

## Running Benchmarks

### Run All Benchmarks with Report
```bash
mix run bench/run_all_benchmarks.exs > performance_report.md
```

### Run Individual Benchmarks
```bash
# UnifiedProcessor Pipeline
mix run bench/unified_processor_benchmark.exs

# Subscription System
mix run bench/subscription_benchmark.exs

# HTTP Client Infrastructure  
mix run bench/http_client_benchmark.exs

# Cache Operations
mix run bench/cache_benchmark.exs

# Batch Processing
mix run bench/batch_processor_benchmark.exs
```

## Benchmark Coverage

### 1. UnifiedProcessor Pipeline (`unified_processor_benchmark.exs`)
- Single killmail processing time
- Batch processing performance (10, 50, 100, 500 killmails)
- Pipeline stage performance (validation, enrichment, storage)
- Full vs partial killmail processing comparison
- Memory usage per killmail

### 2. Subscription System (`subscription_benchmark.exs`)
- Character index lookup performance (Target: ~7.64 μs)
- System index lookup performance (Target: ~8.32 μs)
- Subscription filtering performance
- WebSocket message broadcasting performance
- Large scale subscription handling (50,000 characters, 10,000 systems)

### 3. HTTP Client Infrastructure (`http_client_benchmark.exs`)
- Request/response time with unified HTTP client
- Smart rate limiter performance
- Request coalescing effectiveness
- Error handling and retry logic performance
- Concurrent request handling

### 4. Cache Operations (`cache_benchmark.exs`)
- Cache hit/miss performance
- Character extraction caching
- Ship type cache performance
- Concurrent cache operations
- Memory usage under load
- TTL expiration overhead

### 5. Batch Processing (`batch_processor_benchmark.exs`)
- Character extraction from killmails
- Subscription matching performance
- Character index performance at scale
- Realistic scenario simulation

## Performance Targets

Key performance metrics that must be maintained:

| Metric | Target | Description |
|--------|--------|-------------|
| Character Index Lookup | ~7.64 μs | Sub-microsecond character lookups |
| System Index Lookup | ~8.32 μs | Sub-microsecond system lookups |
| Single Killmail Processing | < 5ms | End-to-end processing time |
| Batch Throughput | > 1,000/min | Killmails processed per minute |
| Cache Hit Performance | < 50 μs | Cache retrieval time |
| WebSocket Support | 10,000+ clients | Concurrent connection support |
| Memory per Killmail | < 10 KB | Memory efficiency |

## Interpreting Results

The benchmarks output detailed metrics for each component. Look for:

1. **Pass/Fail Status**: Character and System index lookups show ✓ PASS or ✗ FAIL
2. **Throughput Metrics**: Operations per second for various components
3. **Latency Percentiles**: P95 and P99 values for consistency
4. **Memory Usage**: Total and per-operation memory consumption
5. **Scalability Tests**: Performance at different load levels

## Adding New Benchmarks

To add a new benchmark:

1. Create a new file in `/bench` directory
2. Follow the naming convention: `component_benchmark.exs`
3. Include module documentation with run instructions
4. Emit clear, parseable output for the report generator
5. Add the benchmark to `run_all_benchmarks.exs`

## Notes

- Benchmarks use realistic data distributions (solo kills, small gang, large fleet)
- Memory benchmarks force garbage collection for accurate measurements
- Network benchmarks use httpbin.org for consistent external testing
- All benchmarks warm up caches/JIT before measurement