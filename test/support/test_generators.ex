defmodule WandererKills.TestGenerators do
  @moduledoc """
  Consolidated property-based test generators.

  This module provides generators for use with StreamData and property-based testing.
  """

  use ExUnitProperties

  # ============================================================================
  # Basic Generators
  # ============================================================================

  @doc """
  Generates valid cache keys.
  """
  def cache_key do
    gen all(
          namespace <- member_of([:killmails, :systems, :characters, :corporations]),
          id <- positive_integer()
        ) do
      "#{namespace}:#{id}"
    end
  end

  @doc """
  Generates cache values suitable for testing.
  """
  def cache_value do
    one_of([
      string(:alphanumeric, min_length: 1),
      integer(),
      boolean(),
      simple_map()
    ])
  end

  @doc """
  Generates simple maps for testing.
  """
  def simple_map do
    gen all(
          key1 <- string(:alphanumeric, min_length: 1, max_length: 10),
          key2 <- string(:alphanumeric, min_length: 1, max_length: 10),
          val1 <- one_of([string(:alphanumeric), integer()]),
          val2 <- one_of([string(:alphanumeric), integer()])
        ) do
      %{key1 => val1, key2 => val2}
    end
  end

  # ============================================================================
  # EVE Online Specific Generators
  # ============================================================================

  @doc """
  Generates valid EVE Online system IDs.
  """
  def system_id do
    # EVE system IDs are typically in the 30000000-32000000 range
    integer(30_000_000..32_000_000)
  end

  @doc """
  Generates valid EVE Online character IDs.
  """
  def character_id do
    # Character IDs are typically > 90000000
    integer(90_000_000..99_999_999)
  end

  @doc """
  Generates valid killmail IDs.
  """
  def killmail_id do
    # Modern killmail IDs are typically > 100000000
    integer(100_000_000..999_999_999)
  end

  @doc """
  Generates valid ship type IDs.
  """
  def ship_type_id do
    # Common ship type IDs
    member_of([
      # Rifter
      587,
      # Tengu
      29_984,
      # Crow
      11_176,
      # Vexor
      624,
      # Caracal
      32_790
    ])
  end

  @doc """
  Generates ISK values.
  """
  def isk_value do
    # Generate realistic ISK values from 1K to 10B
    gen all(
          base <- integer(1..10_000),
          multiplier <- member_of([1_000, 10_000, 100_000, 1_000_000, 10_000_000])
        ) do
      base * multiplier
    end
  end

  # ============================================================================
  # Complex Generators
  # ============================================================================

  @doc """
  Generates a minimal killmail structure for testing.
  """
  def minimal_killmail do
    gen all(
          km_id <- killmail_id(),
          sys_id <- system_id(),
          char_id <- character_id(),
          ship_id <- ship_type_id(),
          value <- isk_value()
        ) do
      %{
        "killmail_id" => km_id,
        "system_id" => sys_id,
        "victim" => %{
          "character_id" => char_id,
          "ship_type_id" => ship_id
        },
        "zkb" => %{
          "totalValue" => value
        }
      }
    end
  end

  @doc """
  Generates subscription filter parameters.
  """
  def subscription_filter do
    gen all(
          min_value <- one_of([nil, isk_value()]),
          ship_types <- one_of([nil, list_of(ship_type_id(), max_length: 5)]),
          involved <- one_of([nil, list_of(character_id(), max_length: 3)])
        ) do
      filter = %{}
      filter = if min_value, do: Map.put(filter, :min_value, min_value), else: filter
      filter = if ship_types, do: Map.put(filter, :ship_types, ship_types), else: filter
      filter = if involved, do: Map.put(filter, :involved, involved), else: filter
      filter
    end
  end

  # ============================================================================
  # Test Data Generators
  # ============================================================================

  @doc """
  Generates HTTP response status codes.
  """
  def http_status do
    frequency([
      {70, constant(200)},
      {10, constant(404)},
      {10, constant(500)},
      {5, constant(429)},
      {5, member_of([201, 204, 400, 401, 403, 502, 503])}
    ])
  end

  @doc """
  Generates HTTP headers.
  """
  def http_headers do
    list_of(
      tuple({
        string(:alphanumeric, min_length: 1, max_length: 20),
        string(:alphanumeric, min_length: 1, max_length: 50)
      }),
      max_length: 5
    )
  end

  @doc """
  Generates rate limiter tokens.
  """
  def rate_limiter_tokens do
    integer(0..100)
  end

  @doc """
  Generates batch sizes for testing.
  """
  def batch_size do
    member_of([1, 5, 10, 25, 50, 100])
  end
end
