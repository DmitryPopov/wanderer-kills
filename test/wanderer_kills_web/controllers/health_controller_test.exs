defmodule WandererKillsWeb.HealthControllerTest do
  use WandererKills.UnifiedTestCase, async: false, type: :conn

  describe "GET /api/health (health check endpoint)" do
    @tag :skip
    test "returns 503 with standardized error format when health check fails", %{conn: _conn} do
      # This test is skipped because we cannot easily mock Health.check_health to fail
      # The actual error handling is tested through integration tests
    end

    test "returns health status with proper structure", %{conn: conn} do
      # Test the actual health endpoint
      conn = get(conn, "/health")

      # Should return 200 or 503 depending on actual system health
      assert conn.status in [200, 503]

      response = json_response(conn, conn.status)

      # When health check is successful
      if conn.status == 200 do
        assert Map.has_key?(response, "healthy")
        assert Map.has_key?(response, "circuit_breaker")
        assert Map.has_key?(response, "connection_monitor")
        assert Map.has_key?(response, "timestamp")
      else
        # When health check fails, verify standardized error format
        assert %{
                 "error" => %{
                   "domain" => "system",
                   "type" => "health_check_failed",
                   "message" => "Health check failed",
                   "retryable" => false,
                   "details" => details
                 }
               } = response

        assert Map.has_key?(details, "reason")
        assert Map.has_key?(details, "timestamp")
        assert is_binary(details["timestamp"])
      end
    end
  end

  describe "GET /api/ping" do
    test "returns simple pong response", %{conn: conn} do
      conn = get(conn, "/ping")
      assert text_response(conn, 200) == "pong"
    end
  end

  describe "GET /api/status" do
    test "returns system status metrics", %{conn: conn} do
      conn = get(conn, "/status")

      response = json_response(conn, 200)
      assert Map.has_key?(response, "metrics")
      assert Map.has_key?(response, "summary")
      assert Map.has_key?(response, "timestamp")

      # Check summary fields
      summary = response["summary"]
      assert Map.has_key?(summary, "api_requests_per_minute")
      assert Map.has_key?(summary, "active_subscriptions")
      assert Map.has_key?(summary, "killmails_stored")
      assert Map.has_key?(summary, "cache_hit_rate")
      assert Map.has_key?(summary, "memory_usage_mb")
      assert Map.has_key?(summary, "uptime_hours")
    end
  end

  describe "GET /api/metrics" do
    test "returns detailed metrics", %{conn: conn} do
      conn = get(conn, "/metrics")

      assert conn.status == 200
      response = json_response(conn, 200)

      # Verify the response has expected structure
      assert is_map(response)
    end
  end
end
