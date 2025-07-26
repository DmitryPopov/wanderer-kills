defmodule WandererKills.Subs.SystemIndex do
  @moduledoc """
  Direct ETS-based system-to-subscription mapping.
  Replaces the 574-line macro-generated BaseIndex with ~50 lines of direct implementation.
  """

  alias WandererKills.Subs.SubscriptionTypes

  @table_name :system_subscription_index

  # ============================================================================
  # Public API
  # ============================================================================

  @doc "Initialize the ETS table"
  @spec init() :: :ok
  def init do
    case :ets.whereis(@table_name) do
      :undefined ->
        :ets.new(@table_name, [:set, :public, :named_table, {:read_concurrency, true}])
        :ok

      _ ->
        :ok
    end
  end

  @doc "Add subscription to system index"
  @spec add_subscription(String.t(), [integer()]) :: :ok
  def add_subscription(subscription_id, system_ids) do
    Enum.each(system_ids, fn system_id ->
      current_subs = get_subscriptions_for_system(system_id)
      updated_subs = MapSet.put(current_subs, subscription_id)
      :ets.insert(@table_name, {system_id, updated_subs})
    end)

    :ok
  end

  @doc "Remove subscription from system index"
  @spec remove_subscription(String.t(), [integer()]) :: :ok
  def remove_subscription(subscription_id, system_ids) do
    Enum.each(system_ids, fn system_id ->
      current_subs = get_subscriptions_for_system(system_id)
      updated_subs = MapSet.delete(current_subs, subscription_id)

      if MapSet.size(updated_subs) == 0 do
        :ets.delete(@table_name, system_id)
      else
        :ets.insert(@table_name, {system_id, updated_subs})
      end
    end)

    :ok
  end

  @doc "Find all subscriptions for a system"
  @spec find_subscriptions_for_system(integer()) :: [String.t()]
  def find_subscriptions_for_system(system_id) do
    get_subscriptions_for_system(system_id) |> MapSet.to_list()
  end

  @doc "Find all subscriptions for multiple systems"
  @spec find_subscriptions_for_systems([integer()]) :: [String.t()]
  def find_subscriptions_for_systems(system_ids) do
    system_ids
    |> Enum.reduce(MapSet.new(), fn system_id, acc ->
      MapSet.union(acc, get_subscriptions_for_system(system_id))
    end)
    |> MapSet.to_list()
  end

  @doc "Clear all subscriptions from the index"
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table_name)
    :ok
  end

  @doc "Get statistics about the system index"
  @spec get_stats() :: SubscriptionTypes.index_stats()
  def get_stats do
    info = :ets.info(@table_name)
    total_entities = Keyword.get(info, :size, 0)
    memory_words = Keyword.get(info, :memory, 0)
    memory_bytes = memory_words * :erlang.system_info(:wordsize)

    # Calculate average subscriptions per system
    avg_subs =
      if total_entities > 0 do
        total_subs =
          :ets.tab2list(@table_name)
          |> Enum.reduce(0, fn {_sys_id, subs}, acc -> acc + MapSet.size(subs) end)

        total_subs / total_entities
      else
        0.0
      end

    %{
      total_entities: total_entities,
      total_subscriptions: count_unique_subscriptions(),
      memory_usage_bytes: memory_bytes,
      average_subscriptions_per_entity: avg_subs
    }
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp get_subscriptions_for_system(system_id) do
    case :ets.lookup(@table_name, system_id) do
      [{^system_id, subscriptions}] -> subscriptions
      [] -> MapSet.new()
    end
  end

  defp count_unique_subscriptions do
    :ets.tab2list(@table_name)
    |> Enum.reduce(MapSet.new(), fn {_sys_id, subs}, acc ->
      MapSet.union(acc, subs)
    end)
    |> MapSet.size()
  end
end
