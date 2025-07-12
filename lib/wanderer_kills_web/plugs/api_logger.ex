defmodule WandererKillsWeb.Plugs.ApiLogger do
  @moduledoc """
  Custom API logger plug for structured request/response logging.

  Provides more detailed logging than the default Plug.Logger with
  structured metadata for better observability.
  """

  require Logger

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    start_time = System.monotonic_time()

    # Only log non-SSE requests to reduce noise
    unless String.contains?(conn.request_path, "/stream") do
      Logger.debug("API request started",
        method: conn.method,
        path: conn.request_path
      )
    end

    # Register a callback to log the response
    Plug.Conn.register_before_send(conn, fn conn ->
      end_time = System.monotonic_time()
      duration_ms = System.convert_time_unit(end_time - start_time, :native, :millisecond)

      # Only log non-SSE requests to reduce noise
      unless String.contains?(conn.request_path, "/stream") do
        Logger.debug("API request completed",
          method: conn.method,
          path: conn.request_path,
          status: conn.status,
          duration_ms: duration_ms
        )
      end

      conn
    end)
  end
end
