defmodule WandererKillsWeb.Schemas.SubscriptionResponse do
  @moduledoc """
  OpenAPI schema for subscription creation response.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "SubscriptionResponse",
    description: "Response after creating a subscription",
    type: :object,
    properties: %{
      data: %OpenApiSpex.Schema{
        type: :object,
        properties: %{
          subscription_id: %OpenApiSpex.Schema{
            type: :string,
            description: "Unique identifier for the created subscription"
          },
          message: %OpenApiSpex.Schema{
            type: :string,
            description: "Success message"
          }
        },
        required: [:subscription_id, :message]
      }
    },
    required: [:data],
    example: %{
      data: %{
        subscription_id: "sub_123456789",
        message: "Subscription created successfully"
      }
    }
  })
end
