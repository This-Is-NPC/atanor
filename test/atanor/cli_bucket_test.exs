defmodule Atanor.CLIBucketTest do
  @moduledoc "`atanor deploy --bucket`: publishes through a store handle, with no node (docs/cli.md)."
  use ExUnit.Case, async: true

  alias Atanor.CLI
  alias Atanor.Deployments
  alias Atanor.Deployments.Versions
  alias Atanor.Test.Manifests

  @moduletag :tmp_dir
  @bucket "s3://bucket/some/prefix"

  setup %{tmp_dir: dir} do
    project = Path.join(dir, "project")
    File.mkdir_p!(project)
    File.cp!("test/fixtures/wasm/hello.wasm", Path.join(project, "hello.wasm"))
    write_manifest(project, "atanor.json", Manifests.wasm("hello", "hello", routes: [{"127.0.0.1", "/hello"}]))

    store = Manifests.memory_store("some/prefix")
    {:ok, project: project, store: store, cwd: dir}
  end

  defp write_manifest(project, file, manifest), do: File.write!(Path.join(project, file), Jason.encode!(manifest))

  # The store handle replaces the bucket; the rest of the command is the real one.
  defp cli(argv, ctx, store, env \\ %{}) do
    me = self()

    open = fn url, _env ->
      send(me, {:open, url})
      {:ok, store, []}
    end

    CLI.run(argv, %{env: env, cwd: ctx.cwd, stdin: fn _ -> :eof end, open_store: open})
  end

  defp package_id(out), do: Regex.run(~r/^package ([0-9a-f]{64}) /m, out) |> List.last()

  test "publishes a WASM worker and its manifest to the store and activates it",
       %{project: project, store: store} = ctx do
    assert {0, out, ""} = cli(["deploy", project, "--bucket", @bucket, "--activate"], ctx, store)
    assert_received {:open, @bucket}

    id = package_id(out)
    assert out =~ "package #{id} (hello, wasm, "
    assert out =~ "hello: active #{id}, revision 1, previous none"
    assert out =~ "the nodes apply it at their next poll"

    assert {:ok, %{active: ^id, revision: 1}} = Deployments.head(store, "hello")
    assert {:ok, %{manifest: %{name: "hello", kind: :wasm}, id: ^id}} = Deployments.fetch_package(store, id)

    # `atanor versions` reads the index: a package published this way is listed.
    assert {:ok, [%{"package_id" => ^id, "uploaded_by" => %{"type" => "bucket"}}], nil} =
             Versions.list(store, "hello", nil, 10)
  end

  test "without --activate it only stores the package", %{project: project, store: store} = ctx do
    assert {0, out, ""} = cli(["deploy", project, "--bucket", @bucket], ctx, store)
    id = package_id(out)
    assert out =~ "this run did not activate it: add --activate"

    assert {:error, :not_found} = Deployments.head(store, "hello")
    assert {:ok, %{id: ^id}} = Deployments.fetch_package(store, id)

    assert {0, out, ""} = cli(["deploy", project, "--bucket", @bucket, "--activate"], ctx, store)
    assert package_id(out) == id
    assert {:ok, %{active: ^id}} = Deployments.head(store, "hello")
  end

  test "reads the project from the argument or the working directory, and the manifest named",
       %{
         project: project,
         store: store
       } = ctx do
    manifest = Manifests.wasm("second", "hello", routes: [{"127.0.0.1", "/second"}])
    write_manifest(project, "other.json", manifest)

    assert {0, out, ""} = cli(["deploy", project, "--manifest", "other.json", "--bucket", @bucket], ctx, store)
    assert out =~ "(second, wasm"

    assert {0, out, ""} = CLI.run(["deploy", "--bucket", @bucket], %{ctx_of(project, store) | cwd: project})
    assert out =~ "(hello, wasm"
  end

  defp ctx_of(project, store),
    do: %{env: %{}, cwd: project, stdin: fn _ -> :eof end, open_store: fn _, _ -> {:ok, store, []} end}

  test "refuses a native worker before it opens the store", %{project: project, store: store} = ctx do
    write_manifest(project, "atanor.json", Manifests.probe("native", routes: [{"127.0.0.1", "/"}]))

    assert {1, "", err} = cli(["deploy", project, "--bucket", @bucket, "--activate"], ctx, store)
    assert err =~ "--bucket deploys WASM workers only: native is native"
    assert err =~ "--url or a profile"
    refute_received {:open, _}
    assert {:ok, [], nil} = Atanor.Store.list(store, "packages/")
  end

  test "an activation the rules refuse leaves the package stored and the head alone",
       %{project: project, store: store} =
         ctx do
    # `rooms` belongs to the first worker that claims it.
    cells = %{"rooms" => Manifests.notes_migrations()}
    owner = Manifests.wasm("owner", "hello", cells: cells, routes: [{"127.0.0.1", "/owner"}])
    rival = Manifests.wasm("hello", "hello", cells: cells, routes: [{"127.0.0.1", "/hello"}])
    write_manifest(project, "atanor.json", owner)
    assert {0, _, ""} = cli(["deploy", project, "--bucket", @bucket, "--activate"], ctx, store)

    write_manifest(project, "atanor.json", rival)
    assert {1, "", err} = cli(["deploy", project, "--bucket", @bucket, "--activate"], ctx, store)
    assert err =~ "is stored in #{@bucket} but cannot be activated"
    assert err =~ "namespace_owned"
    assert {:error, :not_found} = Deployments.head(store, "hello")
  end

  test "a store that fails to write is reported", %{project: project} = ctx do
    {:ok, pid} = AlambiqueTestkit.MemoryStore.start_link()
    config = AlambiqueTestkit.MemoryStore.config(pid)
    store = Atanor.Store.open({AlambiqueTestkit.MemoryStore, config}, "p")
    GenServer.stop(pid)

    assert {1, "", err} = cli(["deploy", project, "--bucket", @bucket], ctx, store)
    assert err =~ "cannot write the package to #{@bucket}"
  end

  test "a bucket that is not an S3 URL, or has no credentials, is refused before anything is written", %{
    project: project,
    cwd: cwd
  } do
    ctx = %{env: %{"AWS_EC2_METADATA_DISABLED" => "true"}, cwd: cwd, stdin: fn _ -> :eof end}

    assert {1, "", err} = CLI.run(["deploy", project, "--bucket", "http://bucket"], ctx)
    assert err =~ "atanor: --bucket: must be s3://bucket or s3://bucket/prefix"

    assert {1, "", err} = CLI.run(["deploy", project, "--bucket", @bucket], ctx)
    assert err =~ "no AWS credentials"
  end

  test "credentials that cannot be fetched stop the command, and the command is left clean", %{
    project: project,
    cwd: cwd
  } do
    env = %{"AWS_EC2_METADATA_SERVICE_ENDPOINT" => "http://127.0.0.1:1", "AWS_EC2_METADATA_DISABLED" => "false"}
    ctx = %{env: env, cwd: cwd, stdin: fn _ -> :eof end}

    assert {1, "", err} = CLI.run(["deploy", project, "--bucket", @bucket], ctx)
    assert err =~ "cannot get the AWS credentials (EC2 metadata)"
    refute_received {:EXIT, _, _}
    assert Process.info(self(), :trap_exit) == {:trap_exit, false}
  end

  describe "the two modes" do
    test "are exclusive, with an error for each flag of the admin API", %{project: project, store: store} = ctx do
      for {flag, value} <- [{"--url", "http://127.0.0.1:1"}, {"--profile", "ops"}, {"--timeout", "5"}] do
        assert {2, "", err} = cli(["deploy", project, "--bucket", @bucket, flag, value], ctx, store)
        assert err =~ "--bucket writes the store directly and #{flag} is for the admin API of a node"
      end

      # The profile may also come before the command.
      assert {2, "", err} = cli(["--profile", "ops", "deploy", project, "--bucket", @bucket], ctx, store)
      assert err =~ "--profile"

      refute_received {:open, _}
      assert {:error, :not_found} = Deployments.head(store, "hello")
    end

    test "leave the environment of the admin API alone: --bucket does not use it",
         %{project: project, store: store} =
           ctx do
      env = %{"ATANOR_URL" => "http://127.0.0.1:1", "ATANOR_TOKEN" => "unused", "ATANOR_PROFILE" => "ops"}
      assert {0, _, ""} = cli(["deploy", project, "--bucket", @bucket], ctx, store, env)
    end

    test "without --bucket the admin API is used, with --url and the token of the environment",
         %{
           project: project,
           store: store
         } = ctx do
      env = %{"ATANOR_TOKEN" => "unused", "HOME" => ctx.cwd, "XDG_CONFIG_HOME" => ctx.cwd}
      assert {1, "", err} = cli(["deploy", project, "--url", "http://127.0.0.1:1"], ctx, store, env)
      assert err =~ "cannot reach http://127.0.0.1:1"
      refute_received {:open, _}
    end

    test "take at most one directory and no unknown option", %{project: project, store: store} = ctx do
      assert {2, "", err} = cli(["deploy", project, "other", "--bucket", @bucket], ctx, store)
      assert err =~ "usage: atanor deploy [DIR]"
      assert {2, "", err} = cli(["deploy", "--buckets", @bucket], ctx, store)
      assert err =~ "invalid option --buckets for deploy"
    end
  end
end
