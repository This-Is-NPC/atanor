# Requests forwarded to the owner of a cell, against requests that find the
# owner on the ingress node (design §12.4).
#
#   mise run bench:cluster            # 5 seconds per case
#   mise run bench:cluster -- 10      # another duration
#
# Three peer nodes on this machine over one in-memory store, a counter worker,
# 96 write cells and 96 read cells woken first. All load goes to the HTTP port of n1: "local" requests
# are for cells n1 owns, "forwarded" ones for cells the other nodes own. The
# peers and the load generator share the machine's cores.

Code.require_file("load.exs", __DIR__)

defmodule Bench do
  alias Atanor.Bench.Load
  alias Atanor.Test.Manifests
  alias AtanorTestkit.Cluster

  @clients 32
  @cells 96

  def run(seconds) do
    {:ok, cluster} = Cluster.start_link(names: [:n1, :n2, :n3], ttl_ms: 30_000, skew_margin_ms: 2_000, workers: [Manifests.counter("counter")])

    try do
      port = cluster |> Cluster.url(:n1) |> URI.parse() |> Map.fetch!(:port)
      # Write cells grow with the run; read cells keep one row, so reads are comparable.
      cells = for i <- 1..@cells, do: "w#{i}"
      read_cells = for i <- 1..@cells, do: "r#{i}"
      for cell <- cells ++ read_cells, do: {:ok, _} = Req.post(Cluster.url(cluster, :n2) <> "/c/#{cell}", body: "0", retry: false)

      n1 = Cluster.node(cluster, :n1)
      split = fn cells -> Enum.split_with(cells, &(owner(cluster, &1) == n1)) end
      {write_local, write_forwarded} = split.(cells)
      {read_local, read_forwarded} = split.(read_cells)

      IO.puts("machine: #{Load.machine()}\npeers: 3, clients: #{@clients}, #{seconds} s per case")
      IO.puts("cells owned by n1: #{length(write_local)} of #{@cells} write cells, #{length(read_local)} of #{@cells} read cells\n")

      cases = [
        {"write, owner is the ingress", write_local, "POST"},
        {"write, forwarded to the owner", write_forwarded, "POST"},
        {"read, owner is the ingress", read_local, "GET"},
        {"read, forwarded to the owner", read_forwarded, "GET"}
      ]

      for {label, set, method} <- cases do
        request = fn i -> {method, "/c/#{Enum.at(set, rem(i, length(set)))}", [], if(method == "POST", do: "#{i}", else: "")} end
        Load.run(port, @clients, {:seconds, 1}, request)
        IO.puts(Load.row("#{label} (#{length(set)} cells)", Load.run(port, @clients, {:seconds, seconds}, request)))
      end
    after
      Process.unlink(cluster)
      Cluster.stop(cluster)
    end
  end

  defp owner(cluster, cell) do
    {:ok, {:ok, node}} = Cluster.call(cluster, :n1, Alambique, :owner, [Module.concat(Cluster.instance(cluster), Cells), "log." <> cell])
    node
  end
end

[seconds | _] = System.argv() ++ ["5"]
Bench.run(String.to_integer(seconds))
