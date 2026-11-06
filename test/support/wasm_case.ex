defmodule Atanor.Test.WasmCase do
  @moduledoc "Helpers for tests of WASM workers over HTTP."

  alias Atanor.Test.Manifests
  alias AtanorTestkit.Node

  @host "127.0.0.1"

  @doc "Starts a node, deploys the guests `{worker, guest, opts}` from `test/fixtures/wasm` and stops the node at exit."
  def start(workers, node_opts \\ []) do
    node = Node.start(node_opts)
    ExUnit.Callbacks.on_exit(fn -> Node.stop(node) end)
    deploy(node, workers)
    node
  end

  def deploy(node, workers) do
    Manifests.deploy_wasm(node, for({name, guest, opts} <- workers, do: manifest(name, guest, opts)))
  end

  def manifest(name, guest, opts \\ []),
    do: Manifests.wasm(name, guest, [routes: [{@host, "/#{name}"}]] ++ opts)

  @doc "Requests `/<worker><path>`; returns the Req response."
  def request(node, worker, path \\ "", opts \\ []),
    do: Req.request!([url: "#{node.url}/#{worker}#{path}", retry: false, receive_timeout: 30_000] ++ opts)

  @doc false
  def forward(event, measurements, metadata, test), do: send(test, {:telemetry, event, measurements, metadata})

  @doc "Sends telemetry events matching `events` to the calling process as `{:telemetry, event, measurements, metadata}`."
  def capture(events) do
    test = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach_many(id, events, &__MODULE__.forward/4, test)

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(id) end)
  end
end
