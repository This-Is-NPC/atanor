defmodule AtanorDaemon.MixProject do
  use Mix.Project

  def project do
    [
      app: :atanor_daemon,
      # x-release-please-start-version
      version: "0.3.0",
      # x-release-please-end
      elixir: "~> 1.17",
      start_permanent: true,
      deps: deps(),
      # One lock for the library and the daemon: the release is built from the versions Atanor is tested with.
      lockfile: "../mix.lock",
      releases: [atanor: [include_executables_for: [:unix]]]
    ]
  end

  def application do
    [extra_applications: [:logger, :runtime_tools], mod: {AtanorDaemon.Application, []}]
  end

  defp deps do
    [
      {:atanor, path: ".."},
      # The dashboard (Atanor.Dashboard.dependencies/0).
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_live_dashboard, "~> 0.9"},
      {:telemetry_metrics, "~> 1.2"}
    ]
  end
end
