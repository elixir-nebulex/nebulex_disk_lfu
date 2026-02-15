defmodule NebulexDiskLFU.MixProject do
  use Mix.Project

  @source_url "https://github.com/elixir-nebulex/nebulex_disk_lfu"
  @version "3.0.0-dev"
  # @nbx_version "3.0.0"

  def project do
    [
      app: :nebulex_disk_lfu,
      version: @version,
      elixir: "~> 1.14",
      aliases: aliases(),
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),

      # Testing
      test_coverage: [tool: ExCoveralls],

      # Dialyzer
      dialyzer: dialyzer(),

      # Usage Rules
      usage_rules: usage_rules(),

      # Hex
      package: package(),
      description: "Persistent disk-based cache adapter with LFU eviction for Nebulex",

      # Docs
      name: "Nebulex.Adapters.DiskLFU",
      docs: docs()
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "test.ci": :test
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:nebulex, github: "elixir-nebulex/nebulex", branch: "main"},
      {:nebulex_local, github: "elixir-nebulex/nebulex_local", branch: "main"},
      {:nimble_options, "~> 0.5 or ~> 1.0"},
      {:telemetry, "~> 0.4 or ~> 1.0", optional: true},

      # Test & Code Analysis
      {:excoveralls, "~> 0.18", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:briefly, "~> 0.5", only: [:dev, :test]},
      {:mimic, "~> 2.0", only: :test},

      # Benchmark Test
      {:benchee, "~> 1.5", only: [:dev, :test]},
      {:benchee_html, "~> 1.0", only: [:dev, :test]},

      # Docs
      {:ex_doc, "~> 0.40", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      "test.ci": [
        "deps.unlock --check-unused",
        "compile --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "coveralls.html",
        "sobelow -i Traversal.FileModule --exit --skip",
        "dialyzer --format short"
      ],
      "ur.sync": ["usage_rules.sync"]
    ]
  end

  defp package do
    [
      name: :nebulex_disk_lfu,
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README* CHANGELOG* LICENSE*)
    ]
  end

  defp docs do
    [
      main: "Nebulex.Adapters.DiskLFU",
      source_ref: "v#{@version}",
      canonical: "https://hexdocs.pm/nebulex_disk_lfu",
      source_url: @source_url,
      extra_section: "GUIDES",
      extras: extras()
    ]
  end

  defp extras do
    [
      # Learning
      "guides/learning/architecture.md"
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:nebulex],
      plt_file: {:no_warn, "priv/plts/" <> plt_file_name()},
      flags: [
        :error_handling,
        :extra_return,
        :no_opaque,
        :no_return
      ]
    ]
  end

  defp plt_file_name do
    "dialyzer-#{Mix.env()}-#{System.version()}-#{System.otp_release()}.plt"
  end

  defp usage_rules do
    [
      # The file to write usage rules into (required for usage_rules syncing)
      file: "AGENTS.md",

      # rules to include directly in CLAUDE.md
      usage_rules: ["nebulex:all"],

      # Agent skills configuration
      skills: [
        # The location of the skills directory
        location: ".claude/skills",

        # Auto-build a "use-<pkg>" skill per dependency
        deps: [:nebulex]
      ]
    ]
  end
end
