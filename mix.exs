defmodule NebulexDiskLFU.MixProject do
  use Mix.Project

  @source_url "http://github.com/elixir-nebulex/nebulex_disk_lfu"
  @version "3.0.0-rc.1"

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
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "test.ci": :test
      ],

      # Dialyzer
      dialyzer: dialyzer(),

      # Hex
      package: package(),
      description: "A Nebulex adapter for DiskLFU",

      # Docs
      docs: [
        main: "Nebulex.Adapters.DiskLFU",
        source_ref: "v#{@version}",
        source_url: @source_url
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:nebulex, "~> 3.0.0-rc.1"},
      {:nimble_options, "~> 0.5 or ~> 1.0"},
      {:telemetry, "~> 0.4 or ~> 1.0", optional: true},

      # Test & Code Analysis
      {:excoveralls, "~> 0.18", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:briefly, "~> 0.5", only: [:dev, :test]},
      {:mimic, "~> 1.7", only: :test},

      # Benchmark Test
      {:benchee, "~> 1.3", only: [:dev, :test]},
      {:benchee_html, "~> 1.0", only: [:dev, :test]},

      # Docs
      {:ex_doc, "~> 0.36", only: [:dev, :test], runtime: false}
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
      ]
    ]
  end

  defp package do
    [
      name: :nebulex_disk_lfu,
      maintainers: [
        "Carlos Bolanos"
      ],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README* CHANGELOG* LICENSE*)
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:nebulex],
      plt_file: {:no_warn, "priv/plts/" <> plt_file_name()},
      flags: [
        :error_handling,
        :no_opaque,
        :unknown,
        :no_return
      ]
    ]
  end

  defp plt_file_name do
    "dialyzer-#{Mix.env()}-#{System.otp_release()}-#{System.version()}.plt"
  end
end
