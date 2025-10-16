defmodule WandererKills.TestContexts do
  @moduledoc """
  Consolidated test contexts and HTTP helpers.

  This module provides shared contexts and HTTP mocking utilities for tests.
  """

  import ExUnit.Assertions, only: [assert: 1, flunk: 1]

  alias WandererKills.TestFactory

  # ============================================================================
  # Shared Test Contexts
  # ============================================================================

  @doc """
  Provides a basic killmail context for tests.
  """
  def killmail_context(_context) do
    killmail_id = TestFactory.random_killmail_id()
    system_id = TestFactory.random_system_id()
    character_id = TestFactory.random_character_id()

    killmail_data = TestFactory.build_killmail(killmail_id)

    %{
      killmail_id: killmail_id,
      system_id: system_id,
      character_id: character_id,
      killmail_data: killmail_data
    }
  end

  @doc """
  Provides subscription context for tests.
  """
  def subscription_context(_context) do
    %{
      character_ids: Enum.map(1..3, fn _ -> TestFactory.random_character_id() end),
      system_ids: Enum.map(1..3, fn _ -> TestFactory.random_system_id() end),
      subscription_filters: %{
        min_value: 1_000_000,
        ship_types: [587, 29_984],
        involved: []
      }
    }
  end

  @doc """
  Provides WebSocket context for tests.
  """
  def websocket_context(_context) do
    %{
      client_id: "test_client_#{System.unique_integer()}",
      channel_topic: "system:#{TestFactory.random_system_id()}",
      subscription_data: %{
        systems: [TestFactory.random_system_id()],
        characters: [TestFactory.random_character_id()]
      }
    }
  end

  @doc """
  Provides rate limiter context for tests.
  """
  def rate_limiter_context(_context) do
    %{
      initial_tokens: 50,
      max_tokens: 100,
      refill_rate: 25,
      test_requests: 10
    }
  end

  # ============================================================================
  # HTTP Mock Helpers
  # ============================================================================

  defmodule DefaultHttpMock do
    @moduledoc false
    @behaviour WandererKills.Http.ClientBehaviour

    def get(_url, _headers \\ [], _opts \\ []) do
      {:ok, %{status: 200, body: "{}", headers: []}}
    end

    def post(_url, _body, _headers \\ [], _opts \\ []) do
      {:ok, %{status: 200, body: "{}", headers: []}}
    end

    def get_with_rate_limit(_url, _headers \\ [], _opts \\ []) do
      {:ok, %{status: 200, body: "{}", headers: []}}
    end

    def get_esi(_url, _headers \\ [], _opts \\ []) do
      {:ok, %{status: 200, body: "{}", headers: []}}
    end

    def get_zkb(_url, _headers \\ [], _opts \\ []) do
      {:ok, %{status: 200, body: "{}", headers: []}}
    end
  end

  # Default ESI mock implementation
  defmodule DefaultEsiMock do
    @moduledoc false
    @behaviour WandererKills.Ingest.ESI.ClientBehaviour

    def get_killmail(_killmail_id, _killmail_hash) do
      {:ok,
       %{
         "killmail_id" => 123_456,
         "killmail_time" => DateTime.utc_now() |> DateTime.to_iso8601(),
         "solar_system_id" => 30_000_142,
         "victim" => %{
           "character_id" => 12_345,
           "ship_type_id" => 587
         },
         "attackers" => [
           %{
             "character_id" => 67_890,
             "final_blow" => true,
             "ship_type_id" => 29_984
           }
         ]
       }}
    end

    def get_character(_character_id) do
      {:ok,
       %{
         "name" => "Test Character",
         "corporation_id" => 98_765
       }}
    end

    def get_corporation(_corporation_id) do
      {:ok,
       %{
         "name" => "Test Corporation",
         "alliance_id" => 54_321
       }}
    end

    def get_alliance(_alliance_id) do
      {:ok,
       %{
         "name" => "Test Alliance"
       }}
    end

    def get_ship_type(_ship_type_id) do
      {:ok,
       %{
         "name" => "Test Ship",
         "group_id" => 25
       }}
    end

    def get_system(_system_id) do
      {:ok,
       %{
         "name" => "Test System",
         "constellation_id" => 12_345
       }}
    end

    def get_character_batch(character_ids) do
      Enum.map(character_ids, fn id -> get_character(id) end)
    end

    def get_corporation_batch(corporation_ids) do
      Enum.map(corporation_ids, fn id -> get_corporation(id) end)
    end

    def get_alliance_batch(alliance_ids) do
      Enum.map(alliance_ids, fn id -> get_alliance(id) end)
    end

    def get_type_batch(type_ids) do
      Enum.map(type_ids, fn id -> get_ship_type(id) end)
    end

    def get_group_batch(group_ids) do
      Enum.map(group_ids, fn id -> get_group(id) end)
    end

    def get_system_batch(system_ids) do
      Enum.map(system_ids, fn id -> get_system(id) end)
    end

    def get_type(type_id) do
      get_ship_type(type_id)
    end

    def get_group(_group_id) do
      {:ok,
       %{
         "name" => "Test Group",
         "category_id" => 6
       }}
    end

    def fetch({:character, id}), do: get_character(id)
    def fetch({:corporation, id}), do: get_corporation(id)
    def fetch({:alliance, id}), do: get_alliance(id)
    def fetch({:type, id}), do: get_type(id)
    def fetch({:group, id}), do: get_group(id)
    def fetch({:system, id}), do: get_system(id)

    def fetch(_),
      do:
        {:error,
         %WandererKills.Core.Support.Error{type: :not_found, message: "Unknown fetch type"}}
  end

  # ============================================================================
  # HTTP Response Builders
  # ============================================================================

  @doc """
  Builds a successful HTTP response.
  """
  def success_response(body \\ "{}", status \\ 200) do
    {:ok,
     %{
       status: status,
       body: body,
       headers: [{"content-type", "application/json"}]
     }}
  end

  @doc """
  Builds an error HTTP response.
  """
  def error_response(status \\ 500, message \\ "Internal Server Error") do
    {:ok,
     %{
       status: status,
       body: %{"error" => message} |> Jason.encode!(),
       headers: [{"content-type", "application/json"}]
     }}
  end

  @doc """
  Builds a rate limit error response.
  """
  def rate_limit_response do
    {:ok,
     %{
       status: 429,
       body: %{"error" => "Rate limit exceeded"} |> Jason.encode!(),
       headers: [
         {"content-type", "application/json"},
         {"x-esi-error-limit-remain", "0"},
         {"x-esi-error-limit-reset", "60"}
       ]
     }}
  end

  @doc """
  Builds a killmail response from zKillboard.
  """
  def zkb_killmail_response(killmail_id \\ nil) do
    id = killmail_id || TestFactory.random_killmail_id()

    killmail = %{
      "killID" => id,
      "killmail" => TestFactory.build_killmail(id),
      "zkb" => %{
        "locationID" => TestFactory.random_system_id(),
        "hash" => "test_hash_#{id}",
        "totalValue" => 1_000_000
      }
    }

    success_response(Jason.encode!(killmail))
  end

  @doc """
  Builds an ESI killmail response.
  """
  def esi_killmail_response(killmail_id \\ nil) do
    id = killmail_id || TestFactory.random_killmail_id()

    killmail = TestFactory.build_killmail(id)
    success_response(Jason.encode!(killmail))
  end

  # ============================================================================
  # WebSocket Test Helpers
  # ============================================================================

  @doc """
  Simulates joining a WebSocket channel.
  """
  def join_channel(socket, _topic, _payload \\ %{}) do
    ref = make_ref()
    # Return simulated join result
    {socket, ref}
  end

  @doc """
  Simulates leaving a WebSocket channel.
  """
  def leave_channel(socket, _topic) do
    ref = make_ref()
    # Return simulated leave result
    {socket, ref}
  end

  @doc """
  Waits for a specific message on a WebSocket.
  """
  def assert_push(event, payload \\ %{}, timeout \\ 100) do
    receive do
      {:push, ^event, received_payload} ->
        if payload == %{} do
          received_payload
        else
          assert received_payload == payload
          received_payload
        end
    after
      timeout ->
        flunk("Expected push #{event} but didn't receive it within #{timeout}ms")
    end
  end

  # ============================================================================
  # Test Data Assertions
  # ============================================================================

  @doc """
  Asserts that a killmail has the expected structure.
  """
  def assert_killmail_structure(killmail) do
    assert is_map(killmail)
    assert Map.has_key?(killmail, "killmail_id")
    assert Map.has_key?(killmail, "victim")
    assert Map.has_key?(killmail, "attackers")
    assert is_list(killmail["attackers"])
  end

  @doc """
  Asserts that an ESI response has valid structure.
  """
  def assert_esi_response_structure(response) do
    assert {:ok, data} = response
    assert is_map(data)
  end

  @doc """
  Asserts that a subscription filter is valid.
  """
  def assert_valid_subscription_filter(filter) do
    assert is_map(filter)

    if Map.has_key?(filter, :min_value) do
      assert is_number(filter.min_value)
    end

    if Map.has_key?(filter, :ship_types) do
      assert is_list(filter.ship_types)
      assert Enum.all?(filter.ship_types, &is_integer/1)
    end
  end
end
