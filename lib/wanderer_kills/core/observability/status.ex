defmodule WandererKills.Core.Observability.Status do
  @moduledoc """
  Business logic for application status and health information.

  This module centralizes all status-related operations that were
  previously scattered across controllers.
  """

  alias WandererKills.Core.Observability.UnifiedStatus
  alias WandererKills.Subs.SubscriptionManager

  # Cache configuration for subscription count
  @subscription_count_cache_key :status_subscription_count_cache
  # 5 seconds
  @subscription_count_cache_ttl 5_000

  @doc """
  Get comprehensive service status information.
  """
  @spec get_service_status() :: map()
  def get_service_status do
    # Get comprehensive metrics from UnifiedStatus
    metrics = UnifiedStatus.get_status()

    %{
      metrics: metrics,
      summary: build_status_summary(metrics),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp build_status_summary(metrics) do
    %{
      api_requests_per_minute:
        get_in(metrics, [:api, :zkillboard, :requests_per_minute]) +
          get_in(metrics, [:api, :esi, :requests_per_minute]),
      active_subscriptions: get_in(metrics, [:websocket, :connections_active]) || 0,
      killmails_stored: get_in(metrics, [:storage, :killmails_count]) || 0,
      cache_hit_rate: get_in(metrics, [:cache, :hit_rate]) || 0.0,
      memory_usage_mb: get_in(metrics, [:system, :memory_mb]) || 0.0,
      uptime_hours: get_in(metrics, [:system, :uptime_hours]) || 0.0,
      processing_lag_seconds:
        get_in(metrics, [:processing, :redisq_last_killmail_ago_seconds]) || 0,
      active_preload_tasks: get_in(metrics, [:preload, :active_tasks]) || 0
    }
  end

  @doc """
  Get WebSocket-specific status information.
  """
  @spec get_websocket_status() :: String.t()
  def get_websocket_status do
    if websocket_connected?() do
      "online"
    else
      "offline"
    end
  end

  @doc """
  Get the last killmail time from the system.
  """
  @spec get_last_killmail_time() :: String.t() | nil
  def get_last_killmail_time do
    # Get the most recent killmail from the ETS table
    # Note: This scans the entire table, so it may be inefficient for large datasets
    case get_latest_killmail_from_ets() do
      {_killmail_id, killmail_data} when is_map(killmail_data) ->
        killmail_data["kill_time"] || killmail_data["killmail_time"]

      _ ->
        nil
    end
  end

  defp get_latest_killmail_from_ets do
    # Scan the killmails ETS table to find the most recent one
    # In production, you might want to maintain a separate index for this
    :ets.foldl(
      fn {killmail_id, killmail_data}, acc ->
        compare_and_select_latest_killmail({killmail_id, killmail_data}, acc)
      end,
      {nil, %{}},
      :killmails
    )
  end

  defp compare_and_select_latest_killmail({killmail_id, killmail_data}, acc) do
    current_time = get_time_from_killmail(killmail_data)
    acc_time = get_time_from_killmail(elem(acc, 1))

    case {current_time, acc_time} do
      {time1, time2} when is_binary(time1) and is_binary(time2) ->
        if time1 > time2, do: {killmail_id, killmail_data}, else: acc

      {time1, _} when is_binary(time1) ->
        {killmail_id, killmail_data}

      _ ->
        acc
    end
  rescue
    _ -> {nil, %{}}
  end

  defp get_time_from_killmail(%{"kill_time" => time}) when is_binary(time), do: time
  defp get_time_from_killmail(%{"killmail_time" => time}) when is_binary(time), do: time
  defp get_time_from_killmail(_), do: nil

  @doc """
  Get active subscription count with caching.
  """
  @spec get_active_subscription_count() :: non_neg_integer()
  def get_active_subscription_count do
    case get_cached_subscription_count() do
      {:ok, count} ->
        count

      _miss_or_expired ->
        count = fetch_fresh_subscription_count()
        cache_subscription_count(count)
        count
    end
  end

  defp get_cached_subscription_count do
    case Process.get(@subscription_count_cache_key) do
      {count, timestamp} when is_integer(timestamp) and is_integer(count) ->
        if System.monotonic_time(:millisecond) - timestamp < @subscription_count_cache_ttl do
          {:ok, count}
        else
          :expired
        end

      _ ->
        :miss
    end
  end

  defp fetch_fresh_subscription_count do
    SubscriptionManager.list_subscriptions() |> length()
  rescue
    _ -> 0
  end

  defp cache_subscription_count(count) do
    Process.put(@subscription_count_cache_key, {count, System.monotonic_time(:millisecond)})
  end

  # Private functions

  defp websocket_connected? do
    case Code.ensure_loaded(WandererKillsWeb.Endpoint) do
      {:module, _} -> Process.whereis(WandererKillsWeb.Endpoint) != nil
      {:error, _} -> false
    end
  end
end
