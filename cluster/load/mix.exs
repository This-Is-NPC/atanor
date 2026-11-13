defmodule AtanorLoad.MixProject do
  use Mix.Project

  def project do
    [
      app: :atanor_load,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: [{:atanor, path: "../.."}],
      # The image of the load tests: a derived image (mix atanor.release), which `scripts/load-env` builds.
      releases: [atanor: [include_executables_for: [:unix]]]
    ]
  end

  def application, do: [extra_applications: [:logger], mod: {AtanorLoad.Application, []}]
end
