defmodule Atanor.AlambiquePinTest do
  # Every project of the repository builds against the release in alambique.ref (docs/how-to-update-alambique.md):
  # a lock left on an older tag builds the load lab or an example against another Alambique.
  use ExUnit.Case, async: true

  @repo Path.expand("../..", __DIR__)
  @tag_line ~r/"alambique": \{:git, "[^"]+", "[0-9a-f]+", \[tag: "([^"]+)"\]\}/

  for lock <- ~w(mix.lock cluster/load/mix.lock examples/echo-tcp/mix.lock examples/hello-native/mix.lock
                 examples/hello-wasm/mix.lock examples/live-counter/mix.lock lab/app/mix.lock) do
    test "#{lock} names the tag of alambique.ref" do
      pin = @repo |> Path.join("alambique.ref") |> File.read!() |> String.trim()
      [_, tag] = Regex.run(@tag_line, File.read!(Path.join(@repo, unquote(lock))))
      assert tag == pin
    end
  end
end
