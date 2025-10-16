defmodule WandererKillsWeb.Schemas.SubscriptionStatsResponse do
  @moduledoc """
  OpenAPI schema for subscription statistics response.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "SubscriptionStatsResponse",
    description: "Response containing subscription statistics",
    type: :object,
    properties: %{
      data: %OpenApiSpex.Schema{
        type: :object,
        properties: %{
          total_subscriptions: %OpenApiSpex.Schema{
            type: :integer,
            description: "Total number of active subscriptions"
          },
          unique_subscribers: %OpenApiSpex.Schema{
            type: :integer,
            description: "Number of unique subscribers"
          },
          systems_tracked: %OpenApiSpex.Schema{
            type: :integer,
            description: "Number of unique systems being tracked"
          },
          characters_tracked: %OpenApiSpex.Schema{
            type: :integer,
            description: "Number of unique characters being tracked"
          }
        }
      }
    },
    required: [:data],
    example: %{
      data: %{
        total_subscriptions: 42,
        unique_subscribers: 15,
        systems_tracked: 127,
        characters_tracked: 89
      }
    }
  })
end
