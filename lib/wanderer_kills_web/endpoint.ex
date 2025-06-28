defmodule WandererKillsWeb.Endpoint do
  @moduledoc """
  Phoenix Endpoint for WandererKills web interface.

  Handles both HTTP API requests and WebSocket connections for real-time killmail subscriptions.
  """

  use Phoenix.Endpoint, otp_app: :wanderer_kills

  # WebSocket configuration
  socket("/socket", WandererKillsWeb.UserSocket,
    websocket: [
      # 60 seconds (increased from 45)
      timeout: 60_000,
      transport_log: if(Mix.env() == :dev, do: :debug, else: false),
      # Set to specific origins in production
      check_origin: false,
      # Compress messages for better performance
      compress: true,
      # Max frame size 128KB
      max_frame_size: 131_072
    ],
    longpoll: false
  )

  # Serve at "/" the static files from "priv/static" directory.
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug(Plug.Static,
    at: "/",
    from: :wanderer_kills,
    gzip: true,
    only: ~w(css fonts images js favicon.ico robots.txt)
  )

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug(Phoenix.CodeReloader)
  end

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)

  # Phoenix router
  plug(WandererKillsWeb.Router)
end
