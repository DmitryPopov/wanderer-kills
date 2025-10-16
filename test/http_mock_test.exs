defmodule HttpMockTest do
  use ExUnit.Case

  alias WandererKills.Http.ClientMock

  setup do
    if Code.ensure_loaded?(Mox) do
      Mox.verify_on_exit!(self())
    end

    :ok
  end

  @tag :skip_if_no_mox

  test "HTTP client mock implements the behaviour correctly" do
    # Set up the mock
    Mox.expect(ClientMock, :get, fn url, headers, opts ->
      assert url == "https://example.com/test"
      assert headers == []
      assert opts == []
      {:ok, %{status: 200, body: %{"status" => "success"}, headers: []}}
    end)

    Mox.expect(ClientMock, :get_with_rate_limit, fn url, headers, opts ->
      assert url == "https://example.com/rate-limited"
      assert headers == []
      assert opts == [timeout: 5000]
      {:ok, %{status: 200, body: %{"rate_limited" => true}, headers: []}}
    end)

    Mox.expect(ClientMock, :post, fn url, body, headers, opts ->
      assert url == "https://example.com/post"
      assert body == %{"test" => "data"}
      assert headers == []
      assert opts == []
      {:ok, %{status: 200, body: %{"posted" => true}, headers: []}}
    end)

    Mox.expect(ClientMock, :get_esi, fn url, headers, opts ->
      assert url == "https://esi.evetech.net/test"
      assert headers == []
      assert opts == []
      {:ok, %{status: 200, body: %{"source" => "esi"}, headers: []}}
    end)

    Mox.expect(ClientMock, :get_zkb, fn url, headers, opts ->
      assert url == "https://zkillboard.com/test"
      assert headers == []
      assert opts == []
      {:ok, %{status: 200, body: %{"source" => "zkb"}, headers: []}}
    end)

    # Call the mock functions to verify they work
    assert {:ok, %{body: %{"status" => "success"}}} =
             ClientMock.get("https://example.com/test", [], [])

    assert {:ok, %{body: %{"rate_limited" => true}}} =
             ClientMock.get_with_rate_limit(
               "https://example.com/rate-limited",
               [],
               timeout: 5000
             )

    assert {:ok, %{body: %{"posted" => true}}} =
             ClientMock.post(
               "https://example.com/post",
               %{"test" => "data"},
               [],
               []
             )

    assert {:ok, %{body: %{"source" => "esi"}}} =
             ClientMock.get_esi("https://esi.evetech.net/test", [], [])

    assert {:ok, %{body: %{"source" => "zkb"}}} =
             ClientMock.get_zkb("https://zkillboard.com/test", [], [])
  end
end
