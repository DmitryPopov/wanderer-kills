defmodule WandererKills.Ingest.Killmails.ZkbClientTest do
  use WandererKills.DataCase, async: false
  import Mox

  @moduletag :external

  alias WandererKills.Http.ClientMock, as: HttpClientMock
  alias WandererKills.Ingest.Killmails.ZkbClient, as: ZKB

  # Get base URL from config
  @base_url Application.compile_env(:wanderer_kills, :zkb)[:base_url]

  setup do
    # Configure the HTTP client to use the mock
    Application.put_env(:wanderer_kills, :http, client: WandererKills.Http.ClientMock)

    on_exit(fn ->
      # Reset to default
      Application.delete_env(:wanderer_kills, :http)
    end)

    :ok
  end

  describe "fetch_killmail/1" do
    test "successfully fetches a killmail" do
      killmail_id = 123_456
      killmail = TestHelpers.generate_test_data(:killmail, killmail_id)

      HttpClientMock
      |> expect(:get_zkb, fn
        "#{@base_url}/killID/123456/", _headers, _opts ->
          {:ok, %{status: 200, body: [killmail]}}
      end)

      assert {:ok, ^killmail} = ZKB.fetch_killmail(killmail_id)
    end

    test "handles killmail not found (nil response)" do
      killmail_id = 999_999

      HttpClientMock
      |> expect(:get_zkb, fn
        "#{@base_url}/killID/999999/", _headers, _opts ->
          {:ok, %{status: 200, body: []}}
      end)

      assert {:error, error} = ZKB.fetch_killmail(killmail_id)
      assert error.domain == :zkb
      assert error.type == :not_found
      assert String.contains?(error.message, "not found")
    end

    test "handles client errors" do
      killmail_id = 123_456

      HttpClientMock
      |> expect(:get_zkb, fn
        "#{@base_url}/killID/123456/", _headers, _opts ->
          {:error, :rate_limited}
      end)

      assert {:error, :rate_limited} = ZKB.fetch_killmail(killmail_id)
    end

    test "validates killmail ID format" do
      assert {:error, error} = ZKB.fetch_killmail("invalid")
      assert error.domain == :validation
      assert String.contains?(error.message, "Invalid killmail ID format")
    end

    test "validates positive killmail ID" do
      assert {:error, error} = ZKB.fetch_killmail(-1)
      assert error.domain == :validation
    end
  end

  describe "fetch_system_killmails/2" do
    test "successfully fetches system killmails" do
      system_id = 30_000_142
      killmail1 = TestHelpers.generate_test_data(:killmail, 123)
      killmail2 = TestHelpers.generate_test_data(:killmail, 456)
      killmails = [killmail1, killmail2]

      HttpClientMock
      |> expect(:get_zkb, fn
        "#{@base_url}/systemID/30000142/", _headers, _opts ->
          {:ok, %{status: 200, body: killmails}}
      end)

      # Using new API with options
      assert {:ok, ^killmails} =
               ZKB.fetch_system_killmails(system_id, limit: 10, past_seconds: 86_400)
    end

    test "successfully fetches system killmails without options" do
      system_id = 30_000_142
      killmail1 = TestHelpers.generate_test_data(:killmail, 123)
      killmail2 = TestHelpers.generate_test_data(:killmail, 456)
      killmails = [killmail1, killmail2]

      HttpClientMock
      |> expect(:get_zkb, fn
        "#{@base_url}/systemID/30000142/", _headers, _opts ->
          {:ok, %{status: 200, body: killmails}}
      end)

      # Using new API without options
      assert {:ok, ^killmails} = ZKB.fetch_system_killmails(system_id)
    end

    test "handles empty killmail list" do
      system_id = 30_000_142

      HttpClientMock
      |> expect(:get_zkb, fn
        "#{@base_url}/systemID/30000142/", _headers, _opts ->
          {:ok, %{status: 200, body: []}}
      end)

      assert {:ok, []} = ZKB.fetch_system_killmails(system_id, [])
    end

    test "handles client errors" do
      system_id = 30_000_142

      HttpClientMock
      |> expect(:get_zkb, fn
        "#{@base_url}/systemID/30000142/", _headers, _opts ->
          {:error, :timeout}
      end)

      assert {:error, :timeout} = ZKB.fetch_system_killmails(system_id, [])
    end

    test "validates system ID format" do
      assert {:error, error} = ZKB.fetch_system_killmails("invalid", [])
      assert error.domain == :validation
      assert String.contains?(error.message, "Invalid system ID format")
    end

    test "validates positive system ID" do
      assert {:error, error} = ZKB.fetch_system_killmails(-1, [])
      assert error.domain == :validation
    end
  end

  describe "get_system_killmail_count/1" do
    test "successfully gets kill count" do
      system_id = 30_000_142
      expected_count = 42

      # Create a list with 42 items (the function counts list length)
      kill_list = Enum.map(1..expected_count, fn id -> %{"killmail_id" => id} end)

      HttpClientMock
      |> expect(:get_zkb, fn
        "#{@base_url}/systemID/30000142/", _headers, _opts ->
          {:ok, %{status: 200, body: kill_list}}
      end)

      assert {:ok, ^expected_count} = ZKB.get_system_killmail_count(system_id)
    end

    test "handles client errors" do
      system_id = 30_000_142

      HttpClientMock
      |> expect(:get_zkb, fn
        "#{@base_url}/systemID/30000142/", _headers, _opts ->
          {:error, :not_found}
      end)

      assert {:error, :not_found} = ZKB.get_system_killmail_count(system_id)
    end

    test "validates system ID format" do
      assert {:error, error} = ZKB.get_system_killmail_count("invalid")
      assert error.domain == :validation
      assert String.contains?(error.message, "Invalid system ID format")
    end

    test "validates positive system ID" do
      assert {:error, error} = ZKB.get_system_killmail_count(-1)
      assert error.domain == :validation
    end
  end

  describe "fetch_history/1" do
    test "successfully fetches historical kill IDs" do
      date = "20240101"

      historical_data = %{
        "122912852" => "b2550e9cb63e9e93c4b4416c20e1674de8bbf34d",
        "122912855" => "e0b6afbcf3fd7359d95011d8f2656345f110a930",
        "122912856" => "22de1d255b4c3419151ddcf9f0c0d3f8313b7f53"
      }

      HttpClientMock
      |> expect(:get_zkb, fn
        "#{@base_url}/history/20240101.json", _headers, _opts ->
          {:ok, %{status: 200, body: historical_data}}
      end)

      assert {:ok, ^historical_data} = ZKB.fetch_history(date)
    end

    test "handles empty historical data" do
      date = "20240101"
      empty_data = %{}

      HttpClientMock
      |> expect(:get_zkb, fn
        "#{@base_url}/history/20240101.json", _headers, _opts ->
          {:ok, %{status: 200, body: empty_data}}
      end)

      assert {:ok, ^empty_data} = ZKB.fetch_history(date)
    end

    test "handles client errors" do
      date = "20240101"

      HttpClientMock
      |> expect(:get_zkb, fn
        "#{@base_url}/history/20240101.json", _headers, _opts ->
          {:error, :timeout}
      end)

      assert {:error, :timeout} = ZKB.fetch_history(date)
    end

    test "handles invalid response format" do
      date = "20240101"

      HttpClientMock
      |> expect(:get_zkb, fn
        "#{@base_url}/history/20240101.json", _headers, _opts ->
          {:ok, %{status: 200, body: "invalid_string_response"}}
      end)

      assert {:error, error} = ZKB.fetch_history(date)
      assert error.type == :invalid_response
      assert String.contains?(error.message, "Expected map, got string")
    end

    test "validates date format" do
      assert {:error, error} = ZKB.fetch_history("invalid")
      assert error.domain == :validation
      assert String.contains?(error.message, "Invalid date format")
    end

    test "validates date string type" do
      assert {:error, error} = ZKB.fetch_history(123)
      assert error.domain == :validation
      assert String.contains?(error.message, "Invalid date format")
    end

    test "handles rate limit errors from HTTP client" do
      date = "20240101"

      rate_limit_error = %WandererKills.Core.Support.Error{
        type: :rate_limit,
        message: "Rate limit exceeded"
      }

      HttpClientMock
      |> expect(:get_zkb, fn
        "#{@base_url}/history/20240101.json", _headers, _opts ->
          {:error, rate_limit_error}
      end)

      assert {:error, ^rate_limit_error} = ZKB.fetch_history(date)
    end
  end
end
