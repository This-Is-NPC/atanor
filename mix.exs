defmodule Atanor.MixProject do
  use Mix.Project

  # The Alambique release tag (a public git dependency) that Atanor is built and tested against
  # (docs/how-to-update-alambique.md).
  @alambique_git "https://github.com/This-Is-NPC/alambique.git"
  @alambique_tag "alambique.ref" |> Path.expand(__DIR__) |> File.read!() |> String.trim()

  def project do
    [
      app: :atanor,
      version: "0.4.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "A generic runtime for workers and stateful cells on the BEAM.",
      package: package(),
      test_coverage: [ignore_modules: coverage_ignore()],
      escript: [main_module: Atanor.CLI, name: "atanor", path: "_build/cli/atanor", app: nil]
    ]
  end

  defp package do
    [licenses: ["MIT"], links: %{}, files: ~w(lib native wit mix.exs alambique.ref README.md LICENSE CHANGELOG.md)]
  end

  def application do
    [extra_applications: [:logger], mod: {Atanor.Application, []}]
  end

  # The testkit sources are compiled into the test build instead of being a
  # path dependency, because atanor_testkit itself depends on atanor and Mix
  # rejects that cycle.
  defp elixirc_paths(:test), do: ["lib", "test/support", "testkit/lib"]
  defp elixirc_paths(_), do: ["lib"]

  # The Maestro testkit is an optional test-only path dependency: set MAESTRO_TESTKIT to a checkout of
  # its testkit directory to compile the OIDC end-to-end test.
  defp maestro_testkit do
    case System.get_env("MAESTRO_TESTKIT") do
      nil -> []
      path -> if File.dir?(path), do: [{:maestro_testkit, path: path, only: :test, runtime: false}], else: []
    end
  end

  # Coverage counts lib/ only: the modules of test/support and testkit/ are compiled into the test build
  # but are not production code. Atanor.Dev* and Mix.Tasks.Atanor.Dev are the local development tooling
  # behind `mise run dev`. ATANOR_COVERAGE_IGNORE replaces the default (comma-separated regexes
  # matched against module names).
  defp coverage_ignore do
    ~S"^Atanor\.Test\.,^AtanorTestkit\.,^Atanor\.Dev(\.|$),^Mix\.Tasks\.Atanor\.Dev$"
    |> then(&System.get_env("ATANOR_COVERAGE_IGNORE", &1))
    |> String.split(",", trim: true)
    |> Enum.map(&Regex.compile!/1)
  end

  defp deps do
    maestro_testkit() ++
      [
        {:alambique, git: @alambique_git, tag: @alambique_tag, override: true},
        {:alambique_testkit, git: @alambique_git, tag: @alambique_tag, subdir: "testkit", only: [:dev, :test]},
        {:rustler, "~> 0.38", runtime: false},
        {:bandit, "~> 1.5"},
        {:plug, "~> 1.16"},
        {:websock_adapter, "~> 0.5"},
        {:jason, "~> 1.4"},
        {:jose, "~> 1.11"},
        {:req, "~> 0.5"},
        {:mint, "~> 1.6"},
        {:telemetry, "~> 1.3"},
        # Ranch protocol listeners (design 7.3); optional like Phoenix.
        {:ranch, "~> 2.1", optional: true},
        # The dashboard (design 10.1); the runtime does not need them.
        {:phoenix, "~> 1.8", optional: true},
        {:phoenix_live_view, "~> 1.2", optional: true},
        {:phoenix_live_dashboard, "~> 0.9", optional: true},
        {:telemetry_metrics, "~> 1.2", optional: true},
        {:lazy_html, ">= 0.1.0", only: :test},
        {:stream_data, "~> 1.1", only: :test},
        {:mint_web_socket, "~> 1.0", only: :test},
        {:gen_smtp, "~> 1.2", only: :test}
      ]
  end
end
