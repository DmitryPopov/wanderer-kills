defmodule WandererKills.Core.Observability.SSEMetricsTest do
  use ExUnit.Case, async: false

  alias WandererKills.Core.Observability.{Monitoring, UnifiedStatus}

  setup do
    # Both Monitoring and UnifiedStatus are already running from the application
    # No need to start them again
    :ok
  end

  describe "SSE metrics in health endpoint" do
    test "includes SSE health status" do
      {:ok, health} = Monitoring.check_health()

      assert Map.has_key?(health, :sse)
      assert is_map(health.sse)
      assert Map.has_key?(health.sse, :healthy)
      assert Map.has_key?(health.sse, :status)
      assert Map.has_key?(health.sse, :active_connections)
      assert Map.has_key?(health.sse, :max_connections)
      assert Map.has_key?(health.sse, :utilization)
    end

    test "SSE health reflects connection state" do
      {:ok, health} = Monitoring.check_health()

      # Initially should be healthy with no connections (library managed)
      assert health.sse.healthy == true
      assert health.sse.status == "managed_by_library"
      assert health.sse.active_connections == 0
    end
  end

  describe "SSE metrics collection" do
    test "includes SSE metrics in comprehensive metrics" do
      {:ok, metrics} = Monitoring.get_metrics()

      assert Map.has_key?(metrics, :sse)
      assert is_map(metrics.sse)
      assert Map.has_key?(metrics.sse, :connections_active)
      assert Map.has_key?(metrics.sse, :connections_total)
      assert Map.has_key?(metrics.sse, :connections_closed)
      assert Map.has_key?(metrics.sse, :events_sent)
      assert Map.has_key?(metrics.sse, :connections_by_ip)
      assert Map.has_key?(metrics.sse, :manager_status)
    end

    test "SSE metrics reflect library-managed state" do
      # SSE is now managed by sse_phoenix_pubsub library
      {:ok, metrics} = Monitoring.get_metrics()

      # Metrics should be available but show library-managed status
      assert metrics.sse.connections_active == 0
      assert metrics.sse.connections_total == 0
      assert metrics.sse.events_sent == 0
      assert metrics.sse.manager_status == "managed_by_library"
    end
  end

  describe "SSE metrics in unified status" do
    test "includes SSE section in status report" do
      status = UnifiedStatus.get_status()

      assert Map.has_key?(status, :sse)
      assert is_map(status.sse)
      assert Map.has_key?(status.sse, :connections_active)
      assert Map.has_key?(status.sse, :connections_total)
      assert Map.has_key?(status.sse, :events_sent_total)
      assert Map.has_key?(status.sse, :events_killmails)
      assert Map.has_key?(status.sse, :events_heartbeats)
      assert Map.has_key?(status.sse, :events_errors)
      assert Map.has_key?(status.sse, :connections_by_ip)
      assert Map.has_key?(status.sse, :avg_connection_duration)
      assert Map.has_key?(status.sse, :events_per_connection)
    end

    test "SSE metrics calculation" do
      status = UnifiedStatus.get_status()

      # Initial state should have zeros
      assert status.sse.connections_active == 0
      assert status.sse.events_sent_total == 0
      assert status.sse.avg_connection_duration == 0.0
      assert status.sse.events_per_connection == 0.0
    end
  end
end
