defmodule Atanor.Cluster.DiscoveryPropertyTest do
  @moduledoc """
  **Single owner while nodes come and go through discovery** (design §8.16).

  The nodes are connected by `Atanor.Discovery` only. Random requests through the live nodes are
  interleaved with nodes that join (and are found while requests run), nodes that stop gracefully and
  nodes that are killed. Afterwards:

    * every acknowledged request ran its handler on the node that committed its batch, unless a takeover
      explains it, so two nodes never both owned a cell;
    * no two nodes acknowledged batches of one cell in the same epoch, and epochs never overlap;
    * a counter cell has every acknowledged increment once and none twice.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Atanor.Test.ClusterCase

  alias Atanor.Test.{C1, Manifests}
  alias AtanorTestkit.Cluster

  @moduletag :cluster
  @moduletag timeout: 900_000

  @pool [:n1, :n2, :n3, :n4]
  @cells ["c0", "c1", "c2"]
  @ttl_ms 2_000
  @skew_ms 400
  @available_within_ms @ttl_ms + @skew_ms + 15_000

  defp op do
    frequency([
      {16, tuple({constant(:request), member_of(@pool), member_of(@cells)})},
      {3, constant(:join)},
      {2, tuple({constant(:leave), member_of(@pool)})},
      {2, tuple({constant(:kill), member_of(@pool)})},
      {3, tuple({constant(:pass), integer(50..600)})}
    ])
  end

  property "a cell has one owner while nodes join and leave through discovery" do
    check all(ops <- resize(list_of(op(), min_length: 20, max_length: 40), 40), max_runs: 8, max_shrinking_steps: 0) do
      cluster =
        start_cluster(
          names: [:n1, :n2],
          ttl_ms: @ttl_ms,
          skew_margin_ms: @skew_ms,
          discover: [ttl_ms: @ttl_ms, renew_ms: 200],
          workers: [Manifests.counter("counter")]
        )

      try do
        run = Enum.reduce(ops, %{live: [:n1, :n2], seq: 0, requests: []}, &step(cluster, &1, &2))
        verify(cluster, run)
      after
        Process.unlink(cluster)
        Cluster.stop(cluster)
      end
    end
  end

  # A new node, found by the others and finding them, while requests go on.
  defp step(cluster, :join, run) do
    case @pool -- Cluster.names(cluster) do
      [] ->
        run

      [name | _] ->
        Cluster.add(cluster, name)
        %{run | live: run.live ++ [name]}
    end
  end

  defp step(cluster, {:leave, node}, run) do
    if node in run.live and length(run.live) > 1 do
      supervisor = Module.concat(Cluster.instance(cluster), Supervisor)
      {:ok, :ok} = Cluster.call(cluster, node, Supervisor, :stop, [supervisor])
      %{run | live: run.live -- [node]}
    else
      run
    end
  end

  defp step(cluster, {:kill, node}, run) do
    if node in run.live and length(run.live) > 1 do
      Cluster.kill(cluster, node)
      %{run | live: run.live -- [node]}
    else
      run
    end
  end

  defp step(cluster, {:request, node, cell}, run) do
    if node in run.live do
      n = run.seq + 1
      %{run | seq: n, requests: [send_request(cluster, node, cell, n) | run.requests]}
    else
      run
    end
  end

  defp step(_cluster, {:pass, ms}, run), do: tap(run, fn _ -> Process.sleep(ms) end)

  defp send_request(cluster, node, cell, n) do
    outcome =
      case request(cluster, node, :post, "/c/#{cell}", body: Integer.to_string(n)) do
        {:ok, %{status: 200, body: body}} -> {:acked, Jason.decode!(body)}
        _ -> :unknown
      end

    %{n: n, cell: cell, outcome: outcome}
  end

  defp verify(cluster, run) do
    requests = Enum.reverse(run.requests)

    for cell <- @cells do
      stored = C1.read_when_available(cluster, run.live, cell, @available_within_ms)
      mine = Enum.filter(requests, &(&1.cell == cell))
      acked = for %{outcome: {:acked, _}, n: n} <- mine, do: n

      assert stored == Enum.uniq(stored), "cell #{cell} applied an increment twice: #{inspect(stored)}"
      assert stored -- Enum.map(mine, & &1.n) == [], "cell #{cell} has increments nobody sent"
      assert acked -- stored == [], "cell #{cell} lost acknowledged increments #{inspect(acked -- stored)}"

      takeovers =
        for %{event: [:alambique, :lease, :take_over], meta: %{result: :ok, cell: "log." <> ^cell}} <-
              Cluster.events(cluster),
            do: :taken

      # A handler on another node than the commit is a takeover's doing (design §8.13), never two owners.
      C1.check_placement(cluster, cell, mine, fn n, body ->
        assert takeovers != [], "increment #{n} of #{cell} ran on #{body["node"]} and committed on #{body["tx_node"]}"
      end)
    end

    C1.check_epochs(Cluster.events(cluster))

    IO.puts(
      "discovery C1: #{length(requests)} requests, #{Enum.count(requests, &(&1.outcome != :unknown))} acknowledged"
    )
  end
end
