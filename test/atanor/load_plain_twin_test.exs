defmodule Atanor.LoadPlainTwinTest do
  use ExUnit.Case, async: true

  # The plain WASM worker of the load tests (examples/load-plain) must do the same work in the store as the
  # native worker (cluster/load): one INSERT or one count per request. Segment uploads (`.ltx` puts) are counted: the feed and lease writes depend on timing. The scoreboard does not (a job per write),
  # which is why the load tests keep it as http-wasm-jobs. Needs `mise run build:load-plain`.

  alias Atanor.Test.{CountingStore, Manifests}
  alias AtanorTestkit.Node

  @wasm Path.expand("examples/load-plain")
  @migrations [[1, "CREATE TABLE log (n INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT NOT NULL)"]]
  @requests 240
  @cells 6

  defmodule Twin do
    @moduledoc false
    @behaviour Atanor.Worker
    alias Atanor.{Env, Request, Response}

    @impl true
    def route_key(%Request{path: "/native/" <> cell}, _env), do: {:cell, "load", cell}
    def route_key(_request, _env), do: :none

    @impl true
    def handle_request(%Request{method: "GET", path: "/native/" <> cell}, env) do
      {:ok, %{rows: [[n]]}} = Env.query(env, {"load", cell}, "SELECT count(*) FROM log")
      %Response{status: 200, body: ~s({"rows":#{n}})}
    end

    def handle_request(%Request{method: "POST", path: "/native/" <> cell, body: body}, env) do
      {:ok, _} = Env.execute(env, {"load", cell}, "INSERT INTO log (v) VALUES (?)", [body])
      %Response{status: 201, body: ~s({"ok":true})}
    end
  end

  setup do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    {:ok, pid} = AlambiqueTestkit.MemoryStore.start_link(name: name)
    Process.unlink(pid)
    store = CountingStore.wrap({AlambiqueTestkit.MemoryStore, AlambiqueTestkit.MemoryStore.config(name)}, ".ltx")
    node = Node.start(store: store)

    on_exit(fn ->
      Node.stop(node)
      GenServer.stop(pid)
    end)

    manifest =
      Map.put(@wasm |> Path.join("atanor.json") |> File.read!() |> Jason.decode!(), "routes", [
        %{"http" => %{"host" => "127.0.0.1", "path" => "/plain"}}
      ])

    {:ok, _} = Atanor.Dev.deploy(node.name, manifest, @wasm)

    twin = Manifests.probe("twin", module: Twin, cells: %{"load" => @migrations}, routes: [{"127.0.0.1", "/native"}])
    {:ok, _} = Atanor.Dev.deploy(node.name, twin)
    {:ok, node: node, store: store}
  end

  # Sends `@requests` requests, half of them writes, over the `@cells` warmed cells; returns the puts and bytes per request.
  defp measure(node, store, route) do
    {puts, bytes} = {CountingStore.puts(store), CountingStore.put_bytes(store)}

    for n <- 1..@requests do
      url = "#{node.url}/#{route}/warm-#{rem(n, @cells)}"

      resp =
        if rem(n, 2) == 0,
          do: Req.post!(url, body: "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", retry: false),
          else: Req.get!(url, retry: false)

      assert resp.status in [200, 201]
    end

    {(CountingStore.puts(store) - puts) / @requests, (CountingStore.put_bytes(store) - bytes) / @requests}
  end

  test "the plain WASM worker uploads as much per request as the native one", %{node: node, store: store} do
    for route <- ["native", "plain"], cell <- 0..(@cells - 1) do
      assert Req.post!("#{node.url}/#{route}/warm-#{cell}", body: "w", retry: false).status == 201
    end

    {native_puts, native_bytes} = measure(node, store, "native")
    {plain_puts, plain_bytes} = measure(node, store, "plain")

    assert native_puts > 0
    # Bytes vary more with the timing of the commits than puts do: a runtime that uploads per call still doubles them.
    assert_in_delta plain_puts, native_puts, native_puts * 0.25
    assert_in_delta plain_bytes, native_bytes, native_bytes * 0.5
  end
end
