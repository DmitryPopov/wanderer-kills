defmodule WandererKillsWeb.Schemas.Error do
  @moduledoc """
  OpenAPI schema for error responses.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Error",
    description: "Error response",
    type: :object,
    properties: %{
      error: %OpenApiSpex.Schema{
        type: :object,
        properties: %{
          domain: %OpenApiSpex.Schema{
            type: :string,
            description: "Error domain"
          },
          type: %OpenApiSpex.Schema{
            type: :string,
            description: "Error type"
          },
          message: %OpenApiSpex.Schema{
            type: :string,
            description: "Human-readable error message"
          },
          details: %OpenApiSpex.Schema{
            type: :object,
            description: "Additional error details",
            nullable: true
          },
          retryable: %OpenApiSpex.Schema{
            type: :boolean,
            description: "Whether the operation can be retried"
          }
        },
        required: [:type, :message]
      }
    },
    required: [:error],
    example: %{
      "error" => %{
        "domain" => "validation",
        "type" => "validation_error",
        "message" => "Invalid system_ids: 'abc' is not a valid integer",
        "details" => nil,
        "retryable" => false
      }
    }
  })
end
