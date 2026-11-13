defmodule Atanor.Scripts.EntrypointTest do
  @moduledoc "The entry point of the release and its image (daemon/rel/overlays/bin/atanor-entrypoint): CLI or node."
  use ExUnit.Case, async: true

  @script Path.expand("../../daemon/rel/overlays/bin/atanor-entrypoint", __DIR__)

  # A copy next to a stand-in for bin/atanor that prints what it was given, one argument per line.
  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    File.cp!(@script, Path.join(bin, "atanor-entrypoint"))
    File.write!(Path.join(bin, "atanor"), "#!/bin/sh\nfor a in \"$@\"; do echo \"$a\"; done\n")
    for file <- ["atanor", "atanor-entrypoint"], do: File.chmod!(Path.join(bin, file), 0o755)
    {:ok, bin: Path.join(bin, "atanor-entrypoint")}
  end

  defp run(bin, args) do
    {out, 0} = System.cmd(bin, args)
    String.split(out, "\n", trim: true)
  end

  test "is executable", do: assert(File.stat!(@script).mode |> Bitwise.band(0o111) != 0)

  test "no argument starts the node, and the commands of the release go to it", %{bin: bin} do
    assert run(bin, []) == ["start"]
    assert run(bin, ["start"]) == ["start"]
    assert run(bin, ["stop"]) == ["stop"]
    assert run(bin, ["eval", "IO.puts(1)"]) == ["eval", "IO.puts(1)"]
    assert run(bin, ["remote"]) == ["remote"]
  end

  test "a command of the CLI runs the CLI in an eval, with its arguments", %{bin: bin} do
    assert run(bin, ["deploy", "/w", "--bucket", "s3://b/p", "--activate"]) ==
             ["eval", "Atanor.CLI.main(tl(System.argv()))", "--", "deploy", "/w", "--bucket", "s3://b/p", "--activate"]
  end

  test "dispatches exactly the commands of Atanor.CLI, except those the release has itself", %{bin: bin} do
    commands = Atanor.CLI.commands() |> Enum.map(&(&1.name |> String.split(" ") |> hd())) |> Enum.uniq()

    for command <- commands -- ["help", "version"] do
      assert ["eval" | _] = run(bin, [command]), "#{command} does not run the CLI"
    end

    # `help` and `version` stay the release's own; nothing else is taken from it.
    assert run(bin, ["version"]) == ["version"]
    assert run(bin, ["help"]) == ["help"]
  end
end
