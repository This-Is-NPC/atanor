defmodule Atanor.Cluster.LeaveWaitTest do
  @moduledoc """
  A call waits for an owner that is leaving for `routing.leave_wait_ms` in all
  (design §8.11), however many times it fails meanwhile.
  """
  use ExUnit.Case, async: false

  import Atanor.Test.ClusterCase

  alias Atanor.Test.{Await, Manifests}
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag timeout: 120_000

  @wait_ms 1_000

  test "a write to a cell whose owner announced that it leaves and never hands off is answered 503 in about that time" do
    cluster =
      start_cluster(
        names: [:n1, :n2, :n3],
        atanor: [routing: [leave_wait_ms: @wait_ms]],
        workers: [Manifests.counter("counter")]
      )

    {cell, :n3} = owned_cell(cluster, "lw", [:n3])
    instance = Cluster.instance(cluster)
    leaving = Cluster.node(cluster, :n3)

    # The notice a stopping node sends, then no heartbeat: it stays left, serves its cells and never hands them off.
    {:ok, _} = Cluster.call(cluster, :n1, Kernel, :send, [Module.concat(instance, Detector), {:leaving, leaving}])
    {:ok, :ok} = Cluster.call(cluster, :n3, :sys, :suspend, [Module.concat(instance, Detector)])
    Await.until(fn -> match?({:ok, true}, Cluster.call(cluster, :n1, Atanor.Detector, :left?, [instance, leaving])) end)

    t0 = System.monotonic_time(:millisecond)
    assert {503, body} = write(cluster, :n1, cell, 1)
    waited = System.monotonic_time(:millisecond) - t0

    assert %{"error" => "unavailable"} = Jason.decode!(body)
    assert waited >= @wait_ms, "answered after #{waited} ms, before the wait ended"
    assert waited < @wait_ms + 2_000, "answered after #{waited} ms"
  end

  test "a GET for a new cell whose preferred node has just left the members is not answered owner_down" do
    cluster = start_cluster(names: [:n1, :n2, :n3], workers: [Manifests.counter("counter")])

    {:ok, config} =
      Cluster.call(cluster, :n3, Alambique.Config, :fetch!, [Module.concat(Cluster.instance(cluster), Cells)])

    # n3 refuses to wake cells while every view, its own included, still has it among the members: the
    # moment between the start of its drain and the views catching up with the leave.
    {:ok, :ok} = Cluster.call(cluster, :n3, Alambique.Membership, :put_state, [config, :left])
    gets = for i <- 1..24, do: Task.async(fn -> get_when_served(cluster, "/c/lv#{i}") end)

    Process.sleep(300)
    {:ok, :ok} = Cluster.call(cluster, :n3, Alambique.Membership, :leave, [config])

    statuses = for task <- gets, {:ok, resp} = Task.await(task, 30_000), do: {resp.status, resp.body}
    assert Enum.all?(statuses, &match?({200, _}, &1)), "GET answers: #{inspect(Enum.frequencies(statuses))}"
  end

  test "a cell call of a handler on another node waits for the owner that is draining" do
    cluster = start_cluster(names: [:n1, :n2, :n3], workers: [Manifests.counter("counter")])

    {:ok, config} =
      Cluster.call(cluster, :n3, Alambique.Config, :fetch!, [Module.concat(Cluster.instance(cluster), Cells)])

    # As above, but the handler of `/c/direct/` runs on n1 and reaches the cell through Alambique's router.
    {:ok, :ok} = Cluster.call(cluster, :n3, Alambique.Membership, :put_state, [config, :left])
    gets = for i <- 1..24, do: Task.async(fn -> get_when_served(cluster, "/c/direct/dr#{i}") end)

    Process.sleep(300)
    {:ok, :ok} = Cluster.call(cluster, :n3, Alambique.Membership, :leave, [config])

    statuses = for task <- gets, {:ok, resp} = Task.await(task, 30_000), do: {resp.status, resp.body}
    assert Enum.all?(statuses, &match?({200, _}, &1)), "GET answers: #{inspect(Enum.frequencies(statuses))}"
  end

  test "a peer that left is taken over, and only a node outside the cluster is held_elsewhere" do
    cluster = start_cluster(names: [:n1, :n2, :n3], workers: [Manifests.counter("counter")])
    instance = Cluster.instance(cluster)
    peer = Cluster.node(cluster, :n3)
    owner = Atom.to_string(peer)

    # A peer the detector knows is of the cluster, whether or not it is among the members.
    assert {:ok, :owner_unreachable} = Cluster.call(cluster, :n1, Atanor.Takeover, :unreachable, [instance, owner])

    assert {:ok, :held_elsewhere} =
             Cluster.call(cluster, :n1, Atanor.Takeover, :unreachable, [instance, "node-b@elsewhere"])

    # A peer that announced its leave is confirmed down, so a call for its cell never reaches `unreachable`.
    {:ok, _} = Cluster.call(cluster, :n1, Kernel, :send, [Module.concat(instance, Detector), {:leaving, peer}])
    Await.until(fn -> match?({:ok, true}, Cluster.call(cluster, :n1, Atanor.Detector, :left?, [instance, peer])) end)
    assert {:ok, {:ok, ^peer, :left}} = Cluster.call(cluster, :n1, Atanor.Detector, :down_owner, [instance, owner])
  end

  # The cells wake together when the owner hands off, and a node runs at most `max_concurrent_statements`
  # reads at once: the read over it is a 503 `overloaded` (design §7), which a client retries after
  # Retry-After. Any other answer, `owner_down` included, is final.
  defp get_when_served(cluster, path, attempts \\ 5) do
    case request(cluster, :n1, :get, path) do
      {:ok, %{status: 503, body: body} = resp} when attempts > 1 ->
        if match?(%{"error" => "overloaded"}, Jason.decode!(body)) do
          [seconds] = Req.Response.get_header(resp, "retry-after")
          Process.sleep(String.to_integer(seconds) * 1_000)
          get_when_served(cluster, path, attempts - 1)
        else
          {:ok, resp}
        end

      other ->
        other
    end
  end
end
