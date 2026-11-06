defmodule AtanorNode.MixProject do
  use Mix.Project

  def project do
    [
      app: :atanor_node,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: true,
      deps: deps(),
      releases: [atanor_node: [include_executables_for: [:unix]]]
    ]
  end

  def application do
    [extra_applications: [:logger, :runtime_tools], mod: {AtanorNode.Application, []}]
  end

  defp deps do
    [
      {:atanor, path: "../.."},
      # The dashboard (Atanor.Dashboard.dependencies/0).
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_live_dashboard, "~> 0.9"},
      {:telemetry_metrics, "~> 1.2"}
    ]
  end
end
