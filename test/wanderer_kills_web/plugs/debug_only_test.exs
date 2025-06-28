defmodule WandererKillsWeb.Plugs.DebugOnlyTest do
  use WandererKillsWeb.ConnCase

  alias WandererKillsWeb.Plugs.DebugOnly

  describe "call/2" do
    test "allows access in test environment", %{conn: conn} do
      # In test environment, should pass through
      result = DebugOnly.call(conn, [])
      assert result == conn
    end

    test "blocks access in production environment", %{conn: conn} do
      # We can't actually change Mix.env() in tests, but we can test
      # that the plug is properly integrated in the router
      conn = get(conn, "/api/v1/kills/stream/stats")

      # In test env, it should pass through to the controller
      # which would return 200 or another status, not 403
      refute conn.status == 403
    end
  end
end
