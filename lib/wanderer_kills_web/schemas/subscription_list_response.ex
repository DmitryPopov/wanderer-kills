defmodule WandererKillsWeb.Schemas.SubscriptionListResponse do
  @moduledoc """
  OpenAPI schema for subscription list response.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "SubscriptionListResponse",
    description: "Response containing a list of subscriptions",
    type: :object,
    properties: %{
      data: %OpenApiSpex.Schema{
        type: :object,
        properties: %{
          subscriptions: %OpenApiSpex.Schema{
            type: :array,
            items: %OpenApiSpex.Schema{
              type: :object,
              properties: %{
                id: %OpenApiSpex.Schema{type: :string},
                subscriber_id: %OpenApiSpex.Schema{type: :string},
                type: %OpenApiSpex.Schema{type: :string},
                system_ids: %OpenApiSpex.Schema{
                  type: :array,
                  items: %OpenApiSpex.Schema{type: :integer}
                },
                character_ids: %OpenApiSpex.Schema{
                  type: :array,
                  items: %OpenApiSpex.Schema{type: :integer}
                },
                callback_url: %OpenApiSpex.Schema{type: :string},
                created_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"},
                updated_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"}
              }
            }
          },
          count: %OpenApiSpex.Schema{
            type: :integer,
            description: "Total number of subscriptions"
          }
        },
        required: [:subscriptions, :count]
      }
    },
    required: [:data],
    example: %{
      data: %{
        subscriptions: [
          %{
            id: "sub_123456789",
            subscriber_id: "user123",
            type: "webhook",
            system_ids: [30_000_142, 30_000_143],
            character_ids: [95_465_499],
            callback_url: "https://example.com/webhook",
            created_at: "2024-01-01T12:00:00Z",
            updated_at: "2024-01-01T12:00:00Z"
          }
        ],
        count: 1
      }
    }
  })
end
