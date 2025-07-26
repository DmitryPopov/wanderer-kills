defmodule WandererKills.Http.Client do
  @moduledoc """
  Consolidated HTTP client for all WandererKills HTTP operations.

  This module provides a single, clean interface for HTTP requests with:
  - Built-in timeouts and retries
  - Telemetry integration
  - Rate limiting support via SmartRateLimiter
  - ESI and ZKB specific helpers

  All HTTP requests in the application should go through this module.
  """

  require Logger

  alias WandererKills.Core.Support.Error
  alias WandererKills.Ingest.SmartRateLimiter

  # Configuration
  @default_timeout_ms 30_000
  @user_agent "(wanderer-kills@proton.me; +https://github.com/wanderer-industries/wanderer-kills)"

  # ESI specific timeouts
  @esi_timeout_ms Application.compile_env(:wanderer_kills, [:esi, :request_timeout_ms], 30_000)
  @zkb_timeout_ms Application.compile_env(:wanderer_kills, [:zkb, :request_timeout_ms], 15_000)

  @type url :: String.t()
  @type headers :: [{String.t(), String.t()}]
  @type options :: keyword()
  @type response :: {:ok, map()} | {:error, term()}

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Performs a GET request with rate limiting.
  """
  @spec get(url, headers, options) :: response
  def get(url, headers \\ [], options \\ []) do
    # Check if we should use rate limiting
    if should_rate_limit?(url) do
      get_with_rate_limit(url, headers, options)
    else
      do_get(url, headers, options)
    end
  end

  @doc """
  Performs a GET request with explicit rate limiting.
  """
  @spec get_with_rate_limit(url, headers, options) :: response
  def get_with_rate_limit(url, headers \\ [], options \\ []) do
    if Application.get_env(:wanderer_kills, :features)[:smart_rate_limiting] do
      case SmartRateLimiter.check_rate_limit(url) do
        :ok ->
          do_get(url, headers, options)

        {:error, :rate_limited} ->
          {:error, Error.http_error(:rate_limited, "Rate limit exceeded for #{url}", true)}
      end
    else
      # Rate limiting disabled, proceed directly
      do_get(url, headers, options)
    end
  end

  @doc """
  Performs a POST request.
  """
  @spec post(url, body :: term(), headers, options) :: response
  def post(url, body, headers \\ [], options \\ []) do
    # Add content-type header if not present
    headers = ensure_content_type(headers)
    do_post(url, body, headers, options)
  end

  @doc """
  GET request specifically for ESI endpoints with ESI-specific configuration.
  """
  @spec get_esi(url, headers, options) :: response
  def get_esi(url, headers \\ [], options \\ []) do
    options = Keyword.put_new(options, :timeout, @esi_timeout_ms)
    get_with_rate_limit(url, headers, options)
  end

  @doc """
  GET request specifically for zKillboard endpoints.
  """
  @spec get_zkb(url, headers, options) :: response
  def get_zkb(url, headers \\ [], options \\ []) do
    options = Keyword.put_new(options, :timeout, @zkb_timeout_ms)
    get_with_rate_limit(url, headers, options)
  end

  # ============================================================================
  # Private Implementation
  # ============================================================================

  defp do_get(url, headers, options) do
    Logger.debug("[HTTP] GET #{url}")

    timeout = Keyword.get(options, :timeout, @default_timeout_ms)
    headers = build_headers(headers)

    # Build Finch request
    request = Finch.build(:get, url, headers)

    # Get the Finch instance to use
    finch_name = get_finch_name()

    # Perform the request
    start_time = System.monotonic_time(:millisecond)

    result =
      case Finch.request(request, finch_name, receive_timeout: timeout) do
        {:ok, %Finch.Response{status: status, body: body, headers: resp_headers}} ->
          elapsed = System.monotonic_time(:millisecond) - start_time
          Logger.debug("[HTTP] Response #{status} in #{elapsed}ms")

          # Parse JSON if content-type indicates it
          parsed_body = maybe_parse_json(body, resp_headers)

          handle_response(status, parsed_body, resp_headers)

        {:error, %{reason: :timeout}} ->
          {:error, Error.http_error(:timeout, "Request to #{url} timed out", true)}

        {:error, %{reason: :econnrefused}} ->
          {:error, Error.http_error(:connection_failed, "Connection refused for #{url}", true)}

        {:error, reason} ->
          Logger.error("[HTTP] Request failed: #{inspect(reason)}")
          {:error, Error.http_error(:request_failed, "Request failed: #{inspect(reason)}", false)}
      end

    # Emit telemetry
    emit_telemetry(url, start_time, result)

    result
  end

  defp do_post(url, body, headers, options) do
    Logger.debug("[HTTP] POST #{url}")

    timeout = Keyword.get(options, :timeout, @default_timeout_ms)
    headers = build_headers(headers)

    # Encode body as JSON if it's not already a string
    encoded_body =
      case body do
        body when is_binary(body) -> body
        _ -> Jason.encode!(body)
      end

    # Build Finch request
    request = Finch.build(:post, url, headers, encoded_body)

    # Get the Finch instance to use
    finch_name = get_finch_name()

    # Perform the request
    start_time = System.monotonic_time(:millisecond)

    result =
      case Finch.request(request, finch_name, receive_timeout: timeout) do
        {:ok, %Finch.Response{status: status, body: resp_body, headers: resp_headers}} ->
          elapsed = System.monotonic_time(:millisecond) - start_time
          Logger.debug("[HTTP] Response #{status} in #{elapsed}ms")

          # Parse JSON if content-type indicates it
          parsed_body = maybe_parse_json(resp_body, resp_headers)

          handle_response(status, parsed_body, resp_headers)

        {:error, reason} ->
          Logger.error("[HTTP] POST request failed: #{inspect(reason)}")

          {:error,
           Error.http_error(:request_failed, "POST request failed: #{inspect(reason)}", false)}
      end

    # Emit telemetry
    emit_telemetry(url, start_time, result)

    result
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp get_finch_name do
    # Use WandererKills.Finch if available, otherwise fall back to default
    if Process.whereis(WandererKills.Finch) do
      WandererKills.Finch
    else
      # In test environment, use a test-specific Finch
      if Application.get_env(:wanderer_kills, :env) == :test do
        WandererKills.Test.Finch
      else
        # Fallback - this shouldn't happen in normal operation
        raise "No Finch instance available!"
      end
    end
  end

  defp should_rate_limit?(url) do
    # Rate limit external APIs (ESI, zKillboard)
    String.contains?(url, "esi.evetech.net") or
      String.contains?(url, "zkillboard.com") or
      String.contains?(url, "zkillredisq.stream")
  end

  defp build_headers(headers) do
    # Add default headers
    default_headers = [
      {"user-agent", @user_agent},
      {"accept", "application/json"}
    ]

    # Merge with provided headers (provided headers take precedence)
    Enum.uniq_by(headers ++ default_headers, fn {key, _} -> String.downcase(key) end)
  end

  defp ensure_content_type(headers) do
    if Enum.any?(headers, fn {k, _} -> String.downcase(k) == "content-type" end) do
      headers
    else
      [{"content-type", "application/json"} | headers]
    end
  end

  defp maybe_parse_json(body, headers) do
    content_type =
      Enum.find_value(headers, fn
        {key, value} when is_binary(key) ->
          if String.downcase(key) == "content-type", do: value

        _ ->
          nil
      end)

    if content_type && String.contains?(content_type, "application/json") do
      case Jason.decode(body) do
        {:ok, parsed} -> parsed
        {:error, _} -> body
      end
    else
      body
    end
  end

  defp handle_response(status, body, headers) when status >= 200 and status < 300 do
    {:ok, %{status: status, body: body, headers: headers}}
  end

  defp handle_response(404, body, _headers) do
    {:error, Error.not_found_error("Resource not found", %{body: body})}
  end

  defp handle_response(429, body, headers) do
    # Extract retry-after header if present
    retry_after =
      Enum.find_value(headers, fn
        {"retry-after", value} -> value
        {"x-esi-error-limit-remain", value} -> value
        _ -> nil
      end)

    {:error,
     Error.rate_limit_error("Rate limit exceeded", %{body: body, retry_after: retry_after})}
  end

  defp handle_response(status, body, _headers) when status >= 400 and status < 500 do
    {:error,
     Error.http_error(:client_error, "Client error: #{status}", false, %{
       status: status,
       body: body
     })}
  end

  defp handle_response(status, body, _headers) when status >= 500 do
    {:error,
     Error.http_error(:server_error, "Server error: #{status}", true, %{
       status: status,
       body: body
     })}
  end

  defp handle_response(status, body, _headers) do
    {:error,
     Error.http_error(:unknown_status, "Unknown status: #{status}", false, %{
       status: status,
       body: body
     })}
  end

  defp emit_telemetry(url, start_time, result) do
    duration = System.monotonic_time(:millisecond) - start_time

    metadata = %{
      url: url,
      duration_ms: duration,
      status:
        case result do
          {:ok, %{status: status}} -> status
          _ -> nil
        end,
      error:
        case result do
          {:error, error} -> error
          _ -> nil
        end
    }

    :telemetry.execute(
      [:wanderer_kills, :http, :request],
      %{duration: duration},
      metadata
    )
  end
end
