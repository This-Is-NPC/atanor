defmodule LiveCounter.MixProject do
  use Mix.Project

  def project do
    [
      app: :live_counter,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # The release must be named atanor: the image has the layout of the product image (mix atanor.release).
      releases: [atanor: [include_executables_for: [:unix]]]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {LiveCounter.Application, []}]
  end

  # In your app, depend on a release tag instead:
  #   {:atanor, git: "https://github.com/This-Is-NPC/atanor.git", tag: "v0.3.0"}
  defp deps do
    [
      {:atanor, path: "../.."},
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.2"}
    ]
  end
end
