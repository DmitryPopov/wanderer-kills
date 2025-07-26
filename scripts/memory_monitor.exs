#!/usr/bin/env elixir

# Memory Monitoring Script for WandererKills
# 
# Usage: elixir scripts/memory_monitor.exs [interval_seconds] [duration_minutes]
# Example: elixir scripts/memory_monitor.exs 10 5
#
# This script monitors memory usage patterns over time and generates a CSV report

defmodule MemoryMonitorScript do
  @default_interval 10  # seconds
  @default_duration 5   # minutes
  
  def run(args \\ []) do
    {interval, duration} = parse_args(args)
    
    IO.puts("Starting memory monitoring...")
    IO.puts("Interval: #{interval} seconds")
    IO.puts("Duration: #{duration} minutes")
    IO.puts("Output: memory_monitor_#{timestamp()}.csv")
    
    # Start the application if not already running
    ensure_application_started()
    
    # Open CSV file
    filename = "memory_monitor_#{timestamp()}.csv"
    {:ok, file} = File.open(filename, [:write])
    
    # Write CSV header
    write_csv_header(file)
    
    # Calculate iterations
    iterations = div(duration * 60, interval)
    
    # Run monitoring loop
    Enum.each(1..iterations, fn i ->
      data = collect_memory_data()
      write_csv_row(file, data)
      
      # Print progress
      progress = Float.round(i / iterations * 100, 1)
      IO.write("\rProgress: #{progress}%")
      
      if i < iterations do
        Process.sleep(interval * 1000)
      end
    end)
    
    File.close(file)
    IO.puts("\n\nMonitoring complete! Results saved to: #{filename}")
    
    # Generate summary
    generate_summary(filename)
  end
  
  defp parse_args([]) do
    {@default_interval, @default_duration}
  end
  
  defp parse_args([interval]) do
    {String.to_integer(interval), @default_duration}
  end
  
  defp parse_args([interval, duration | _]) do
    {String.to_integer(interval), String.to_integer(duration)}
  end
  
  defp ensure_application_started do
    case Application.ensure_all_started(:wanderer_kills) do
      {:ok, _} -> :ok
      {:error, _} -> 
        IO.puts("Warning: Could not start application. Some metrics may be unavailable.")
    end
  end
  
  defp collect_memory_data do
    # System memory
    memory_data = :erlang.memory()
    
    # ETS table info
    ets_tables = [
      :killmails,
      :system_killmails,
      :system_kill_counts,
      :system_fetch_timestamps,
      :character_subscription_index,
      :system_subscription_index
    ]
    
    ets_data = Enum.map(ets_tables, fn table ->
      case :ets.info(table) do
        :undefined -> {table, 0, 0}
        info -> 
          size = Keyword.get(info, :size, 0)
          memory = Keyword.get(info, :memory, 0) * :erlang.system_info(:wordsize)
          {table, size, memory}
      end
    end)
    
    # Process count by type
    processes = Process.list()
    process_info = Enum.map(processes, fn pid ->
      Process.info(pid, [:registered_name, :memory, :current_function])
    end)
    |> Enum.reject(&is_nil/1)
    
    genserver_count = Enum.count(process_info, &is_genserver?/1)
    websocket_count = Enum.count(process_info, &is_websocket?/1)
    
    # Build data map
    %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      total_mb: bytes_to_mb(memory_data[:total]),
      processes_mb: bytes_to_mb(memory_data[:processes]),
      ets_mb: bytes_to_mb(memory_data[:ets]),
      binary_mb: bytes_to_mb(memory_data[:binary]),
      atom_mb: bytes_to_mb(memory_data[:atom]),
      code_mb: bytes_to_mb(memory_data[:code]),
      process_count: length(processes),
      genserver_count: genserver_count,
      websocket_count: websocket_count
    }
    |> add_ets_data(ets_data)
  end
  
  defp add_ets_data(data, ets_data) do
    Enum.reduce(ets_data, data, fn {table, size, memory}, acc ->
      acc
      |> Map.put(:"#{table}_size", size)
      |> Map.put(:"#{table}_mb", bytes_to_mb(memory))
    end)
  end
  
  defp is_genserver?(proc_info) do
    case Keyword.get(proc_info, :registered_name) do
      nil -> false
      name ->
        name_str = Atom.to_string(name)
        String.contains?(name_str, "Server") or
        String.contains?(name_str, "Worker") or
        String.contains?(name_str, "Manager")
    end
  end
  
  defp is_websocket?(proc_info) do
    case Keyword.get(proc_info, :current_function) do
      {module, _, _} ->
        module_str = inspect(module)
        String.contains?(module_str, "Channel") or
        String.contains?(module_str, "Socket")
      _ -> false
    end
  end
  
  defp write_csv_header(file) do
    headers = [
      "timestamp",
      "total_mb",
      "processes_mb", 
      "ets_mb",
      "binary_mb",
      "atom_mb",
      "code_mb",
      "process_count",
      "genserver_count",
      "websocket_count",
      "killmails_size",
      "killmails_mb",
      "system_killmails_size",
      "system_killmails_mb",
      "character_subscription_index_size",
      "character_subscription_index_mb",
      "system_subscription_index_size",
      "system_subscription_index_mb"
    ]
    
    IO.write(file, Enum.join(headers, ",") <> "\n")
  end
  
  defp write_csv_row(file, data) do
    values = [
      data.timestamp,
      data.total_mb,
      data.processes_mb,
      data.ets_mb,
      data.binary_mb,
      data.atom_mb,
      data.code_mb,
      data.process_count,
      data.genserver_count,
      data.websocket_count,
      Map.get(data, :killmails_size, 0),
      Map.get(data, :killmails_mb, 0),
      Map.get(data, :system_killmails_size, 0),
      Map.get(data, :system_killmails_mb, 0),
      Map.get(data, :character_subscription_index_size, 0),
      Map.get(data, :character_subscription_index_mb, 0),
      Map.get(data, :system_subscription_index_size, 0),
      Map.get(data, :system_subscription_index_mb, 0)
    ]
    
    IO.write(file, Enum.join(values, ",") <> "\n")
  end
  
  defp generate_summary(filename) do
    # Read the CSV and calculate statistics
    {:ok, content} = File.read(filename)
    lines = String.split(content, "\n", trim: true)
    
    if length(lines) > 1 do
      # Skip header
      data_lines = Enum.drop(lines, 1)
      
      # Parse numeric columns (indices 1-17)
      parsed_data = Enum.map(data_lines, fn line ->
        String.split(line, ",")
        |> Enum.drop(1)  # Skip timestamp
        |> Enum.map(&parse_float/1)
      end)
      
      if length(parsed_data) > 0 do
        # Calculate statistics for each column
        stats = Enum.map(0..16, fn col_idx ->
          values = Enum.map(parsed_data, fn row -> Enum.at(row, col_idx, 0) end)
          |> Enum.filter(&is_number/1)
          
          if length(values) > 0 do
            %{
              min: Enum.min(values),
              max: Enum.max(values),
              avg: Float.round(Enum.sum(values) / length(values), 2)
            }
          else
            %{min: 0, max: 0, avg: 0}
          end
        end)
        
        IO.puts("\n=== Memory Monitoring Summary ===")
        IO.puts("\nSystem Memory (MB):")
        IO.puts("  Total: Min=#{Enum.at(stats, 0).min}, Max=#{Enum.at(stats, 0).max}, Avg=#{Enum.at(stats, 0).avg}")
        IO.puts("  Processes: Min=#{Enum.at(stats, 1).min}, Max=#{Enum.at(stats, 1).max}, Avg=#{Enum.at(stats, 1).avg}")
        IO.puts("  ETS: Min=#{Enum.at(stats, 2).min}, Max=#{Enum.at(stats, 2).max}, Avg=#{Enum.at(stats, 2).avg}")
        
        IO.puts("\nProcess Counts:")
        IO.puts("  Total: Min=#{Enum.at(stats, 6).min}, Max=#{Enum.at(stats, 6).max}, Avg=#{Enum.at(stats, 6).avg}")
        IO.puts("  GenServers: Min=#{Enum.at(stats, 7).min}, Max=#{Enum.at(stats, 7).max}, Avg=#{Enum.at(stats, 7).avg}")
        IO.puts("  WebSockets: Min=#{Enum.at(stats, 8).min}, Max=#{Enum.at(stats, 8).max}, Avg=#{Enum.at(stats, 8).avg}")
        
        IO.puts("\nKillmail Storage:")
        IO.puts("  Entries: Min=#{Enum.at(stats, 9).min}, Max=#{Enum.at(stats, 9).max}, Avg=#{Enum.at(stats, 9).avg}")
        IO.puts("  Memory (MB): Min=#{Enum.at(stats, 10).min}, Max=#{Enum.at(stats, 10).max}, Avg=#{Enum.at(stats, 10).avg}")
      end
    end
  end
  
  defp parse_float(str) do
    case Float.parse(str) do
      {num, _} -> num
      :error -> 0
    end
  end
  
  defp bytes_to_mb(bytes) when is_number(bytes) do
    Float.round(bytes / 1024 / 1024, 2)
  end
  
  defp bytes_to_mb(_), do: 0.0
  
  defp timestamp do
    DateTime.utc_now()
    |> DateTime.to_iso8601()
    |> String.replace(~r/[:\s]/, "_")
    |> String.replace(~r/\.\d+Z$/, "")
  end
end

# Run the script
MemoryMonitorScript.run(System.argv())