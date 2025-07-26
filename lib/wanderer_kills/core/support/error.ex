defmodule WandererKills.Core.Support.Error do
  @moduledoc """
  Centralized error handling for WandererKills.

  This module provides a unified error structure and helper functions for all
  error handling across the application, replacing disparate error tuple patterns
  with a consistent approach.

  ## Error Structure

  All errors have a standardized format with:
  - `domain` - Which part of the system generated the error
  - `type` - Specific error type within the domain
  - `message` - Human-readable error message
  - `details` - Additional error context (optional)
  - `retryable` - Whether the operation can be retried

  ## Usage

  ```elixir
  # Preferred: Using the generic constructor
  {:error, Error.new(:http, :timeout, "Request timed out", true)}
  {:error, Error.new(:cache, :miss, "Cache key not found")}
  {:error, Error.new(:killmail, :invalid_format, "Missing required fields")}

  # Alternative: Using domain-specific helpers (backward compatibility)
  {:error, Error.http_error(:timeout, "Request timed out", true)}
  {:error, Error.cache_error(:miss, "Cache key not found")}

  # Checking if error is retryable
  if Error.retryable?(error) do
    retry_operation()
  end

  # Common error patterns
  Error.not_found_error("Resource not found")
  Error.timeout_error("Operation timed out")
  ```
  """

  defstruct [:domain, :type, :message, :details, :retryable]

  @type domain ::
          :http
          | :cache
          | :killmail
          | :system
          | :esi
          | :zkb
          | :parsing
          | :enrichment
          | :redis_q
          | :ship_types
          | :validation
          | :config
          | :time
          | :csv
  @type error_type :: atom()
  @type details :: map() | nil

  @type t :: %__MODULE__{
          domain: domain(),
          type: error_type(),
          message: String.t(),
          details: details(),
          retryable: boolean()
        }

  # ============================================================================
  # Constructor Functions
  # ============================================================================

  @doc """
  Creates a new error with the specified domain.

  This is the main constructor for all errors. Domain-specific convenience
  functions are provided for backward compatibility.

  ## Parameters
  - `domain` - Error domain (:http, :cache, :killmail, etc.)
  - `type` - Specific error type within the domain
  - `message` - Human-readable error message
  - `retryable` - Whether the operation can be retried (default: false)
  - `details` - Additional error context (default: nil)
  """
  @spec new(domain(), error_type(), String.t(), boolean(), details()) :: t()
  def new(domain, type, message, retryable \\ false, details \\ nil) do
    %__MODULE__{
      domain: domain,
      type: type,
      message: message,
      details: details,
      retryable: retryable
    }
  end

  # Domain-specific convenience functions for backward compatibility
  @doc "Creates an HTTP-related error"
  @spec http_error(error_type(), String.t(), boolean(), details()) :: t()
  def http_error(type, message, retryable \\ false, details \\ nil),
    do: new(:http, type, message, retryable, details)

  @doc "Creates a cache-related error"
  @spec cache_error(error_type(), String.t(), details()) :: t()
  def cache_error(type, message, details \\ nil),
    do: new(:cache, type, message, false, details)

  @doc "Creates a killmail processing error"
  @spec killmail_error(error_type(), String.t(), boolean(), details()) :: t()
  def killmail_error(type, message, retryable \\ false, details \\ nil),
    do: new(:killmail, type, message, retryable, details)

  @doc "Creates a system-related error"
  @spec system_error(error_type(), String.t(), boolean(), details()) :: t()
  def system_error(type, message, retryable \\ false, details \\ nil),
    do: new(:system, type, message, retryable, details)

  @doc "Creates an ESI API error"
  @spec esi_error(error_type(), String.t(), boolean(), details()) :: t()
  def esi_error(type, message, retryable \\ false, details \\ nil),
    do: new(:esi, type, message, retryable, details)

  @doc "Creates a zKillboard API error"
  @spec zkb_error(error_type(), String.t(), boolean(), details()) :: t()
  def zkb_error(type, message, retryable \\ false, details \\ nil),
    do: new(:zkb, type, message, retryable, details)

  @doc "Creates a parsing error"
  @spec parsing_error(error_type(), String.t(), details()) :: t()
  def parsing_error(type, message, details \\ nil),
    do: new(:parsing, type, message, false, details)

  @doc "Creates an enrichment error"
  @spec enrichment_error(error_type(), String.t(), boolean(), details()) :: t()
  def enrichment_error(type, message, retryable \\ false, details \\ nil),
    do: new(:enrichment, type, message, retryable, details)

  @doc "Creates a RedisQ error"
  @spec redisq_error(error_type(), String.t(), boolean(), details()) :: t()
  def redisq_error(type, message, retryable \\ true, details \\ nil),
    do: new(:redis_q, type, message, retryable, details)

  @doc "Creates a ship types error"
  @spec ship_types_error(error_type(), String.t(), boolean(), details()) :: t()
  def ship_types_error(type, message, retryable \\ false, details \\ nil),
    do: new(:ship_types, type, message, retryable, details)

  @doc "Creates a validation error"
  @spec validation_error(error_type(), String.t(), details()) :: t()
  def validation_error(type, message, details \\ nil),
    do: new(:validation, type, message, false, details)

  @doc "Creates a configuration error"
  @spec config_error(error_type(), String.t(), details()) :: t()
  def config_error(type, message, details \\ nil),
    do: new(:config, type, message, false, details)

  @doc "Creates a time processing error"
  @spec time_error(error_type(), String.t(), details()) :: t()
  def time_error(type, message, details \\ nil),
    do: new(:time, type, message, false, details)

  @doc "Creates a CSV processing error"
  @spec csv_error(error_type(), String.t(), details()) :: t()
  def csv_error(type, message, details \\ nil),
    do: new(:csv, type, message, false, details)

  # ============================================================================
  # Utility Functions
  # ============================================================================

  @doc "Checks if an error is retryable"
  @spec retryable?(t()) :: boolean()
  def retryable?(%__MODULE__{retryable: retryable}), do: retryable

  @doc "Gets the error domain"
  @spec domain(t()) :: domain()
  def domain(%__MODULE__{domain: domain}), do: domain

  @doc "Gets the error type"
  @spec type(t()) :: error_type()
  def type(%__MODULE__{type: type}), do: type

  @doc "Gets the error message"
  @spec message(t()) :: String.t()
  def message(%__MODULE__{message: message}), do: message

  @doc "Gets the error details"
  @spec details(t()) :: details()
  def details(%__MODULE__{details: details}), do: details

  @doc "Converts an error to a string representation"
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{domain: domain, type: type, message: message}) do
    "[#{domain}:#{type}] #{message}"
  end

  @doc "Converts an error to a map for serialization"
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = error) do
    %{
      domain: error.domain,
      type: error.type,
      message: error.message,
      details: error.details,
      retryable: error.retryable
    }
  end

  # ============================================================================
  # Error Standardization Functions
  # ============================================================================

  @doc """
  Converts common atom errors to standardized Error structs.

  This function helps migrate legacy error returns to the new standard.
  """
  @spec standardize_error(atom() | {atom(), term()} | term()) :: t()
  def standardize_error(:not_found), do: not_found_error()
  def standardize_error(:timeout), do: timeout_error()
  def standardize_error(:invalid_format), do: invalid_format_error()
  def standardize_error(:rate_limited), do: rate_limit_error()
  def standardize_error(:connection_failed), do: connection_error()

  def standardize_error({:not_found, details}) when is_binary(details) do
    not_found_error(details)
  end

  def standardize_error({:timeout, details}) when is_binary(details) do
    timeout_error(details)
  end

  def standardize_error({:invalid_format, details}) when is_binary(details) do
    invalid_format_error(details)
  end

  def standardize_error(other) do
    system_error(:unknown_error, "Unknown error: #{inspect(other)}")
  end

  @doc """
  Wraps a function result to ensure it returns standardized errors.

  ## Examples

  ```elixir
  # Wrap a function that might return nil
  with_standard_error(fn -> some_function() end, :cache, :miss, "Cache miss")

  # Wrap a function that returns {:error, atom}
  with_standard_error(fn -> legacy_function() end, :http, :request_failed)
  ```
  """
  @spec with_standard_error(
          (-> {:ok, term()} | {:error, term()} | term()),
          domain(),
          error_type(),
          String.t() | nil
        ) :: {:ok, term()} | {:error, t()}
  def with_standard_error(fun, domain, type, message \\ nil) do
    case fun.() do
      {:ok, result} ->
        {:ok, result}

      {:error, %__MODULE__{} = error} ->
        {:error, error}

      {:error, reason} ->
        msg = message || "Operation failed: #{inspect(reason)}"
        {:error, new(domain, type, msg)}

      nil ->
        msg = message || "Operation returned nil"
        {:error, new(domain, type, msg)}

      result ->
        # Assume non-tuple results are successful
        {:ok, result}
    end
  end

  @doc """
  Ensures a function returns {:ok, result} or {:error, %Error{}}.

  Useful for wrapping functions that return bare values or nil.
  """
  @spec ensure_error_tuple(term(), domain(), error_type()) ::
          {:ok, term()} | {:error, t()}
  def ensure_error_tuple(nil, domain, type) do
    {:error, new(domain, type, "Operation returned nil")}
  end

  def ensure_error_tuple({:ok, _} = result, _domain, _type), do: result
  def ensure_error_tuple({:error, %__MODULE__{}} = result, _domain, _type), do: result

  def ensure_error_tuple({:error, reason}, domain, type) do
    {:error, new(domain, type, "Operation failed: #{inspect(reason)}")}
  end

  def ensure_error_tuple(result, _domain, _type) do
    {:ok, result}
  end

  # ============================================================================
  # Common Error Patterns
  # ============================================================================

  @doc "Standard timeout error"
  @spec timeout_error(String.t(), details()) :: t()
  def timeout_error(message \\ "Operation timed out", details \\ nil) do
    http_error(:timeout, message, true, details)
  end

  @doc "Standard not found error"
  @spec not_found_error(String.t(), details()) :: t()
  def not_found_error(message \\ "Resource not found", details \\ nil) do
    system_error(:not_found, message, false, details)
  end

  @doc "Standard invalid format error"
  @spec invalid_format_error(String.t(), details()) :: t()
  def invalid_format_error(message \\ "Invalid data format", details \\ nil) do
    validation_error(:invalid_format, message, details)
  end

  @doc "Standard rate limit error"
  @spec rate_limit_error(String.t(), details()) :: t()
  def rate_limit_error(message \\ "Rate limit exceeded", details \\ nil) do
    http_error(:rate_limited, message, true, details)
  end

  @doc "Standard connection error"
  @spec connection_error(String.t(), details()) :: t()
  def connection_error(message \\ "Connection failed", details \\ nil) do
    http_error(:connection_failed, message, true, details)
  end

  # ============================================================================
  # HTTP Exception Types
  # ============================================================================

  defmodule ConnectionError do
    @moduledoc """
    Error raised when a connection fails.
    """
    defexception [:message]
  end

  defmodule TimeoutError do
    @moduledoc """
    Error raised when a request times out.
    """
    defexception [:message]
  end

  defmodule RateLimitError do
    @moduledoc """
    Error raised when rate limit is exceeded.
    """
    defexception [:message]
  end
end
