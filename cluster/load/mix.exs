defmodule AtanorLoad.MixProject do
  use Mix.Project

  def project do
    [
      app: :atanor_load,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # The image of the load tests: a derived image (mix atanor.release), which `scripts/load-env` builds.
      releases: [atanor: [include_executables_for: [:unix]]]
    ]
  end

  # The node of the product image has its dashboard (Atanor.Dashboard.dependencies/0).
  defp deps do
    [
      {:atanor, path: "../.."},
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_live_dashboard, "~> 0.9"},
      {:telemetry_metrics, "~> 1.2"}
    ]
  end

  def application, do: [extra_applications: [:logger], mod: {AtanorLoad.Application, []}]
end
