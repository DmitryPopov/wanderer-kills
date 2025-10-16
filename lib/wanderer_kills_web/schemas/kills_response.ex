defmodule WandererKillsWeb.Schemas.KillsResponse do
  @moduledoc """
  OpenAPI schema for kills list response.
  """

  require OpenApiSpex
  alias WandererKillsWeb.Schemas.Killmail

  OpenApiSpex.schema(%{
    title: "KillsResponse",
    description: "Response containing a list of killmails",
    type: :object,
    properties: %{
      data: %OpenApiSpex.Schema{
        type: :object,
        properties: %{
          kills: %OpenApiSpex.Schema{
            type: :array,
            items: Killmail,
            description: "List of killmails"
          },
          data_fetched_at: %OpenApiSpex.Schema{
            type: :string,
            format: :"date-time",
            description: "When the killmail data was originally fetched from zKillboard/ESI"
          },
          cached: %OpenApiSpex.Schema{
            type: :boolean,
            description: "Whether this data was served from cache"
          }
        },
        required: [:kills, :data_fetched_at, :cached]
      },
      response_timestamp: %OpenApiSpex.Schema{
        type: :string,
        format: :"date-time",
        description: "When this API response was generated (useful for cache age calculation)"
      }
    },
    required: [:data, :response_timestamp]
  })
end
