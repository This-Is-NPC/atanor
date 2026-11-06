defmodule AtanorTestkit.MixProject do
  use Mix.Project

  def project do
    [
      app: :atanor_testkit,
      # x-release-please-start-version
      version: "0.1.0",
      # x-release-please-end
      elixir: "~> 1.17",
      start_permanent: false,
      description: "Test helpers for applications that run on Atanor.",
      package: [licenses: ["MIT"], links: %{}],
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  @alambique_git "https://github.com/This-Is-NPC/alambique.git"
  @alambique_tag "../alambique.ref" |> Path.expand(__DIR__) |> File.read!() |> String.trim()

  defp deps do
    [
      {:atanor, path: ".."},
      {:alambique, git: @alambique_git, tag: @alambique_tag, override: true},
      {:alambique_testkit, git: @alambique_git, tag: @alambique_tag, subdir: "testkit"}
    ]
  end
end
