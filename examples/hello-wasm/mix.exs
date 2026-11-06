defmodule HelloWasm.MixProject do
  use Mix.Project

  def project do
    [app: :hello_wasm, version: "0.1.0", elixir: "~> 1.17", deps: deps()]
  end

  # alambique_testkit gives `mix atanor.dev` its in-memory store. It and Atanor must use the same
  # Alambique, the release tag in alambique.ref (docs/how-to-update-alambique.md).
  @alambique_git "https://github.com/This-Is-NPC/alambique.git"
  @alambique_tag "../../alambique.ref" |> Path.expand(__DIR__) |> File.read!() |> String.trim()

  defp deps do
    [
      {:atanor, path: "../.."},
      {:alambique, git: @alambique_git, tag: @alambique_tag, override: true},
      {:alambique_testkit, git: @alambique_git, tag: @alambique_tag, subdir: "testkit", only: :dev}
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
