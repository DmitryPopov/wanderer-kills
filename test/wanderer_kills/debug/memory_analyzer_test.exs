defmodule WandererKills.Debug.MemoryAnalyzerTest do
  use ExUnit.Case, async: true

  alias WandererKills.Debug.MemoryAnalyzer

  describe "analyze/0" do
    test "returns comprehensive memory analysis" do
      analysis = MemoryAnalyzer.analyze()

      assert is_map(analysis)
      assert Map.has_key?(analysis, :timestamp)
      assert Map.has_key?(analysis, :system)
      assert Map.has_key?(analysis, :ets_tables)
      assert Map.has_key?(analysis, :processes)
      assert Map.has_key?(analysis, :caches)
      assert Map.has_key?(analysis, :subscriptions)
      assert Map.has_key?(analysis, :recommendations)
    end

    test "system memory includes all components" do
      %{system: system} = MemoryAnalyzer.analyze()

      assert Map.has_key?(system, :total_mb)
      assert Map.has_key?(system, :processes_mb)
      assert Map.has_key?(system, :ets_mb)
      assert Map.has_key?(system, :binary_mb)
      assert Map.has_key?(system, :atom_mb)
      assert Map.has_key?(system, :code_mb)

      # All values should be non-negative
      Enum.each(system, fn {_key, value} ->
        assert value >= 0
      end)
    end

    test "ETS analysis includes core tables" do
      %{ets_tables: tables} = MemoryAnalyzer.analyze()

      assert is_list(tables)

      # Check for core tables
      table_names = Enum.map(tables, & &1.name)
      assert :killmails in table_names
      assert :system_killmails in table_names
      assert :character_subscription_index in table_names
      assert :system_subscription_index in table_names
    end

    test "process analysis categorizes correctly" do
      %{processes: processes} = MemoryAnalyzer.analyze()

      assert Map.has_key?(processes, :total_count)
      assert Map.has_key?(processes, :top_consumers)
      assert Map.has_key?(processes, :by_category)
      assert Map.has_key?(processes, :genserver_memory_mb)
      assert Map.has_key?(processes, :websocket_memory_mb)
      assert Map.has_key?(processes, :supervisor_memory_mb)

      assert processes.total_count > 0
      assert is_list(processes.top_consumers)
    end
  end

  describe "compare_with_baseline/0" do
    test "returns comparison structure" do
      comparison = MemoryAnalyzer.compare_with_baseline()

      assert Map.has_key?(comparison, :current)
      assert Map.has_key?(comparison, :baseline)
      assert Map.has_key?(comparison, :savings)
      assert Map.has_key?(comparison, :improvements)
    end

    test "calculates meaningful savings" do
      %{savings: savings} = MemoryAnalyzer.compare_with_baseline()

      assert Map.has_key?(savings, :estimated_baseline_mb)
      assert Map.has_key?(savings, :current_mb)
      assert Map.has_key?(savings, :saved_mb)
      assert Map.has_key?(savings, :percentage_saved)

      # Should show positive savings from consolidation
      assert savings.saved_mb > 0
      assert savings.percentage_saved > 0
    end
  end

  describe "report/0" do
    test "generates report without errors" do
      # Capture IO to avoid cluttering test output
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          analysis = MemoryAnalyzer.report()
          assert is_map(analysis)
        end)

      # Verify report sections are present
      assert output =~ "WandererKills Memory Analysis Report"
      assert output =~ "System Memory Summary"
      assert output =~ "ETS Table Memory Usage"
      assert output =~ "Process Memory Summary"
      assert output =~ "Recommendations"
    end
  end

  describe "memory efficiency calculations" do
    test "identifies high memory per entry correctly" do
      # Test the private check_ets_efficiency function indirectly
      analysis = MemoryAnalyzer.analyze()

      # Verify ETS tables have reasonable memory per entry
      Enum.each(analysis.ets_tables, fn table ->
        if table[:exists] && table[:size] && table[:size] > 0 do
          bytes_per_entry = table[:memory_mb] * 1024 * 1024 / table[:size]

          # Most entries should be under 10KB
          case table.name do
            :killmails -> assert bytes_per_entry < 10_000
            :system_killmails -> assert bytes_per_entry < 1_000
            :character_subscription_index -> assert bytes_per_entry < 500
            :system_subscription_index -> assert bytes_per_entry < 500
            _ -> :ok
          end
        end
      end)
    end
  end
end
