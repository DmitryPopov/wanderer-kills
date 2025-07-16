defmodule WandererKills.Test.HttpHelpers do
  @moduledoc """
  Test helper functions for HTTP mocking and testing.

  This module provides utilities for:
  - HTTP client mocking
  - Response generation
  - Request expectations
  - HTTP response assertions
  """

  import ExUnit.Assertions

  @doc """
  Sets up default mocks for HTTP client and other services.
  """
  @spec setup_mocks() :: :ok
  def setup_mocks do
    setup_http_mocks()
    :ok
  end

  @doc """
  Sets up HTTP client mocks with default responses.

  NOTE: This function no longer sets up global stubs. 
  Use explicit expectations in your tests with `expect_http_*` functions.
  """
  @spec setup_http_mocks() :: :ok
  def setup_http_mocks do
    # Configure the application to use the mock HTTP client
    Application.put_env(:wanderer_kills, :http, client: WandererKills.Ingest.Http.Client.Mock)

    # Set up fallback expectations for tests that don't specify their own
    Mox.stub(WandererKills.Ingest.Http.Client.Mock, :get_with_rate_limit, fn _url, _opts ->
      {:error, :not_found}
    end)

    # Set up fallback for POST requests (used by webhooks)
    Mox.stub(WandererKills.Ingest.Http.Client.Mock, :post, fn _url, _body, _opts ->
      {:error, :not_found}
    end)

    Mox.stub(WandererKills.Ingest.Killmails.ZkbClient.Mock, :fetch_killmail, fn _id ->
      {:error, :not_found}
    end)

    Mox.stub(
      WandererKills.Ingest.Killmails.ZkbClient.Mock,
      :fetch_system_killmails,
      fn _system_id, _options ->
        {:ok, []}
      end
    )

    Mox.stub(
      WandererKills.Ingest.Killmails.ZkbClient.Mock,
      :get_system_killmail_count,
      fn _system_id ->
        {:ok, 0}
      end
    )

    :ok
  end

  @doc """
  Creates a mock HTTP response with given status and body.
  """
  @spec mock_http_response(integer(), term()) :: {:ok, map()} | {:error, term()}
  def mock_http_response(status, body \\ nil) do
    case status do
      200 -> {:ok, %{status: 200, body: body || %{}}}
      404 -> {:error, :not_found}
      429 -> {:error, :rate_limited}
      500 -> {:error, :server_error}
      _ -> {:error, "HTTP #{status}"}
    end
  end

  @doc """
  Expects an HTTP request to succeed with specific response body.
  """
  @spec expect_http_success(String.t(), map(), non_neg_integer()) :: :ok
  def expect_http_success(url_pattern, response_body, times \\ 1) do
    Mox.expect(WandererKills.Ingest.Http.Client.Mock, :get_with_rate_limit, times, fn url,
                                                                                      _opts ->
      if String.contains?(url, url_pattern) do
        {:ok, %{status: 200, body: response_body}}
      else
        {:error, :not_found}
      end
    end)

    :ok
  end

  @doc """
  Expects an HTTP request to be rate limited.
  """
  @spec expect_http_rate_limit(String.t(), non_neg_integer(), non_neg_integer()) :: :ok
  def expect_http_rate_limit(url_pattern, _retry_count \\ 3, times \\ 1) do
    Mox.expect(WandererKills.Ingest.Http.Client.Mock, :get_with_rate_limit, times, fn url,
                                                                                      _opts ->
      if String.contains?(url, url_pattern) do
        {:error, :rate_limited}
      else
        {:error, :not_found}
      end
    end)

    :ok
  end

  @doc """
  Expects an HTTP request to fail with specific error.
  """
  @spec expect_http_error(String.t(), atom(), non_neg_integer()) :: :ok
  def expect_http_error(url_pattern, error_type, times \\ 1) do
    Mox.expect(WandererKills.Ingest.Http.Client.Mock, :get_with_rate_limit, times, fn url,
                                                                                      _opts ->
      if String.contains?(url, url_pattern) do
        {:error, error_type}
      else
        {:error, :not_found}
      end
    end)

    :ok
  end

  @doc """
  Expects any HTTP request to return not_found (useful for tests that don't care about HTTP calls).
  """
  @spec expect_http_not_found(non_neg_integer()) :: :ok
  def expect_http_not_found(times \\ 1) do
    Mox.expect(WandererKills.Ingest.Http.Client.Mock, :get_with_rate_limit, times, fn _url,
                                                                                      _opts ->
      {:error, :not_found}
    end)

    :ok
  end

  @doc """
  Asserts that an HTTP response has expected status and body keys.
  """
  @spec assert_http_response(map(), integer(), [String.t()]) :: :ok
  def assert_http_response(response, expected_status, expected_body_keys \\ []) do
    assert %{status: ^expected_status} = response

    if expected_body_keys != [] do
      for key <- expected_body_keys do
        assert Map.has_key?(response.body, key), "Response body missing key: #{key}"
      end
    end

    :ok
  end
end
