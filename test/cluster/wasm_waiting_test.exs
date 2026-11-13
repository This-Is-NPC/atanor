defmodule Atanor.Cluster.WasmWaitingTest do
  @moduledoc """
  Guests that wait for the store do not use the slots meant for CPU (design §14.2). A node sized as 1 CPU
  (`threads: 1`) and 512 MiB serves 12 writers that each wait 600 ms, the time of about 12 store round
  trips of 25 ms, none refused with `worker_queue`.
  """
  use ExUnit.Case, async: false

  import Atanor.Test.ClusterCase

  alias Atanor.Test.Manifests
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag timeout: 120_000

  @writers 12
  @wait_ms 600
  @memory [limit_bytes: 512 * 1_048_576]

  test "12 writers that wait 600 ms each are not refused on 1 CPU" do
    cluster =
      start_cluster(names: [:n1], wasm: [threads: 1, queue_wait_ms: 5_000], atanor: [memory: @memory])

    manifest = Manifests.wasm("sleeper", "sleep", routes: [{"127.0.0.1", "/sleeper"}])
    assert {:ok, _} = Cluster.deploy(cluster, manifest, Path.expand("test/fixtures/wasm"))

    # One writer every 10 ms: the 12th starts while the first are still waiting.
    tasks =
      for _ <- 1..@writers do
        Process.sleep(10)
        Task.async(fn -> request(cluster, :n1, :get, "/sleeper/#{@wait_ms}") end)
      end

    responses = Task.await_many(tasks, 60_000)
    statuses = for {:ok, response} <- responses, do: {response.status, response.body}
    refused = Enum.filter(statuses, fn {status, _} -> status == 503 end)

    assert refused == [], inspect(refused)
    assert Enum.all?(statuses, &match?({200, _}, &1)), inspect(statuses)
  end
end
