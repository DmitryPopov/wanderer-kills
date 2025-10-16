defmodule WandererKills.Core.Support.Utils do
  @moduledoc """
  Consolidated utility functions for WandererKills.

  This module combines commonly used utilities that were previously spread
  across Clock, Retry, and PubSubTopics modules. The goal is to reduce the
  number of small single-purpose modules while maintaining clear organization.

  ## Included Utilities

  - **Time Operations** (formerly Clock)
    - Current time functions
    - Relative time calculations
    - Killmail time parsing and validation

  - **Retry Logic** (formerly Retry)
    - Exponential backoff implementation
    - Retryable error detection
    - HTTP operation retry helpers

  - **PubSub Topics** (formerly PubSubTopics)
    - Topic name generation
    - Topic validation
    - System ID extraction
  """

  require Logger
  alias WandererKills.Core.Support.Error

  # ============================================================================
  # Time Operations (formerly Clock)
  # ============================================================================

  @type killmail :: map()
  @type time_result :: {:ok, DateTime.t()} | {:error, term()}
  @type validation_result :: {:ok, {killmail(), DateTime.t()}} | :older | :skip

  @doc """
  Returns the current `DateTime` in UTC.
  """
  @spec now() :: DateTime.t()
  def now do
    DateTime.utc_now()
  end

  @doc """
  Returns the current time in **milliseconds** since Unix epoch.
  """
  @spec now_milliseconds() :: integer()
  def now_milliseconds do
    System.system_time(:millisecond)
  end

  @doc """
  Returns the current time as an ISO8601 string.
  """
  @spec now_iso8601() :: String.t()
  def now_iso8601 do
    now() |> DateTime.to_iso8601()
  end

  @doc """
  Returns a `DateTime` that is `seconds` seconds before the current `now()`.
  """
  @spec seconds_ago(non_neg_integer()) :: DateTime.t()
  def seconds_ago(seconds) do
    now() |> DateTime.add(-seconds, :second)
  end

  @doc """
  Returns a `DateTime` that is `hours` hours before the current `now()`.
  """
  @spec hours_ago(non_neg_integer()) :: DateTime.t()
  def hours_ago(hours) do
    now() |> DateTime.add(-hours * 3_600, :second)
  end

  @doc """
  Converts a DateTime to Unix timestamp in milliseconds.
  """
  @spec to_unix(DateTime.t()) :: integer()
  def to_unix(%DateTime{} = dt) do
    DateTime.to_unix(dt, :millisecond)
  end

  @doc """
  Gets the killmail time from any supported format.
  Returns `{:ok, DateTime.t()}` or `{:error, reason}`.
  """
  @spec get_killmail_time(killmail()) :: time_result()
  def get_killmail_time(%{"killmail_time" => value}), do: parse_time(value)
  def get_killmail_time(%{"killTime" => value}), do: parse_time(value)
  def get_killmail_time(%{"zkb" => %{"time" => value}}), do: parse_time(value)

  def get_killmail_time(_),
    do: {:error, Error.time_error(:missing_time, "No time field found in killmail")}

  @doc """
  Parses a time value from various formats into a DateTime.
  """
  @spec parse_time(String.t() | DateTime.t() | any()) :: time_result()
  def parse_time(dt) when is_struct(dt, DateTime), do: {:ok, dt}

  def parse_time(time_str) when is_binary(time_str) do
    case DateTime.from_iso8601(time_str) do
      {:ok, dt, _offset} ->
        {:ok, DateTime.shift_zone!(dt, "Etc/UTC")}

      {:error, :invalid_format} ->
        case NaiveDateTime.from_iso8601(time_str) do
          {:ok, ndt} ->
            {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}

          error ->
            Logger.warning("[Utils] Failed to parse time: #{time_str}, error: #{inspect(error)}")
            error
        end

      error ->
        Logger.warning("[Utils] Failed to parse time: #{time_str}, error: #{inspect(error)}")
        error
    end
  end

  def parse_time(_), do: {:error, Error.time_error(:invalid_time_format, "Invalid time format")}

  @doc """
  Validates and attaches a killmail's timestamp against a cutoff.
  Returns:
    - `{:ok, {km_with_time, dt}}` if valid
    - `:older` if timestamp is before cutoff
    - `:skip` if timestamp is missing or unparseable
  """
  @spec validate_killmail_time(killmail(), DateTime.t()) :: validation_result()
  def validate_killmail_time(km, cutoff_dt) do
    case get_killmail_time(km) do
      {:ok, km_dt} ->
        if DateTime.compare(km_dt, cutoff_dt) == :lt do
          :older
        else
          km_with_time = Map.put(km, "killmail_time", km_dt)
          {:ok, {km_with_time, km_dt}}
        end

      {:error, reason} ->
        Logger.warning(
          "[Utils] Failed to parse time for killmail #{inspect(Map.get(km, "killmail_id"))}: #{inspect(reason)}"
        )

        :skip
    end
  end

  # ============================================================================
  # Retry Operations (formerly Retry)
  # ============================================================================

  # Compile-time configuration
  @http_max_retries Application.compile_env(:wanderer_kills, [:http, :retry, :max_retries], 3)
  @http_base_delay Application.compile_env(:wanderer_kills, [:http, :retry, :base_delay], 1_000)
  @http_max_delay Application.compile_env(:wanderer_kills, [:http, :retry, :max_delay], 30_000)

  @type retry_opts :: [
          max_retries: non_neg_integer(),
          base_delay: non_neg_integer(),
          max_delay: non_neg_integer(),
          rescue_only: [module()],
          operation_name: String.t()
        ]

  @doc """
  Retries a function with exponential backoff.

  ## Parameters
    - `fun` - A zero-arity function that either returns a value or raises one of the specified errors
    - `opts` - Retry options:
      - `:max_retries` - Maximum number of retry attempts (default: 3)
      - `:base_delay` - Initial delay in milliseconds (default: 1000)
      - `:max_delay` - Maximum delay in milliseconds (default: 30000)
      - `:rescue_only` - List of exception types to retry on (default: network/service errors only)
      - `:operation_name` - Name for logging purposes (default: "operation")

  ## Returns
    - `{:ok, result}` on successful execution
    - `{:error, :max_retries_exceeded}` when max retries are reached
  """
  @spec retry_with_backoff((-> term()), retry_opts()) :: {:ok, term()} | {:error, term()}
  def retry_with_backoff(fun, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, @http_max_retries)
    base_delay = Keyword.get(opts, :base_delay, @http_base_delay)
    max_delay = Keyword.get(opts, :max_delay, @http_max_delay)
    operation_name = Keyword.get(opts, :operation_name, "operation")

    rescue_only =
      Keyword.get(opts, :rescue_only, [
        WandererKills.Core.Support.Error.ConnectionError,
        WandererKills.Core.Support.Error.TimeoutError,
        WandererKills.Core.Support.Error.RateLimitError
      ])

    # Create an Erlang backoff state: init(StartDelay, MaxDelay)
    backoff_state = :backoff.init(base_delay, max_delay)

    do_retry(fun, max_retries, backoff_state, rescue_only, operation_name)
  end

  @spec do_retry((-> term()), non_neg_integer(), :backoff.backoff(), [module()], String.t()) ::
          {:ok, term()} | {:error, term()}
  defp do_retry(_fun, 0, _backoff_state, _rescue_only, operation_name) do
    Logger.error("#{operation_name} failed after exhausting all retry attempts")

    {:error,
     Error.system_error(
       :max_retries_exceeded,
       "#{operation_name} failed after exhausting all retry attempts",
       false
     )}
  end

  defp do_retry(fun, retries_left, backoff_state, rescue_only, operation_name) do
    fun.()
  rescue
    error ->
      if error.__struct__ in rescue_only do
        # Each time we fail, we call :backoff.fail/1 → {delay_ms, next_backoff}
        {delay_ms, next_backoff} = :backoff.fail(backoff_state)

        Logger.warning(
          "#{operation_name} failed with retryable error: #{inspect(error)}. " <>
            "Retrying in #{delay_ms}ms (#{retries_left - 1} attempts left)."
        )

        Process.sleep(delay_ms)
        do_retry(fun, retries_left - 1, next_backoff, rescue_only, operation_name)
      else
        # Not one of our listed retriable errors: bubble up immediately
        Logger.error("#{operation_name} failed with non-retryable error: #{inspect(error)}")
        reraise(error, __STACKTRACE__)
      end
  end

  @doc """
  Convenience function for retrying HTTP operations with sensible defaults.
  """
  @spec retry_http_operation((-> term()), retry_opts()) :: {:ok, term()} | {:error, term()}
  def retry_http_operation(fun, opts \\ []) do
    default_opts = [
      operation_name: "HTTP request",
      rescue_only: [
        WandererKills.Core.Support.Error.ConnectionError,
        WandererKills.Core.Support.Error.TimeoutError,
        WandererKills.Core.Support.Error.RateLimitError
      ]
    ]

    merged_opts = Keyword.merge(default_opts, opts)
    retry_with_backoff(fun, merged_opts)
  end

  # ============================================================================
  # PubSub Topics (formerly PubSubTopics)
  # ============================================================================

  @doc """
  Builds a system-level topic name for basic killmail updates.

  ## Examples
      iex> WandererKills.Core.Support.Utils.system_topic(30000142)
      "zkb:system:30000142"
  """
  @spec system_topic(integer()) :: String.t()
  def system_topic(system_id) when is_integer(system_id) do
    "zkb:system:#{system_id}"
  end

  @doc """
  Builds a detailed system-level topic name for enhanced killmail updates.

  ## Examples
      iex> WandererKills.Core.Support.Utils.system_detailed_topic(30000142)
      "zkb:system:30000142:detailed"
  """
  @spec system_detailed_topic(integer()) :: String.t()
  def system_detailed_topic(system_id) when is_integer(system_id) do
    "zkb:system:#{system_id}:detailed"
  end

  @doc """
  Returns both system topics for a given system ID.

  This is useful when you need to subscribe/unsubscribe from both
  basic and detailed topics for the same system.

  ## Examples
      iex> WandererKills.Core.Support.Utils.system_topics(30000142)
      ["zkb:system:30000142", "zkb:system:30000142:detailed"]
  """
  @spec system_topics(integer()) :: [String.t()]
  def system_topics(system_id) when is_integer(system_id) do
    [system_topic(system_id), system_detailed_topic(system_id)]
  end

  @doc """
  Returns the topic for all systems killmail updates.
  """
  @spec all_systems_topic() :: String.t()
  def all_systems_topic do
    "zkb:all_systems"
  end

  @doc """
  Validates that a topic follows the expected format.
  """
  @spec valid_system_topic?(String.t()) :: boolean()
  def valid_system_topic?(topic) when is_binary(topic) do
    case topic do
      "zkb:system:" <> rest ->
        case String.split(rest, ":") do
          [system_id] -> valid_system_id?(system_id)
          [system_id, "detailed"] -> valid_system_id?(system_id)
          _ -> false
        end

      _ ->
        false
    end
  end

  def valid_system_topic?(_), do: false

  @doc """
  Extracts the system ID from a system topic.

  Returns `{:ok, system_id}` if successful, `{:error, :invalid_topic}` otherwise.
  """
  @spec extract_system_id(String.t()) :: {:ok, integer()} | {:error, :invalid_topic}
  def extract_system_id(topic) when is_binary(topic) do
    case topic do
      "zkb:system:" <> rest ->
        case String.split(rest, ":") do
          [system_id_str] ->
            parse_system_id(system_id_str)

          [system_id_str, "detailed"] ->
            parse_system_id(system_id_str)

          _ ->
            {:error, :invalid_topic}
        end

      _ ->
        {:error, :invalid_topic}
    end
  end

  def extract_system_id(_), do: {:error, :invalid_topic}

  # Private helper functions

  defp valid_system_id?(system_id_str) do
    case Integer.parse(system_id_str) do
      {system_id, ""} when system_id > 0 -> true
      _ -> false
    end
  end

  defp parse_system_id(system_id_str) do
    case Integer.parse(system_id_str) do
      {system_id, ""} when system_id > 0 -> {:ok, system_id}
      _ -> {:error, :invalid_topic}
    end
  end
end
