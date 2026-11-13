defmodule Atanor.Cluster.DeployBucketTest do
  @moduledoc """
  `atanor deploy --bucket` writes only to the store, and every node of the cluster serves the worker
  at its next poll (design §5.3): nothing tells the nodes.
  """
  use ExUnit.Case, async: false

  import Atanor.Test.ClusterCase

  alias Atanor.Test.{Await, Manifests}
  alias Atanor.{CLI, Store}
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag :tmp_dir
  @moduletag timeout: 180_000
  @prefix "deploys"

  setup %{tmp_dir: dir} do
    File.cp!("test/fixtures/wasm/hello.wasm", Path.join(dir, "hello.wasm"))
    manifest = Manifests.wasm("hello", "hello", routes: [{"127.0.0.1", "/hello"}])
    File.write!(Path.join(dir, "atanor.json"), Jason.encode!(manifest))

    cluster = start_cluster(prefix: @prefix, atanor: [poll_interval_ms: 500])
    {:ok, cluster: cluster, dir: dir}
  end

  # What the command opens for `--bucket`: the store the peers share. It is the only part replaced.
  defp deploy(cluster, dir, extra) do
    store = fn _url, _env -> {:ok, Store.open(Cluster.store(cluster), @prefix), []} end

    CLI.run(["deploy", dir, "--bucket", "s3://cluster/" <> @prefix] ++ extra, %{
      env: %{},
      cwd: dir,
      stdin: fn _ -> :eof end,
      open_store: store
    })
  end

  defp serves?(cluster, name) do
    match?({:ok, %{status: 200}}, request(cluster, name, :get, "/hello/ann")) and
      match?(%{"hello" => %{error: nil}}, Cluster.status(cluster, name))
  end

  test "every node serves a worker deployed through the bucket, with no node told", %{cluster: cluster, dir: dir} do
    names = Cluster.names(cluster)
    assert length(names) == 3
    for name <- names, do: assert({:ok, %{status: 404}} = request(cluster, name, :get, "/hello/ann"))

    assert {0, out, ""} = deploy(cluster, dir, ["--activate"])
    [_, id] = Regex.run(~r/^package ([0-9a-f]{64}) /m, out)

    # The nodes pick the head up on their poll.
    Await.until(
      fn -> Enum.all?(names, &(serves?(cluster, &1) and Cluster.status(cluster, &1)["hello"].applied == id)) end,
      30_000
    )

    for name <- names do
      assert {:ok, %{status: 200, body: body}} = request(cluster, name, :get, "/hello/ann")
      assert body =~ "hello GET /hello/ann"
    end
  end

  test "a package stored without --activate changes nothing on the nodes until it is activated", %{
    cluster: cluster,
    dir: dir
  } do
    names = Cluster.names(cluster)
    assert {0, _, ""} = deploy(cluster, dir, [])

    # The nodes reload the heads now: the package is in the store, but no head names it.
    :ok = Cluster.sync(cluster, names)
    for name <- names, do: assert({:ok, %{status: 404}} = request(cluster, name, :get, "/hello/ann"))

    assert {0, _, ""} = deploy(cluster, dir, ["--activate"])
    Await.until(fn -> Enum.all?(names, &serves?(cluster, &1)) end, 30_000)
  end
end
