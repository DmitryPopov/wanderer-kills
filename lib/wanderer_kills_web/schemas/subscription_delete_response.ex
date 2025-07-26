defmodule WandererKillsWeb.Schemas.SubscriptionDeleteResponse do
  @moduledoc """
  OpenAPI schema for subscription deletion response.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "SubscriptionDeleteResponse",
    description: "Response after deleting subscriptions",
    type: :object,
    properties: %{
      data: %OpenApiSpex.Schema{
        type: :object,
        properties: %{
          message: %OpenApiSpex.Schema{
            type: :string,
            description: "Success message"
          },
          subscriber_id: %OpenApiSpex.Schema{
            type: :string,
            description: "ID of the unsubscribed subscriber"
          }
        },
        required: [:message, :subscriber_id]
      }
    },
    required: [:data],
    example: %{
      data: %{
        message: "Successfully unsubscribed",
        subscriber_id: "user123"
      }
    }
  })
end
