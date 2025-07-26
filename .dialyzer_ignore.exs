[
  # The format is regex patterns that match the warning output
  # Ship types CSV processing
  ~r/lib\/wanderer_kills\/core\/ship_types\/csv\.ex:\d+/,
  
  # Ship types info and updater
  ~r/lib\/wanderer_kills\/core\/ship_types\/info\.ex:\d+/,
  ~r/lib\/wanderer_kills\/core\/ship_types\/updater\.ex:\d+/,
  
  # Enrichment pipeline - all pattern matching and unused function warnings
  ~r/lib\/wanderer_kills\/ingest\/killmails\/pipeline\/enrichment\.ex:\d+/,
  
  # Transformations
  ~r/lib\/wanderer_kills\/ingest\/killmails\/transformations\.ex:423/,
  
]