defmodule DpExchangeSchwab.MixProject do
  use Mix.Project

  # SEED, not a release. CI increments the last segment of whatever it finds here, so
  # `0.1.0` first publishes as `0.1.1`. Hand-editing this to `0.2.0` is how a breaking
  # change is signalled. The bump script matches the attribute assignment below by its
  # exact literal form — do not reformat it, and do not repeat that form anywhere else
  # in this file, comments included, or the script will rewrite the wrong line.
  @version "0.1.5"
  @source_url "https://github.com/DistortionPoint/dp-exchange-schwab"

  def project do
    [
      app: :dp_exchange_schwab,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      preferred_cli_env: preferred_cli_env(),
      test_coverage: test_coverage(),

      # Hex.pm
      name: "DpExchangeSchwab",
      description:
        "EXPERIMENTAL — Schwab venue package for the DpExchange family. Market data, " <>
          "trading and streaming behind the shared DpExchange.Core.Venue facade.",
      package: package(),
      source_url: @source_url,
      docs: docs(),
      usage_rules: usage_rules()
    ]
  end

  # No `mod:` — a library does not start itself. A consumer supervises this venue
  # through `child_spec/1` and decides restart strategy, shutdown order and naming. A
  # consumer that has not asked for Schwab must not find a socket open.
  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      # The contract. Three-part pin: while Core is 0.x a minor bump may break us, and
      # that is the signal it is meant to send.
      # Needs `Timeframe.nameable/0` — this venue serves 1w and 1M, which Core can name
      # but deliberately cannot bucket — and `max_leverage: :per_account`, because Reg-T
      # has no single ceiling. Both landed in Core for this package.
      {:dp_exchange_core, "~> 0.1.22"},

      # Core ships no venue-specific dependency: a venue that speaks WebSocket ships what
      # it needs to speak it.
      # No `websockex` — **yet**. This package does not speak the venue's socket; that is
      # not the same as the venue not having one, and this comment used to say it was.
      #
      # It read "this venue has no streaming API at all". **That is false.** Schwab
      # publishes a WebSocket **Streamer** with 15 services, including three book services
      # and `ACCT_ACTIVITY`. It is described in the prose documentation this repository
      # already held (`docs/reference/schwab/documentation/market-data-production.txt`),
      # and it is absent from both OpenAPI documents — which is exactly how the error was
      # made: the specifications were read, the prose beside them was not.
      #
      # The feed is a REST poll served by `Core.PollingFeed` until the Streamer is
      # implemented. Add `websockex` when it is, and not before.
      {:jason, "~> 1.4"},
      {:decimal, "~> 2.0"},

      # Dev/Test
      {:usage_rules, "~> 1.2", only: :dev},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},

      # Exercises the REST pipeline through Req's test seam, so tier-1 tests reach no
      # network. Never ships.
      {:plug, "~> 1.16", only: :test}
    ]
  end

  defp test_coverage, do: [threshold: 90, ignore_modules: []]

  defp aliases do
    [quality: ["format --check-formatted", "credo --strict", "dialyzer", "sobelow --config"]]
  end

  defp dialyzer do
    [plt_add_apps: [:mix, :ex_unit], plt_file: {:no_warn, "priv/plts/dialyzer.plt"}]
  end

  defp preferred_cli_env, do: [quality: :test]

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      maintainers: ["bcatherall"],

      # `files:` belongs HERE, not at the project level. Hex reads `package[:files]`; a
      # `files:` in `project/0` is silently ignored and Hex ships its own defaults —
      # which puts `priv/plts/dialyzer.plt` in the tarball and leaves out anything you
      # meant to add. Nothing warns. Inspect `mix hex.build` before every publish.
      #
      # `priv/` is absent because the only thing in it is the dialyzer PLT.
      # `config/` is absent: it governs this package's own dev and test, never a
      # consumer's.
      files: [
        "lib",
        "mix.exs",
        ".formatter.exs",
        "README.md",
        "LICENSE",
        "CHANGELOG.md",
        "AGENTS.md",
        "usage-rules.md",
        "docs/reference"
      ]
    ]
  end

  defp docs do
    [
      main: "DpExchange.Schwab",
      extras: ["README.md", "CHANGELOG.md", "usage-rules.md"],
      source_ref: "v#{@version}"
    ]
  end

  defp usage_rules, do: [file: "AGENTS.md", usage_rules: [:usage_rules]]
end
