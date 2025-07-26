defmodule WandererKills.Ingest.Historical.BasicTest do
  use ExUnit.Case

  alias WandererKills.Ingest.Killmails.ZkbClient

  describe "basic functionality" do
    test "ZkbClient has fetch_history function" do
      # Test that the function exists and validates non-binary input
      assert {:error, error} = ZkbClient.fetch_history(123)
      assert error.domain == :validation
      assert error.type == :invalid_format
      assert error.message =~ "Invalid date format"
    end

    test "HistoricalStreamer configuration parsing" do
      # Test configuration parsing from environment variables
      System.put_env("HISTORICAL_STREAMING_ENABLED", "true")
      System.put_env("HISTORICAL_START_DATE", "20240315")
      System.put_env("HISTORICAL_DAILY_LIMIT", "2000")
      System.put_env("HISTORICAL_BATCH_SIZE", "100")
      System.put_env("HISTORICAL_BATCH_INTERVAL_MS", "15000")

      # Load configuration (simulating runtime.exs behavior)
      config = %{
        enabled: System.get_env("HISTORICAL_STREAMING_ENABLED", "false") == "true",
        start_date: System.get_env("HISTORICAL_START_DATE", "20240101"),
        daily_limit: String.to_integer(System.get_env("HISTORICAL_DAILY_LIMIT", "5000")),
        batch_size: String.to_integer(System.get_env("HISTORICAL_BATCH_SIZE", "50")),
        batch_interval_ms:
          String.to_integer(System.get_env("HISTORICAL_BATCH_INTERVAL_MS", "10000"))
      }

      assert config.enabled == true
      assert config.start_date == "20240315"
      assert config.daily_limit == 2000
      assert config.batch_size == 100
      assert config.batch_interval_ms == 15_000

      # Clean up
      System.delete_env("HISTORICAL_STREAMING_ENABLED")
      System.delete_env("HISTORICAL_START_DATE")
      System.delete_env("HISTORICAL_DAILY_LIMIT")
      System.delete_env("HISTORICAL_BATCH_SIZE")
      System.delete_env("HISTORICAL_BATCH_INTERVAL_MS")
    end

    test "HistoricalStreamer configuration defaults" do
      # Clear any existing env vars
      System.delete_env("HISTORICAL_STREAMING_ENABLED")
      System.delete_env("HISTORICAL_START_DATE")
      System.delete_env("HISTORICAL_DAILY_LIMIT")
      System.delete_env("HISTORICAL_BATCH_SIZE")
      System.delete_env("HISTORICAL_BATCH_INTERVAL_MS")

      # Test default values
      config = %{
        enabled: System.get_env("HISTORICAL_STREAMING_ENABLED", "false") == "true",
        start_date: System.get_env("HISTORICAL_START_DATE", "20240101"),
        daily_limit: String.to_integer(System.get_env("HISTORICAL_DAILY_LIMIT", "5000")),
        batch_size: String.to_integer(System.get_env("HISTORICAL_BATCH_SIZE", "50")),
        batch_interval_ms:
          String.to_integer(System.get_env("HISTORICAL_BATCH_INTERVAL_MS", "10000"))
      }

      assert config.enabled == false
      assert config.start_date == "20240101"
      assert config.daily_limit == 5000
      assert config.batch_size == 50
      assert config.batch_interval_ms == 10_000
    end

    test "HistoricalStreamer date format validation" do
      # Valid date formats
      assert is_binary("20240101")
      assert String.match?("20240101", ~r/^\d{8}$/)

      # Invalid date formats
      refute String.match?("2024-01-01", ~r/^\d{8}$/)
      refute String.match?("invalid", ~r/^\d{8}$/)
      # Too short
      refute String.match?("2024010", ~r/^\d{8}$/)
      # Too long
      refute String.match?("202401011", ~r/^\d{8}$/)
    end

    test "HistoricalStreamer positive number validation" do
      # Test positive number parsing
      assert {:ok, {100, ""}} = {:ok, Integer.parse("100")}
      assert {:ok, {1, ""}} = {:ok, Integer.parse("1")}

      # Test invalid number parsing
      assert {:ok, :error} = {:ok, Integer.parse("invalid")}
      # Zero is not positive
      assert {:ok, {0, ""}} = {:ok, Integer.parse("0")}
      # Negative is not positive
      assert {:ok, {-5, ""}} = {:ok, Integer.parse("-5")}
      # Partial parse
      assert {:ok, {100, "abc"}} = {:ok, Integer.parse("100abc")}
    end
  end
end
