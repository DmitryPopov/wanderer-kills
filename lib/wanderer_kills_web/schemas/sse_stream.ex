defmodule WandererKillsWeb.Schemas.SSEStream do
  @moduledoc """
  OpenAPI schema for SSE stream response.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "SSE Stream",
    description: "Server-Sent Events stream format",
    type: :string,
    format: :"text/event-stream",
    example: """
    event: connected
    data: SSE stream connected

    event: killmail
    data: {"killmail_id": 123456789, "kill_time": "2024-01-15T14:30:00Z", ...}
    id: 123456789

    event: heartbeat
    data: {"timestamp": "2024-01-15T14:30:00Z"}
    """
  })
end
