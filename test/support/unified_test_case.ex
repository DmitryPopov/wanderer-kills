defmodule WandererKills.UnifiedTestCase do
  @moduledoc """
  Unified test case module that consolidates functionality from TestCase, DataCase,
  IntegrationCase, ConnCase, and ChannelCase into a single configurable module.

  ## Usage

  ```elixir
  use WandererKills.UnifiedTestCase

  # Or with options:
  use WandererKills.UnifiedTestCase,
    async: true,
    type: :channel,
    mocks: true,
    clear_indexes: true,
    clear_subscriptions: true
  ```

  ## Options

  - `:async` - Run tests asynchronously (default: true)
  - `:type` - Test type (:unit, :integration, :conn, :channel) (default: :unit)
  - `:mocks` - Setup mocks (default: true for non-conn/channel tests)
  - `:clear_indexes` - Clear subscription indexes before test (default: false)
  - `:clear_subscriptions` - Clear all subscriptions before test (default: false)
  - `:clear_caches` - Clear all caches before test (default: true)
  """

  use ExUnit.CaseTemplate

  alias WandererKills.TestFactory

  using options do
    # Extract options with defaults
    test_type = Keyword.get(options, :type, :unit)
    async = Keyword.get(options, :async, true)

    # Default mocks to true for unit/integration tests, false for conn/channel
    default_mocks = test_type not in [:conn, :channel]
    setup_mocks = Keyword.get(options, :mocks, default_mocks)

    clear_indexes = Keyword.get(options, :clear_indexes, false)
    clear_subscriptions = Keyword.get(options, :clear_subscriptions, false)
    clear_caches = Keyword.get(options, :clear_caches, true)

    quote do
      use ExUnit.Case, async: unquote(async)

      # Common imports for all test types
      import WandererKills.TestHelpers
      import WandererKills.TestFactory
      import Mox

      # Common aliases
      alias WandererKills.Core.Cache
      alias WandererKills.TestFactory
      alias WandererKills.TestHelpers

      # Set endpoint and imports based on test type
      unquote(
        case test_type do
          :conn ->
            quote do
              @endpoint WandererKillsWeb.Endpoint
              use ExUnit.Case, async: unquote(async)
              import Plug.Conn
              import Phoenix.ConnTest
              import WandererKills.UnifiedTestCase
            end

          :channel ->
            quote do
              @endpoint WandererKillsWeb.Endpoint
              import Phoenix.ChannelTest
              import WandererKills.UnifiedTestCase
            end

          _ ->
            quote do
              import WandererKills.TestContexts
            end
        end
      )

      # Setup hooks based on options
      setup :verify_on_exit!

      setup context do
        # Build setup options from test configuration
        setup_opts = [
          type: unquote(test_type),
          mocks: unquote(setup_mocks),
          clear_indexes: unquote(clear_indexes),
          clear_subscriptions: unquote(clear_subscriptions),
          clear_caches: unquote(clear_caches)
        ]

        WandererKills.UnifiedTestCase.setup_test_environment(context, setup_opts)
      end
    end
  end

  @doc """
  Unified setup function that configures the test environment based on options.
  """
  def setup_test_environment(context, opts) do
    # Set up unique test environment
    unique_id = System.unique_integer([:positive])
    Process.put(:test_unique_id, unique_id)

    # Perform setup operations
    perform_setup_operations(context, opts)

    # Build base context
    base_context = %{test_id: unique_id}

    # Add type-specific context
    add_type_specific_context(base_context, opts[:type])
  end

  defp perform_setup_operations(context, opts) do
    # Configure mox mode
    unless opts[:mox_mode] == :global do
      # Private mode is the default in ExUnit
    end

    # Clear caches if requested
    if opts[:clear_caches] do
      WandererKills.TestHelpers.clear_all_caches()
    end

    # Setup mocks if requested and not disabled in context
    if opts[:mocks] && !context[:no_mocks] do
      WandererKills.TestHelpers.setup_mocks()
    end

    # Clear subscription resources
    clear_subscription_resources(opts)
  end

  defp clear_subscription_resources(opts) do
    alias WandererKills.Subs.SimpleSubscriptionManager
    alias WandererKills.Subs.{CharacterIndex, SystemIndex}

    # Clear subscription indexes if requested
    if opts[:clear_indexes] do
      safe_clear(fn -> CharacterIndex.clear() end)
      safe_clear(fn -> SystemIndex.clear() end)
    end

    # Clear all subscriptions if requested
    if opts[:clear_subscriptions] do
      safe_clear(fn -> SimpleSubscriptionManager.clear_all_subscriptions() end)
    end
  end

  defp add_type_specific_context(base_context, type) do
    case type do
      :conn ->
        Map.put(base_context, :conn, Phoenix.ConnTest.build_conn())

      :channel ->
        # Channel tests get socket setup in their specific test files
        base_context

      :integration ->
        Map.merge(base_context, %{
          killmail_data: TestFactory.build_killmail(TestFactory.random_killmail_id()),
          system_id: TestFactory.random_system_id(),
          character_id: TestFactory.random_character_id()
        })

      _ ->
        base_context
    end
  end

  # Helper to safely execute cleanup functions that might fail
  defp safe_clear(fun) do
    fun.()
  rescue
    _ -> :ok
  end
end
