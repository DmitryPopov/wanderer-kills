ExUnit.start()

# Standard Mox setup
Application.ensure_all_started(:mox)

# Define mocks
Mox.defmock(WandererKills.Ingest.Http.Client.Mock,
  for: WandererKills.Ingest.Http.ClientBehaviour
)

Mox.defmock(WandererKills.Ingest.Killmails.ZkbClient.Mock,
  for: WandererKills.Ingest.Killmails.ZkbClientBehaviour
)

Mox.defmock(EsiClientMock, for: WandererKills.Ingest.ESI.ClientBehaviour)

# Remove the incorrect stub_with line

# Start the application for testing
{:ok, _} = Application.ensure_all_started(:wanderer_kills)

# Test support modules are auto-loaded by Mix

# Create a test case module that provides common setup for all tests
defmodule WandererKills.TestCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      # Import common test utilities
      import WandererKills.TestHelpers
      import WandererKills.TestFactory
      import Mox

      # Setup mocks by default
      setup :verify_on_exit!
      setup {WandererKills.TestSetup, :setup_unique_environment}

      # Make common aliases available
      alias WandererKills.Core.Cache
      alias WandererKills.TestFactory
      alias WandererKills.TestHelpers
    end
  end
end

# Setup function definitions that can be shared across test modules
defmodule WandererKills.TestSetup do
  @doc """
  Sets up a unique test environment with Mox private mode and cache clearing.
  """
  def setup_unique_environment(_context) do
    # Set Mox to private mode for this test process
    Mox.set_mox_private()

    # Set up unique test environment
    unique_id = System.unique_integer([:positive])
    Process.put(:test_unique_id, unique_id)

    # Clear any existing processes and caches
    WandererKills.TestHelpers.clear_all_caches()

    %{test_id: unique_id}
  end

  @doc """
  Sets up a data case environment with additional features.
  """
  def setup_data_environment(context) do
    alias WandererKills.Subs.SubscriptionManager
    alias WandererKills.Subs.Subscriptions.{CharacterIndex, SystemIndex}

    # Set Mox to private mode for this test process
    Mox.set_mox_private()

    # Set up unique test environment
    unique_id = System.unique_integer([:positive])
    Process.put(:test_unique_id, unique_id)

    # Clear caches on setup
    WandererKills.TestHelpers.clear_all_caches()

    # Setup mocks if not disabled
    if !context[:no_mocks] do
      WandererKills.TestHelpers.setup_mocks()
    end

    # Clear subscription indexes if needed
    if context[:clear_indexes] do
      try do
        CharacterIndex.clear()
        SystemIndex.clear()
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    # Clear all subscriptions if needed
    if context[:clear_subscriptions] do
      try do
        SubscriptionManager.clear_all_subscriptions()
      rescue
        # Ignore if the function doesn't exist
        UndefinedFunctionError -> :ok
      end
    end

    %{test_id: unique_id}
  end

  @doc """
  Sets up an integration test environment with all features enabled.
  """
  def setup_integration_environment(_context) do
    alias WandererKills.Subs.Subscriptions.{CharacterIndex, SystemIndex}

    # Set Mox to private mode
    Mox.set_mox_private()

    # Set up unique test environment with all features
    unique_id = System.unique_integer([:positive])
    Process.put(:test_unique_id, unique_id)

    # Full cleanup and setup
    WandererKills.TestHelpers.clear_all_caches()

    # Always set up mocks for integration tests
    WandererKills.TestHelpers.setup_mocks()

    # Clear indexes and subscriptions
    try do
      CharacterIndex.clear()
      SystemIndex.clear()
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    # Provide common integration test context
    %{
      test_id: unique_id,
      killmail_data:
        WandererKills.TestFactory.build_killmail(WandererKills.TestFactory.random_killmail_id()),
      system_id: WandererKills.TestFactory.random_system_id(),
      character_id: WandererKills.TestFactory.random_character_id()
    }
  end
end

# Create a data case module for tests that need application supervision
defmodule WandererKills.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      # Import common test utilities
      import WandererKills.TestHelpers
      import WandererKills.Test.SharedContexts
      import WandererKills.Test.HttpHelpers
      import WandererKills.TestFactory
      import Mox

      # Setup mocks by default
      setup :verify_on_exit!
      setup {WandererKills.TestSetup, :setup_data_environment}

      # Make common aliases available
      alias WandererKills.Core.Cache
      alias WandererKills.TestFactory
      alias WandererKills.TestHelpers
    end
  end
end

# Create an enhanced case for integration tests
defmodule WandererKills.IntegrationCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      # Import all test utilities
      import WandererKills.TestHelpers
      import WandererKills.Test.SharedContexts
      import WandererKills.Test.HttpHelpers
      import WandererKills.TestFactory
      import Mox

      # Setup mocks and unique environment
      setup :verify_on_exit!
      setup {WandererKills.TestSetup, :setup_integration_environment, []}

      # Make all aliases available
      alias WandererKills.Core.Cache
      alias WandererKills.TestFactory
      alias WandererKills.TestHelpers
    end
  end
end

# Set up global mocks - do not stub with real implementation to allow proper mocking in tests
# Mox.stub_with(WandererKills.Ingest.Http.Client.Mock, WandererKills.Ingest.Http.Client)
# Mox.stub_with(WandererKills.Zkb.Client.Mock, WandererKills.Ingest.Killmails.ZkbClient)

# Configure ExUnit for parallel execution and exclude performance tests by default
ExUnit.configure(
  parallel: true,
  max_cases: System.schedulers_online() * 2,
  exclude: [:perf],
  enricher: WandererKills.MockEnricher
)

# Note: Cache clearing functionality is now available via WandererKills.TestHelpers.clear_all_caches()
