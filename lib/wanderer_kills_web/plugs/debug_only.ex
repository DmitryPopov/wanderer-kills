defmodule WandererKillsWeb.Plugs.DebugOnly do
  @moduledoc """
  Plug to restrict access to debug endpoints in production environments.
  """

  # Determine at compile time if debug access should be allowed
  @debug_enabled Mix.env() in [:dev, :test]

  def init(opts), do: opts

  if @debug_enabled do
    # In dev/test environments, pass through
    def call(conn, _opts), do: conn
  else
    # In production, block access
    import Plug.Conn
    import Phoenix.Controller

    def call(conn, _opts) do
      conn
      |> put_status(:forbidden)
      |> json(%{
        error: "Forbidden",
        code: "forbidden",
        message: "Debug endpoints are disabled in production"
      })
      |> halt()
    end
  end
end
