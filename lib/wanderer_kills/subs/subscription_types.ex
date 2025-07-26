defmodule WandererKills.Subs.SubscriptionTypes do
  @moduledoc """
  Type definitions for the simplified subscription system.
  """

  @type subscription_id :: String.t()
  @type subscriber_id :: String.t()
  @type system_id :: integer()
  @type character_id :: integer()
  @type subscription_type :: :webhook | :websocket | :sse

  defstruct [
    :id,
    :subscriber_id,
    :type,
    :system_ids,
    :character_ids,
    :callback_url,
    :socket_pid,
    :user_id,
    :created_at,
    :updated_at
  ]

  @type subscription :: %__MODULE__{
          id: subscription_id(),
          subscriber_id: subscriber_id(),
          type: subscription_type(),
          system_ids: [system_id()],
          character_ids: [character_id()],
          callback_url: String.t() | nil,
          socket_pid: pid() | nil,
          user_id: String.t() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @type subscription_stats :: %{
          total_subscriptions: non_neg_integer(),
          websocket_subscriptions: non_neg_integer(),
          webhook_subscriptions: non_neg_integer(),
          sse_subscriptions: non_neg_integer(),
          total_systems: non_neg_integer(),
          total_characters: non_neg_integer(),
          memory_usage: non_neg_integer()
        }

  @type index_stats :: %{
          total_entities: non_neg_integer(),
          total_subscriptions: non_neg_integer(),
          memory_usage_bytes: non_neg_integer(),
          average_subscriptions_per_entity: float()
        }
end
