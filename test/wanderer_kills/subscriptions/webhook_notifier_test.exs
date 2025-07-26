defmodule WandererKills.Subs.WebhookNotifierTest do
  use WandererKills.TestCase, async: false
  import Mox

  alias WandererKills.Core.Support.Error
  alias WandererKills.Subs.WebhookNotifier

  setup do
    # Configure HTTP client to use mock
    Application.put_env(:wanderer_kills, :http, client: WandererKills.Http.ClientMock)

    on_exit(fn ->
      Application.delete_env(:wanderer_kills, :http)
    end)

    subscription = %{
      "id" => "sub_123",
      "callback_url" => "https://example.com/webhook",
      "subscriber_id" => "user_123"
    }

    kills = [
      %{
        "killmail_id" => 123_456,
        "solar_system_id" => 30_000_142,
        "killmail_time" => "2024-01-01T00:00:00Z"
      }
    ]

    %{subscription: subscription, kills: kills}
  end

  describe "notify_webhook/4" do
    test "successfully sends webhook notification", %{subscription: subscription, kills: kills} do
      WandererKills.Http.ClientMock
      |> expect(:post, fn url, body, headers, _opts ->
        assert url == "https://example.com/webhook"
        assert body[:type] == "killmail_update"
        assert body[:system_id] == 30_000_142
        assert body[:kills] == kills

        # Check headers are present without depending on order
        headers_map = Map.new(headers)
        assert headers_map["Content-Type"] == "application/json"
        assert headers_map["User-Agent"] == "WandererKills/1.0"

        {:ok, %{status: 200, body: %{"success" => true}}}
      end)

      assert :ok =
               WebhookNotifier.notify_webhook(
                 subscription["callback_url"],
                 30_000_142,
                 kills,
                 subscription["id"]
               )
    end

    test "handles webhook failure gracefully", %{subscription: subscription} do
      kills = [%{"killmail_id" => 123_456}]

      WandererKills.Http.ClientMock
      |> expect(:post, fn _url, _body, _headers, _opts ->
        {:error, Error.http_error(:timeout, "Request timed out", true)}
      end)

      # Should return an error tuple
      assert {:error, _} =
               WebhookNotifier.notify_webhook(
                 subscription["callback_url"],
                 30_000_142,
                 kills,
                 subscription["id"]
               )
    end

    test "handles missing callback URL", %{subscription: subscription} do
      subscription = %{subscription | "callback_url" => nil}
      kills = [%{"killmail_id" => 123_456}]

      # No HTTP calls should be made for nil URL
      # verify_on_exit! will ensure no unexpected calls are made

      assert :ok =
               WebhookNotifier.notify_webhook(
                 subscription["callback_url"],
                 30_000_142,
                 kills,
                 subscription["id"]
               )
    end

    test "handles empty callback URL", %{subscription: subscription} do
      subscription = %{subscription | "callback_url" => ""}
      kills = [%{"killmail_id" => 123_456}]

      # No HTTP calls should be made for empty URL
      # verify_on_exit! will ensure no unexpected calls are made

      assert :ok =
               WebhookNotifier.notify_webhook(
                 subscription["callback_url"],
                 30_000_142,
                 kills,
                 subscription["id"]
               )
    end
  end

  describe "notify_webhook_count/4" do
    test "successfully sends kill count notification", %{subscription: subscription} do
      WandererKills.Http.ClientMock
      |> expect(:post, fn url, body, headers, _opts ->
        assert url == "https://example.com/webhook"
        assert body[:type] == "killmail_count_update"
        assert body[:system_id] == 30_000_142
        assert body[:count] == 42

        # Check headers are present without depending on order
        headers_map = Map.new(headers)
        assert headers_map["Content-Type"] == "application/json"
        assert headers_map["User-Agent"] == "WandererKills/1.0"

        {:ok, %{status: 200, body: %{"success" => true}}}
      end)

      assert :ok =
               WebhookNotifier.notify_webhook_count(
                 subscription["callback_url"],
                 30_000_142,
                 42,
                 subscription["id"]
               )
    end

    test "handles kill count notification failure", %{subscription: subscription} do
      WandererKills.Http.ClientMock
      |> expect(:post, fn _url, _body, _headers, _opts ->
        {:error, Error.http_error(:server_error, "Internal server error", true)}
      end)

      # Should return an error tuple
      assert {:error, _} =
               WebhookNotifier.notify_webhook_count(
                 subscription["callback_url"],
                 30_000_142,
                 42,
                 subscription["id"]
               )
    end
  end

  describe "webhook payload structure" do
    test "includes all required fields in killmail update", %{subscription: subscription} do
      kills = [
        %{
          "killmail_id" => 123_456,
          "solar_system_id" => 30_000_142,
          "killmail_time" => "2024-01-01T00:00:00Z",
          "victim" => %{"ship_type_id" => 587}
        }
      ]

      WandererKills.Http.ClientMock
      |> expect(:post, fn _url, body, _headers, _opts ->
        # Verify payload structure
        assert Map.has_key?(body, :type)
        assert Map.has_key?(body, :timestamp)
        assert Map.has_key?(body, :system_id)
        assert Map.has_key?(body, :kills)
        assert is_list(body[:kills])

        {:ok, %{status: 200, body: %{"success" => true}}}
      end)

      assert :ok =
               WebhookNotifier.notify_webhook(
                 subscription["callback_url"],
                 30_000_142,
                 kills,
                 subscription["id"]
               )
    end

    test "includes timestamp in ISO8601 format", %{subscription: subscription} do
      WandererKills.Http.ClientMock
      |> expect(:post, fn _url, body, _headers, _opts ->
        timestamp = body[:timestamp]
        assert is_binary(timestamp)
        # Should be parseable as DateTime
        assert {:ok, _datetime, _offset} = DateTime.from_iso8601(timestamp)

        {:ok, %{status: 200, body: %{"success" => true}}}
      end)

      assert :ok =
               WebhookNotifier.notify_webhook_count(
                 subscription["callback_url"],
                 30_000_142,
                 42,
                 subscription["id"]
               )
    end
  end

  describe "HTTP client options" do
    test "uses appropriate timeout for webhook requests", %{subscription: subscription} do
      WandererKills.Http.ClientMock
      |> expect(:post, fn _url, _body, _headers, opts ->
        # Should have a reasonable timeout
        assert opts[:timeout] >= 5000

        {:ok, %{status: 200, body: %{"success" => true}}}
      end)

      assert :ok =
               WebhookNotifier.notify_webhook_count(
                 subscription["callback_url"],
                 30_000_142,
                 42,
                 subscription["id"]
               )
    end
  end
end
