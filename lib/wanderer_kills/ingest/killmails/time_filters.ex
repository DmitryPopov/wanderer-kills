defmodule WandererKills.Ingest.Killmails.TimeFilters do
  @moduledoc """
  Centralized module for time-based filtering and validation of killmails.

  This module consolidates time-related logic that was previously scattered
  across multiple validation and processing modules, providing consistent
  time handling throughout the application.

  ## Functions

  - Time parsing and validation (ISO8601 timestamps)
  - Cutoff time filtering (age-based rejection)
  - Time range validation
  - Recent fetch checking
  - Duration calculations

  ## Usage

  ```elixir
  # Parse and validate killmail time
  {:ok, kill_time} = TimeFilters.parse_killmail_time("2024-01-01T12:00:00Z")

  # Check if killmail passes cutoff
  case TimeFilters.validate_cutoff_time(killmail, cutoff_time) do
    :ok -> # Process killmail
    {:error, reason} -> # Reject killmail
  end

  # Check system fetch recency
  TimeFilters.is_recent_fetch?(system_id, hours: 24)
  ```
  """

  require Logger
  alias WandererKills.Core.Cache
  alias WandererKills.Core.Support.Error

  @type killmail :: map()
  @type time_string :: String.t()
  @type cutoff_result :: :ok | {:error, Error.t()}
  @type parse_result :: {:ok, DateTime.t()} | {:error, Error.t()}

  # Default time configurations
  @default_cutoff_hours 24
  @default_recent_threshold_hours 5

  # ============================================================================
  # Time Parsing and Validation
  # ============================================================================

  @doc """
  Parses a killmail timestamp string to DateTime.

  Handles ISO8601 timestamp parsing with proper error handling
  and standardized error reporting.

  ## Parameters
  - `time_string` - ISO8601 timestamp string from killmail

  ## Returns
  - `{:ok, datetime}` - Successfully parsed DateTime
  - `{:error, error}` - Parsing failed with detailed error

  ## Examples

  ```elixir
  {:ok, datetime} = parse_killmail_time("2024-01-01T12:00:00Z")
  {:error, error} = parse_killmail_time("invalid-time")
  ```
  """
  @spec parse_killmail_time(time_string()) :: parse_result()
  def parse_killmail_time(time_string) when is_binary(time_string) do
    case DateTime.from_iso8601(time_string) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      {:error, reason} ->
        {:error,
         Error.killmail_error(:invalid_time_format, "Failed to parse ISO8601 timestamp", false, %{
           time_string: time_string,
           underlying_error: reason
         })}
    end
  end

  def parse_killmail_time(nil) do
    {:error, Error.killmail_error(:missing_time, "Kill time is missing", false, %{})}
  end

  def parse_killmail_time(time) do
    {:error,
     Error.killmail_error(:invalid_time_type, "Kill time must be a string", false, %{
       provided_type: typeof(time),
       provided_value: time
     })}
  end

  @doc """
  Extracts and parses time from killmail data.

  Handles different time field variations and provides
  consistent time extraction from killmail structures.

  ## Parameters
  - `killmail` - Killmail map containing time information

  ## Returns
  - `{:ok, datetime}` - Successfully extracted and parsed time
  - `{:error, error}` - Extraction or parsing failed
  """
  @spec extract_killmail_time(killmail()) :: parse_result()
  def extract_killmail_time(killmail) when is_map(killmail) do
    # Try different possible time fields
    time_string = killmail["kill_time"] || killmail["killmail_time"] || killmail["killTime"]
    parse_killmail_time(time_string)
  end

  # ============================================================================
  # Cutoff Time Validation
  # ============================================================================

  @doc """
  Validates that a killmail is not older than the cutoff time.

  ## Parameters
  - `killmail` - Killmail to validate
  - `cutoff_time` - DateTime representing the cutoff threshold

  ## Returns
  - `:ok` - Killmail passes cutoff validation
  - `{:error, error}` - Killmail is too old or validation failed
  """
  @spec validate_cutoff_time(killmail(), DateTime.t()) :: cutoff_result()
  def validate_cutoff_time(killmail, cutoff_time) when is_map(killmail) do
    case extract_killmail_time(killmail) do
      {:ok, kill_time} ->
        validate_time_against_cutoff(kill_time, cutoff_time)

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Validates a parsed DateTime against a cutoff time.

  ## Parameters
  - `kill_time` - Parsed DateTime from killmail
  - `cutoff_time` - DateTime cutoff threshold

  ## Returns
  - `:ok` - Time passes cutoff validation
  - `{:error, error}` - Time is older than cutoff
  """
  @spec validate_time_against_cutoff(DateTime.t(), DateTime.t()) :: cutoff_result()
  def validate_time_against_cutoff(kill_time, cutoff_time) do
    if DateTime.compare(kill_time, cutoff_time) == :lt do
      {:error,
       Error.killmail_error(
         :kill_too_old,
         "Killmail is older than cutoff time",
         false,
         %{
           kill_time: DateTime.to_iso8601(kill_time),
           cutoff: DateTime.to_iso8601(cutoff_time),
           age_hours: calculate_age_hours(kill_time, DateTime.utc_now())
         }
       )}
    else
      :ok
    end
  end

  # ============================================================================
  # Time Range and Age Calculations
  # ============================================================================

  @doc """
  Generates a cutoff DateTime for the specified number of hours ago.

  ## Parameters
  - `hours` - Number of hours to subtract from current time (default: 24)

  ## Returns
  - DateTime representing the cutoff time

  ## Examples

  ```elixir
  cutoff = generate_cutoff_time(6)  # 6 hours ago
  cutoff = generate_cutoff_time()   # 24 hours ago (default)
  ```
  """
  @spec generate_cutoff_time(non_neg_integer()) :: DateTime.t()
  def generate_cutoff_time(hours \\ @default_cutoff_hours)
      when is_integer(hours) and hours >= 0 do
    DateTime.utc_now()
    |> DateTime.add(-hours * 3600, :second)
  end

  @doc """
  Calculates the age of a killmail in hours.

  ## Parameters
  - `kill_time` - DateTime of the killmail
  - `reference_time` - Reference DateTime (default: current time)

  ## Returns
  - Age in hours as a float
  """
  @spec calculate_age_hours(DateTime.t(), DateTime.t()) :: float()
  def calculate_age_hours(kill_time, reference_time \\ DateTime.utc_now()) do
    DateTime.diff(reference_time, kill_time, :second) / 3600
  end

  @doc """
  Checks if a time is within the recent threshold.

  ## Parameters
  - `time` - DateTime to check
  - `opts` - Options including `:hours` threshold (default: 5)

  ## Returns
  - `true` if time is recent, `false` otherwise
  """
  @spec recent?(DateTime.t(), keyword()) :: boolean()
  def recent?(time, opts \\ []) do
    threshold_hours = Keyword.get(opts, :hours, @default_recent_threshold_hours)
    age_hours = calculate_age_hours(time)
    age_hours <= threshold_hours
  end

  # ============================================================================
  # System Fetch Time Validation
  # ============================================================================

  @doc """
  Checks if a system was fetched recently enough.

  Used to determine if system data is fresh enough for processing
  without requiring a new fetch operation.

  ## Parameters
  - `system_id` - System ID to check
  - `opts` - Options including `:hours` threshold

  ## Returns
  - `true` if system was fetched recently, `false` otherwise
  """
  @spec is_recent_fetch?(integer(), keyword()) :: boolean()
  def is_recent_fetch?(system_id, opts \\ []) when is_integer(system_id) do
    threshold_hours = Keyword.get(opts, :hours, @default_recent_threshold_hours)

    case Cache.get(:systems, system_id) do
      {:ok, system_data} when is_map(system_data) ->
        check_last_fetched_timestamp(system_data, threshold_hours)

      _ ->
        false
    end
  end

  defp check_last_fetched_timestamp(system_data, threshold_hours) do
    case Map.get(system_data, "last_fetched") do
      nil ->
        false

      timestamp when is_binary(timestamp) ->
        check_timestamp_recency(timestamp, threshold_hours)

      _ ->
        false
    end
  end

  defp check_timestamp_recency(timestamp, threshold_hours) do
    case parse_killmail_time(timestamp) do
      {:ok, fetch_time} -> recent?(fetch_time, hours: threshold_hours)
      {:error, _} -> false
    end
  end

  # ============================================================================
  # Time Range Filtering
  # ============================================================================

  @doc """
  Filters a list of killmails by time range.

  ## Parameters
  - `killmails` - List of killmails to filter
  - `start_time` - Earliest allowed time (inclusive)
  - `end_time` - Latest allowed time (inclusive)

  ## Returns
  - `{:ok, filtered_killmails}` - Successfully filtered list
  - `{:error, reason}` - Filtering failed
  """
  @spec filter_by_time_range([killmail()], DateTime.t(), DateTime.t()) ::
          {:ok, [killmail()]} | {:error, term()}
  def filter_by_time_range(killmails, start_time, end_time)
      when is_list(killmails) do
    filtered =
      Enum.filter(killmails, fn killmail ->
        case extract_killmail_time(killmail) do
          {:ok, kill_time} ->
            DateTime.compare(kill_time, start_time) != :lt and
              DateTime.compare(kill_time, end_time) != :gt

          {:error, _} ->
            false
        end
      end)

    {:ok, filtered}
  rescue
    error ->
      Logger.warning("Failed to filter killmails by time range",
        error: Exception.format(:error, error, __STACKTRACE__),
        start_time: start_time,
        end_time: end_time
      )

      {:error, error}
  end

  @doc """
  Filters killmails to only include those within the specified hours.

  ## Parameters
  - `killmails` - List of killmails to filter  
  - `hours` - Number of hours back to include (default: 24)

  ## Returns
  - `{:ok, filtered_killmails}` - Recent killmails only
  - `{:error, reason}` - Filtering failed
  """
  @spec filter_recent_killmails([killmail()], non_neg_integer()) ::
          {:ok, [killmail()]} | {:error, term()}
  def filter_recent_killmails(killmails, hours \\ @default_cutoff_hours) do
    cutoff_time = generate_cutoff_time(hours)
    end_time = DateTime.utc_now()
    filter_by_time_range(killmails, cutoff_time, end_time)
  end

  # ============================================================================
  # Private Helper Functions
  # ============================================================================

  # Determines the type of a value for error reporting
  defp typeof(value) when is_map(value), do: :map
  defp typeof(value) when is_list(value), do: :list
  defp typeof(value) when is_binary(value), do: :string
  defp typeof(value) when is_integer(value), do: :integer
  defp typeof(value) when is_float(value), do: :float
  defp typeof(value) when is_boolean(value), do: :boolean
  defp typeof(value) when is_atom(value), do: :atom
  defp typeof(_), do: :unknown
end
