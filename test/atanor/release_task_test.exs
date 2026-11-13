defmodule Atanor.ReleaseTaskTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Atanor.Release

  @repo Path.expand("../..", __DIR__)

  @moduletag :tmp_dir

  # What the task said, as one string.
  defp run(dir, releases, args \\ []) do
    config = [app: :demo, version: "0.1.0", releases: releases]
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    Mix.Project.in_project(:demo, dir, config, fn _ -> Release.run(args) end)
    messages([])
  end

  defp messages(acc) do
    receive do
      {:mix_shell, _, [text]} -> messages([text | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  defp read(dir, path), do: File.read!(Path.join(dir, path))

  describe "plan/2" do
    test "a dependency in deps/ makes the project the build context" do
      plan = Release.plan("/work/app", "/work/app/deps/atanor")

      assert %{git?: true, app_dir: ".", atanor_dir: "deps/atanor", context_arg: "."} = plan
      assert plan.build_command == "docker build -t my-app ."
    end

    test "a path dependency above the project makes their common directory the context" do
      plan = Release.plan("/repo/examples/live", "/repo")

      assert %{git?: false, app_dir: "examples/live", atanor_dir: ".", context_arg: "../.."} = plan
      assert plan.build_command == "docker build -f examples/live/Dockerfile -t my-app ../.."
    end

    test "a path dependency in a sibling directory" do
      plan = Release.plan("/work/app", "/work/atanor")

      assert %{app_dir: "app", atanor_dir: "atanor", context_arg: ".."} = plan
    end
  end

  describe "run/1" do
    test "writes the start script, the entry point and the Dockerfile", %{tmp_dir: dir} do
      run(dir, atanor: [include_executables_for: [:unix]])

      assert read(dir, "rel/env.sh.eex") == File.read!(Path.join(@repo, "daemon/rel/env.sh.eex"))

      assert read(dir, "rel/overlays/bin/atanor-entrypoint") ==
               File.read!(Path.join(@repo, "daemon/rel/overlays/bin/atanor-entrypoint"))

      assert File.stat!(Path.join(dir, "rel/overlays/bin/atanor-entrypoint")).mode |> Bitwise.band(0o111) != 0

      dockerfile = read(dir, "Dockerfile")
      assert dockerfile =~ "mix release atanor --overwrite"
      assert dockerfile =~ ~s(ENTRYPOINT ["/opt/atanor/bin/atanor-entrypoint"])
      assert dockerfile =~ "COPY --from=build /src/"
      refute dockerfile =~ "<%"
    end

    test "the Dockerfile uses the bases of the product image" do
      root = File.read!(Path.join(@repo, "Dockerfile"))
      files = Release.files(Release.plan("/work/app", "/work/app/deps/atanor"), @repo)
      {"Dockerfile", dockerfile, _} = List.keyfind(files, "Dockerfile", 0)

      for name <- ~w(ELIXIR_IMAGE RUNTIME_IMAGE RUST_VERSION) do
        [line] = Regex.run(~r/^ARG #{name}=\S+$/m, root)
        assert dockerfile =~ line, "#{line} is not in the generated Dockerfile"
      end
    end

    test "an unchanged file is left alone and a changed one is kept unless forced", %{tmp_dir: dir} do
      releases = [atanor: []]
      run(dir, releases)
      before = read(dir, "Dockerfile")

      assert run(dir, releases) =~ "unchanged  Dockerfile"

      File.write!(Path.join(dir, "Dockerfile"), "# mine\n")
      assert run(dir, releases) =~ "kept       Dockerfile"
      assert read(dir, "Dockerfile") == "# mine\n"

      assert run(dir, releases, ["--force"]) =~ "wrote      Dockerfile"
      assert read(dir, "Dockerfile") == before
    end

    test "a context above the project sends only the sources that are needed", %{tmp_dir: dir} do
      run(dir, atanor: [])
      ignore = read(dir, "Dockerfile.dockerignore")

      assert String.starts_with?(ignore, "*\n!")
      assert ignore =~ "!lib\n"
      assert ignore =~ "**/_build"
    end

    test "a project without the release named atanor is refused with the line to add", %{tmp_dir: dir} do
      assert_raise Mix.Error, ~r/releases: \[atanor: \[include_executables_for: \[:unix\]\]\]/, fn ->
        run(dir, other: [])
      end

      refute File.exists?(Path.join(dir, "Dockerfile"))
    end

    test "an unknown option is a usage error", %{tmp_dir: dir} do
      assert_raise Mix.Error, ~r/usage/, fn -> run(dir, [atanor: []], ["--nope"]) end
    end
  end
end
