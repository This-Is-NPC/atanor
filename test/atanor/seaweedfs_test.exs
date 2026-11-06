defmodule Atanor.SeaweedFSTest do
  @moduledoc "Cell round trip against the container from `mise run seaweedfs:up`."
  use ExUnit.Case, async: false

  import Atanor.Test.Await

  alias Atanor.{CLI, Cell, Deployments, Registry, Store}
  alias Atanor.Dev.SeaweedFS
  alias Atanor.Test.{Manifests, ProbeWorker}
  alias AtanorTestkit.Node

  @moduletag :seaweedfs

  test "a cell survives hibernation in SeaweedFS" do
    store = {Alambique.Store.S3, Atanor.Dev.SeaweedFS.config()}

    node =
      Node.start(
        store: store,
        workers: [Atanor.Test.Manifests.probe("w", cells: %{"notes" => Atanor.Test.Manifests.notes_migrations()})]
      )

    on_exit(fn -> Node.stop(node) end)

    cell = {"notes", "s3"}
    {:ok, _} = Cell.execute(node.name, cell, "INSERT INTO notes (body) VALUES ('durable')")
    :ok = Cell.hibernate(node.name, cell)
    File.rm_rf!(node.data_dir)
    File.mkdir_p!(node.data_dir)

    assert {:ok, %{rows: [["durable"]]}} = Cell.query(node.name, cell, "SELECT body FROM notes")
    assert {:ok, _etag} = Atanor.Store.put(node.name, "probe", "x")
  end

  describe "deployments" do
    @describetag :tmp_dir

    defp write_manifest(dir, n) do
      path = Path.join(dir, "atanor.json")
      manifest = Manifests.probe("w", routes: [{"127.0.0.1", "/"}], limits: %{"timeout_ms" => n})
      File.write!(path, Jason.encode!(manifest))
      path
    end

    defp id_of(output), do: Regex.run(~r/^package ([0-9a-f]{64}) /m, output) |> List.last()
    defp serving(node), do: with({:ok, d} <- Registry.deployment(node.name, "w"), do: d.id, else: (:error -> nil))

    test "concurrent activators keep a consistent head under S3 conditional writes" do
      store = Store.open({Alambique.Store.S3, SeaweedFS.config()}, "atanor")

      pub = fn n ->
        with(
          {:ok, id} <- Deployments.publish(store, Manifests.package(Manifests.probe("w", limits: %{"timeout_ms" => n}))),
          do: id
        )
      end

      mine = Enum.map(1..4, pub)
      theirs = Enum.map(11..14, pub)

      results =
        [mine, theirs]
        |> Task.async_stream(fn ids -> for id <- ids, do: Deployments.activate(store, "w", id) end, timeout: 60_000)
        |> Enum.flat_map(fn {:ok, r} -> r end)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert {:ok, %{revision: 8, previous: previous}} = Deployments.head(store, "w")
      assert length(previous) == 7
    end

    test "deployments through the CLI with a scoped token switch, roll back and list a node's worker", %{tmp_dir: dir} do
      operator = "operator-secret"

      node =
        Node.start(
          store: {Alambique.Store.S3, SeaweedFS.config()},
          prefix: "atanor",
          poll_interval_ms: 50,
          admin: [token: operator, port: 0]
        )

      on_exit(fn -> Node.stop(node) end)
      url = "http://127.0.0.1:#{Atanor.admin_port(node.name)}"

      # The deployer holds a token scoped to one worker, never bucket credentials.
      ctx = fn token ->
        %{
          env: %{"HOME" => dir, "XDG_CONFIG_HOME" => dir, "ATANOR_URL" => url, "ATANOR_TOKEN" => token},
          cwd: dir,
          stdin: fn _ -> :eof end
        }
      end

      scopes = for s <- ~w(deploy activate rollback read), x <- ["--scope", "worker:w:" <> s], do: x
      {0, out, ""} = CLI.run(["token", "create", "ci"] ++ scopes, ctx.(operator))
      [token] = Regex.run(~r/^secret: (\S+)$/m, out, capture: :all_but_first)

      cli = fn argv ->
        assert {0, out, ""} = CLI.run(argv, ctx.(token))
        out
      end

      ebin = ["--ebin", ProbeWorker |> :code.which() |> to_string() |> Path.dirname()]

      write_manifest(dir, 1)
      out = cli.(["deploy", "--activate"] ++ ebin)
      v1 = id_of(out)
      assert out =~ "w: active #{v1}, revision 1, previous none"
      assert until(fn -> serving(node) == v1 end)

      write_manifest(dir, 2)
      v2 = cli.(["deploy"] ++ ebin) |> id_of()
      assert v2 != v1
      assert serving(node) == v1

      cli.(["activate", "w", v2])
      assert until(fn -> serving(node) == v2 end)

      assert cli.(["rollback", "w"]) =~ "w: active #{v1}, revision 3, previous none"
      assert until(fn -> serving(node) == v1 end)

      assert cli.(["status"]) =~ "w: active #{v1}, revision 3"
    end
  end
end
