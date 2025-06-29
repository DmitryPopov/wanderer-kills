defmodule WandererKills.Test.SharedContexts do
  @moduledoc """
  Shared test contexts to eliminate setup/teardown duplication.

  This module provides reusable test setups that can be included
  in any test module to reduce boilerplate.

  ## Usage

  ```elixir
  defmodule MyTest do
    use WandererKills.DataCase
    use WandererKills.Test.SharedContexts

    describe "with cache" do
      setup :with_cache

      test "can use cache", %{cache: cache} do
        # cache is available here
      end
    end
  end
  ```
  """

  import Cachex.Spec
  import ExUnit.Callbacks

  alias WandererKills.Core.Storage.KillmailStore
  alias WandererKills.Ingest.Http.Client.Mock, as: HttpClientMock
  alias WandererKills.Test.EtsHelpers
  alias WandererKills.TestHelpers

  # Mock modules defined in test_helper.exs
  alias EsiClientMock

  defmacro __using__(_opts) do
    quote do
      import WandererKills.Test.SharedContexts
      import Cachex.Spec
    end
  end

  @doc """
  Ensures the :wanderer_cache is available for tests.

  This function checks if the cache exists and starts it if needed.
  """
  def ensure_cache_available do
    # Check if cache process is running by looking for it in the registry
    case Process.whereis(:wanderer_cache) do
      nil ->
        # Start the cache manually for tests
        opts = [
          default_ttl: :timer.minutes(5),
          expiration:
            expiration(
              interval: :timer.seconds(60),
              default: :timer.minutes(5),
              lazy: true
            ),
          hooks: [
            hook(module: Cachex.Stats)
          ]
        ]

        start_cache_and_setup_teardown(opts)

      _pid ->
        :ok
    end
  end

  defp start_cache_and_setup_teardown(opts) do
    case Cachex.start_link(:wanderer_cache, opts) do
      {:ok, pid} ->
        setup_new_cache(pid)

      {:error, {:already_started, _pid}} ->
        :ok

      :ignore ->
        :ok
    end
  end

  defp setup_new_cache(pid) do
    # Give cache time to fully initialize
    Process.sleep(50)

    # Add teardown callback to stop cache after tests
    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    :ok
  end

  @doc """
  Sets up a clean cache instance for testing.

  Returns:
  - `%{cache: cache_name}` - The cache instance name
  """
  def with_cache(_context \\ %{}) do
    cache_name = Module.safe_concat([TestCache, System.unique_integer()])

    {:ok, _pid} = Cachex.start_link(cache_name)

    on_exit(fn ->
      if Process.whereis(cache_name) do
        Supervisor.stop(cache_name)
      end
    end)

    %{cache: cache_name}
  end

  @doc """
  Sets up a clean test environment with cache clearing.

  This is the most commonly used setup function.
  """
  def with_clean_environment(_context \\ %{}) do
    ensure_cache_available()
    TestHelpers.clear_all_caches()
    %{}
  end

  @doc """
  Sets up a clean KillStore for testing.

  Returns:
  - `%{}` - Empty context (KillStore is global)
  """
  def with_kill_store(_context \\ %{}) do
    # Ensure tables exist before clearing
    KillmailStore.init_tables!()
    :ok = KillmailStore.clear()
    %{}
  end

  @doc """
  Sets up unique ETS tables for parallel testing.

  Creates test-specific ETS table names to avoid conflicts
  between parallel test runs.

  Returns:
  - `%{test_id: unique_id}` - Unique test identifier
  """
  def with_unique_tables(_context \\ %{}) do
    unique_id = System.unique_integer([:positive])
    test_pid = self()

    # Store the unique ID in the process dictionary for easy access
    Process.put(:test_unique_id, unique_id)

    on_exit(fn ->
      # Clean up any test-specific tables when test exits
      cleanup_unique_tables(unique_id)
    end)

    %{test_id: unique_id, test_pid: test_pid}
  end

  @doc """
  Comprehensive test setup combining common requirements.

  This function sets up:
  - Clean caches
  - Clean KillStore
  - HTTP mocks
  - Test data

  Returns all context from individual setups.
  """
  def with_full_test_setup(context) do
    context
    |> Map.merge(with_clean_environment())
    |> Map.merge(with_kill_store())
    |> Map.merge(with_http_mocks())
    |> Map.merge(with_test_data())
  end

  @doc """
  Sets up mock HTTP clients for testing.

  Returns:
  - `%{http_mock: mock, esi_mock: mock}` - The HTTP mock modules
  """
  def with_http_mocks(_context \\ %{}) do
    # Use verify_on_exit to ensure all expectations are called
    Mox.verify_on_exit!()

    # Set up default stubs for common cases
    setup_default_http_stubs()
    setup_default_esi_stubs()

    %{
      http_mock: HttpClientMock,
      esi_mock: EsiClientMock
    }
  end

  @doc """
  Sets up mock HTTP clients with specific expectations.

  Options:
  - `:expect_esi_calls` - Boolean, whether to expect ESI calls (default: false)
  - `:expect_http_calls` - Boolean, whether to expect HTTP calls (default: false)
  - `:zkb_response` - Mock response for ZKB calls
  - `:esi_responses` - Map of ESI endpoint responses

  Returns:
  - `%{http_mock: mock, esi_mock: mock}` - The HTTP mock modules
  """
  def with_configured_http_mocks(context) do
    base_context = with_http_mocks(context)

    # Configure specific expectations based on options
    if context[:expect_esi_calls] do
      setup_esi_expectations(context[:esi_responses] || %{})
    end

    if context[:expect_http_calls] do
      setup_http_expectations(context[:zkb_response])
    end

    base_context
  end

  @doc """
  Sets up a test database with sample data.

  Returns:
  - `%{test_data: data}` - Map of test data
  """
  def with_test_data(_context \\ %{}) do
    test_data = %{
      killmail: build_test_killmail(),
      system: build_test_system(),
      character: build_test_character(),
      corporation: build_test_corporation(),
      alliance: build_test_alliance()
    }

    %{test_data: test_data}
  end

  @doc """
  Sets up a supervised GenServer for testing.

  Options:
  - `:module` - The GenServer module to start
  - `:args` - Arguments to pass to start_link

  Returns:
  - `%{server: pid}` - The GenServer PID
  """
  def with_supervised_server(context) do
    module = context[:module] || raise "Must specify :module"
    args = context[:args] || []

    {:ok, pid} = start_supervised({module, args})

    %{server: pid}
  end

  @doc """
  Sets up a supervised GenServer with a unique name for parallel testing.

  Options:
  - `:module` - The GenServer module to start
  - `:name` - Base name for the server (will be made unique)
  - `:args` - Arguments to pass to start_link

  Returns:
  - `%{server: pid, server_name: unique_name}` - The GenServer PID and unique name
  """
  def with_unique_supervised_server(context) do
    module = context[:module] || raise "Must specify :module"
    base_name = context[:name] || module
    args = context[:args] || []

    # Create unique name for this test
    test_id = EtsHelpers.get_test_id()
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    unique_name = String.to_atom("#{base_name}_test_#{test_id}")

    # Add the unique name to the args if it's a keyword list
    final_args =
      case args do
        [_ | _] = keyword_args when is_list(keyword_args) ->
          Keyword.put(keyword_args, :name, unique_name)

        _ ->
          [name: unique_name] ++ List.wrap(args)
      end

    {:ok, pid} = start_supervised({module, final_args})

    %{server: pid, server_name: unique_name}
  end

  @doc """
  Sets up Phoenix PubSub for testing.

  Returns:
  - `%{pubsub: pubsub_name}` - The PubSub instance name
  """
  def with_pubsub(_context \\ %{}) do
    test_id = EtsHelpers.get_test_id()
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    pubsub_name = String.to_atom("TestPubSub_#{test_id}")

    {:ok, _pid} =
      Phoenix.PubSub.Supervisor.start_link(
        name: pubsub_name,
        adapter: Phoenix.PubSub.PG2
      )

    on_exit(fn ->
      # PubSub will be stopped automatically when test process exits
      :ok
    end)

    %{pubsub: pubsub_name}
  end

  @doc """
  Sets up WebSocket connection for testing.

  Returns:
  - `%{socket: socket, channel: channel}` - Connected socket and channel
  """
  def with_websocket_connection(context) do
    pubsub = context[:pubsub] || WandererKills.PubSub

    socket = %Phoenix.Socket{
      endpoint: WandererKillsWeb.Endpoint,
      pubsub_server: pubsub,
      transport: :websocket,
      serializer: Phoenix.Socket.V2.JSONSerializer
    }

    # Simulate connect_info for testing
    connect_info = %{
      peer_data: %{address: {127, 0, 0, 1}, port: 12_345},
      x_headers: []
    }

    {:ok, connected_socket} = WandererKillsWeb.UserSocket.connect(%{}, socket, connect_info)
    %{socket: connected_socket, channel: "killmails:lobby"}
  end

  # Private helper functions

  defp build_test_killmail do
    %{
      "killmail_id" => 123_456_789,
      "kill_time" => "2024-01-01T12:00:00Z",
      "solar_system_id" => 30_000_142,
      "victim" => %{
        "character_id" => 95_465_499,
        "corporation_id" => 1_000_009,
        "alliance_id" => 1_354_830_081,
        "ship_type_id" => 587,
        "damage_taken" => 1337
      },
      "attackers" => [
        %{
          "character_id" => 95_465_500,
          "corporation_id" => 1_000_010,
          "alliance_id" => nil,
          "ship_type_id" => 17_619,
          "weapon_type_id" => 2488,
          "damage_done" => 1337,
          "final_blow" => true
        }
      ],
      "zkb" => %{
        "totalValue" => 10_000_000.0,
        "points" => 10,
        "npc" => false,
        "hash" => "abcdef123456"
      }
    }
  end

  defp build_test_system do
    %{
      "system_id" => 30_000_142,
      "name" => "Jita",
      "security" => 0.9
    }
  end

  defp build_test_character do
    %{
      "character_id" => 95_465_499,
      "name" => "Test Character",
      "corporation_id" => 1_000_009
    }
  end

  defp build_test_corporation do
    %{
      "corporation_id" => 1_000_009,
      "name" => "Test Corporation",
      "ticker" => "TEST"
    }
  end

  defp build_test_alliance do
    %{
      "alliance_id" => 1_354_830_081,
      "name" => "Test Alliance",
      "ticker" => "TESTA"
    }
  end

  # Private HTTP mocking helper functions

  defp setup_default_http_stubs do
    # No longer setting up global stubs for better test isolation
    # Tests should use explicit expectations with WandererKills.Test.HttpHelpers.expect_http_* functions
    :ok
  end

  defp setup_default_esi_stubs do
    # Default ESI stubs for common test scenarios
    # These return basic success responses to prevent test failures
    :ok
  end

  defp setup_esi_expectations(responses) when is_map(responses) do
    # Set up specific ESI expectations based on provided responses
    # This would iterate through the responses map and set up Mox expectations
    :ok
  end

  defp setup_http_expectations(_zkb_response) do
    # Set up ZKB HTTP expectations
    # This would configure the HTTP mock to return the specified response
    :ok
  end

  # Cleans up test-specific ETS tables by unique ID.
  defp cleanup_unique_tables(unique_id) do
    # Generate the table names that would have been created for this test
    # credo:disable-for-lines:8 Credo.Check.Warning.UnsafeToAtom
    test_table_names = [
      String.to_atom("killmails_#{unique_id}"),
      String.to_atom("system_killmails_#{unique_id}"),
      String.to_atom("system_kill_counts_#{unique_id}"),
      String.to_atom("system_fetch_timestamps_#{unique_id}"),
      String.to_atom("killmail_events_#{unique_id}"),
      String.to_atom("client_offsets_#{unique_id}"),
      String.to_atom("counters_#{unique_id}")
    ]

    # Delete each table if it exists
    Enum.each(test_table_names, fn table_name ->
      case :ets.info(table_name) do
        :undefined -> :ok
        _ -> :ets.delete(table_name)
      end
    end)

    :ok
  end
end
