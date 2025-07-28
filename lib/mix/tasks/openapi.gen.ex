defmodule Mix.Tasks.Openapi.Gen do
  @moduledoc """
  Mix task to generate OpenAPI specification without starting the server.

  This is useful for CI environments where starting the full Phoenix server
  might be problematic due to environment constraints.

  ## Usage

      mix openapi.gen [--output FILE]

  ## Options

    * `--output` - Output file path (default: "openapi.json")

  """

  use Mix.Task

  @shortdoc "Generate OpenAPI specification"

  @impl Mix.Task
  def run(args) do
    # Parse command line arguments
    {opts, _argv, _} = OptionParser.parse(args, switches: [output: :string])
    output_file = opts[:output] || "openapi.json"

    # Start minimal required applications
    try do
      Application.ensure_all_started(:logger)
      Application.ensure_all_started(:jason)
    rescue
      error ->
        IO.puts("Failed to start required applications: #{inspect(error)}")
        IO.puts("Error details: #{Exception.message(error)}")
        exit(1)
    end

    # Generate the OpenAPI specification
    try do
      spec = WandererKillsWeb.ApiSpec.spec()
      json_spec = Jason.encode!(spec, pretty: true)

      # Write to file
      File.write!(output_file, json_spec)

      IO.puts("OpenAPI specification generated: #{output_file}")
      IO.puts("Specification contains #{map_size(spec.paths)} paths")
    rescue
      error ->
        IO.puts("Failed to generate OpenAPI specification: #{inspect(error)}")
        IO.puts("Error details: #{Exception.message(error)}")
        exit(1)
    end
  end
end
