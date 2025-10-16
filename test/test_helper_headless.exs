# Headless test helper that doesn't require Mox for web components
# This allows running core business logic tests without Phoenix dependencies

# Start ExUnit first
ExUnit.start()

# Only define mocks that are needed for core functionality
# Skip Mox setup if not available (headless mode)
if Code.ensure_loaded?(Mox) do
  # Define core mocks only
  Mox.defmock(WandererKills.Http.ClientMock,
    for: WandererKills.Http.ClientBehaviour
  )

  Mox.defmock(WandererKills.Ingest.Killmails.ZkbClient.Mock,
    for: WandererKills.Ingest.Killmails.ZkbClientBehaviour
  )

  # Mock for ESI client
  Mox.defmock(EsiClientMock, for: WandererKills.Ingest.ESI.ClientBehaviour)
end

# Start the application for testing in headless mode
System.put_env("WANDERER_KILLS_HEADLESS", "true")
{:ok, _} = Application.ensure_all_started(:wanderer_kills)

# Create a headless test case module that provides common setup
defmodule WandererKills.HeadlessTestCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      # Import common test utilities if available
      if Code.ensure_loaded?(WandererKills.TestHelpers) do
        import WandererKills.TestHelpers
      end

      if Code.ensure_loaded?(Mox) do
        import Mox
        # Setup mocks by default
        setup :verify_on_exit!
      end

      # Make common aliases available
      alias WandererKills.Core.Cache
    end
  end

  setup do
    # Set up unique test ID for ETS table isolation
    test_id = System.unique_integer([:positive])
    Process.put(:test_unique_id, test_id)

    # Clear any existing processes and caches if helper is available
    if Code.ensure_loaded?(WandererKills.TestHelpers) do
      alias WandererKills.TestHelpers
      TestHelpers.clear_all_caches()
    end

    # Clean up unique test tables on exit
    on_exit(fn ->
      # Simple cleanup - just clear any test-specific data
      if Code.ensure_loaded?(WandererKills.TestHelpers) do
        alias WandererKills.TestHelpers
        TestHelpers.clear_all_caches()
      end
    end)

    :ok
  end
end

# Configure ExUnit for parallel execution with proper test isolation
ExUnit.configure(parallel: true, max_cases: System.schedulers_online())
