defmodule Atanor.Test.C1 do
  @moduledoc """
  The checks of the C1 properties on the events and replies of the counter worker (`Atanor.Test.CounterWorker`)
  of a cluster: where a request ran and committed, that acknowledged requests of one cell do not overlap in time
  on different nodes, and that no two nodes acknowledged batches of one cell in the same epoch.
  """
  import ExUnit.Assertions

  import Atanor.Test.ClusterCase, only: [request: 5]

  alias Atanor.Test.Await
  alias AtanorTestkit.Cluster

  # The handler ran on the node whose cell process committed the transaction, and acknowledged requests
  # for one cell do not overlap in time across nodes, except for the window of a takeover (design §8.13):
  # a handler that started on the owner before the takeover ends its write through the new owner, and a
  # node that was not told it lost the cell starts no handler more than `routing.owner_check_ms` after
  # the takeover. The data properties are not relaxed for any cell.
  def check_placement(cluster, cell, requests, explain) do
    commits =
      for %{event: [:alambique, :cell, :commit], meta: %{result: :ok, cell: "log." <> ^cell} = meta} = e <-
            Cluster.events(cluster),
          into: %{},
          do: {meta.txid, Cluster.node(cluster, e.node)}

    acked = for %{outcome: {:acked, body}, n: n} <- requests, do: {n, body}

    for {n, body} <- acked do
      committed_on = commits[body["txid"]]

      assert committed_on == nil or Atom.to_string(committed_on) == body["tx_node"],
             "increment #{n} of #{cell}: batch committed on #{committed_on}"
    end

    moved = for {n, body} <- acked, body["node"] != body["tx_node"], do: {n, body}
    for {n, body} <- moved, do: explain.(n, body)

    acked = for {n, body} <- acked, do: {n, body["node"], body["from"], body["to"]}
    moved = MapSet.new(for {n, _} <- moved, do: n)

    for {n1, node1, from1, to1} <- acked, {n2, node2, from2, to2} <- acked, n1 < n2, node1 != node2 do
      unless n1 in moved or n2 in moved,
        do: assert(to1 < from2 or to2 < from1, "cell #{cell}: increments #{n1} (#{node1}) and #{n2} (#{node2}) overlap")
    end

    :ok
  end

  def check_epochs(events) do
    commits =
      for %{event: [:alambique, :cell, :commit], meta: %{result: :ok} = meta} = e <- events,
          do: %{cell: meta.cell, txid: meta.txid, epoch: meta.epoch, node: e.node, at: e.at}

    for {cell, batches} <- Enum.group_by(commits, & &1.cell) do
      assert batches |> Enum.map(& &1.txid) |> Enum.uniq() |> length() == length(batches),
             "cell #{cell}: one TXID acknowledged twice"

      for {epoch, nodes} <- Enum.group_by(batches, & &1.epoch, & &1.node) do
        assert nodes |> Enum.uniq() |> length() == 1,
               "cell #{cell}: epoch #{epoch} acknowledged by #{inspect(Enum.uniq(nodes))}"
      end

      epochs = batches |> Enum.sort_by(& &1.at) |> Enum.map(& &1.epoch)
      assert epochs == Enum.sort(epochs), "cell #{cell}: epochs overlap in time"
    end
  end

  @doc "The numbers stored in the counter cell, read through the first of `names` that answers, within `within_ms`."
  def read_when_available(cluster, names, cell, within_ms) do
    Await.until(
      fn ->
        Enum.find_value(names, fn node ->
          with {:ok, %{status: 200, body: body}} <- request(cluster, node, :get, "/c/#{cell}", []) do
            Jason.decode!(body)["rows"]
          else
            _ -> nil
          end
        end)
      end,
      within_ms
    )
  end
end
