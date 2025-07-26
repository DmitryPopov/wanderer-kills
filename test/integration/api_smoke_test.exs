defmodule WandererKills.ApiSmokeTest do
  use WandererKills.UnifiedTestCase, async: false, type: :conn

  @endpoint WandererKillsWeb.Endpoint

  test "GET /ping returns pong", %{conn: conn} do
    conn = get(conn, "/ping")
    assert conn.status == 200
    assert conn.resp_body == "pong"
  end
end
