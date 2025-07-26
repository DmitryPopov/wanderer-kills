defmodule WandererKills.Ingest.Boundary do
  @moduledoc """
  Boundary definition for the Ingest context.

  The Ingest context is responsible for fetching and processing killmail data
  from external APIs (ESI, zKillboard). It transforms raw external data into
  internal domain models and stores them using Core services.

  ## Responsibilities
  - External API client management (ESI, zKillboard)
  - Real-time data streaming (RedisQ)
  - Killmail processing pipeline
  - Data enrichment and validation
  - Rate limiting for external APIs
  - Historical data fetching

  ## Dependencies
  - Core: For storage, caching, error handling, and utilities
  - Domain: For killmail models and data structures

  ## Public API
  Only the following modules should be used by other contexts:
  """

  use Boundary,
    deps: [
      WandererKills.Core,
      WandererKills.Domain
    ],
    exports: [
      # Main processing entry point
      WandererKills.Ingest.Killmails.UnifiedProcessor,

      # Historical data fetching
      WandererKills.Ingest.HistoricalFetcher,

      # Character-related utilities
      WandererKills.Ingest.Killmails.CharacterMatcher,
      WandererKills.Ingest.Killmails.CharacterCache,

      # Batch processing utilities
      WandererKills.Ingest.Killmails.BatchProcessor,

      # Rate limiting
      WandererKills.Ingest.SmartRateLimiter,

      # Real-time streaming
      WandererKills.Ingest.RedisQ
    ]
end
