defmodule WandererKills.MixProject do
  use Mix.Project

  def project do
    [
      app: :wanderer_kills,
      version: "1.4.2",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      compilers: Mix.compilers() ++ [:boundary],
      deps: deps(),
      description:
        "A standalone service for retrieving and caching EVE Online killmails from zKillboard",
      package: package(),
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),

      # Coverage configuration
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        test: :test,
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        "coveralls.xml": :test
      ],

      # Boundary configuration
      boundary: [
        default: [
          check: [
            apps: [:wanderer_kills, :wanderer_kills_web]
          ]
        ]
      ]
    ]
  end

  # The OTP application entrypoint:
  def application do
    [
      extra_applications: [
        :logger,
        :telemetry_poller
      ],
      mod: {WandererKills.Application, []}
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Phoenix framework (optional - can be excluded for headless operation)
      {:phoenix, "~> 1.7.14", optional: true},
      {:plug_cowboy, "~> 2.7", optional: true},

      # JSON parsing
      {:jason, "~> 1.4"},

      # Caching
      {:cachex, "~> 4.1"},

      # HTTP client with retry support
      {:req, "~> 0.5"},
      {:backoff, "~> 1.1"},

      # CSV parsing
      {:nimble_csv, "~> 1.3"},

      # Parallel processing
      {:flow, "~> 1.2"},

      # Telemetry
      {:telemetry_poller, "~> 1.2"},

      # Phoenix PubSub for real-time killmail distribution
      {:phoenix_pubsub, "~> 2.1"},

      # Server-Sent Events with PubSub integration
      {:sse_phoenix_pubsub, "~> 1.0"},

      # OpenAPI specification
      {:open_api_spex, "~> 3.18"},

      # Development and test tools
      {:credo, "~> 1.7.6", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4.3", only: [:dev], runtime: false},
      {:boundary, "~> 0.10", runtime: false},
      {:mox, "~> 1.2.0", only: :test},

      # Code coverage
      {:excoveralls, "~> 0.18", only: :test},

      # Property-based testing
      {:stream_data, "~> 1.2", only: [:test, :dev]}
    ]
  end

  defp package do
    [
      name: "wanderer_kills",
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/guarzo/wanderer_kills"}
    ]
  end

  defp aliases do
    [
      check: [
        "format --check-formatted",
        "credo",
        "dialyzer"
      ],
      "test.coverage": ["coveralls.html"],
      "test.coverage.ci": ["coveralls.json"],
      "test.headless": [
        "test --config config/test_headless.exs --require test/test_helper_headless.exs"
      ],
      "test.core": ["test.headless test/wanderer_kills/"],
      "test.perf": ["test --include perf test/performance/"]
    ]
  end
end
