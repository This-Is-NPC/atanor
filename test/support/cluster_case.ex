defmodule Atanor.Test.ClusterCase do
  @moduledoc "Helpers for tests on a cluster of peer nodes (`AtanorTestkit.Cluster`)."

  alias Atanor.Test.Await
  alias AtanorTestkit.Cluster

  @doc "Starts a cluster that is stopped when the test ends."
  def start_cluster(opts \\ []) do
    {:ok, cluster} = Cluster.start_link(opts)

    # The cluster is linked to the test and may already be stopping with it.
    ExUnit.Callbacks.on_exit(fn ->
      try do
        Cluster.stop(cluster)
      catch
        :exit, _ -> :ok
      end
    end)

    cluster
  end

  @doc "A request through one peer's ingress. Never retried; transport errors are returned."
  def request(cluster, name, method, path, opts \\ []) do
    Req.request(
      [
        method: method,
        url: Cluster.url(cluster, name) <> path,
        retry: false,
        decode_body: false,
        receive_timeout: 10_000
      ] ++
        opts
    )
  end

  @doc "The Alambique id of a cell and the node that owns it, asked from `via`."
  def owner(cluster, via, ns, key) do
    cells = Module.concat(Cluster.instance(cluster), Cells)
    {:ok, result} = Cluster.call(cluster, via, Alambique, :owner, [cells, ns <> "." <> key])
    result
  end

  @doc "The peer name of a node."
  def name_of(cluster, node), do: Enum.find(Cluster.names(cluster), &(Cluster.node(cluster, &1) == node))

  @doc "POSTs `n` to the counter cell: `{status, body}`, or `{:error, reason}`."
  def write(cluster, via, cell, n) do
    case request(cluster, via, :post, "/c/#{cell}", body: Integer.to_string(n)) do
      {:ok, resp} -> {resp.status, resp.body}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "A cell woken through `n1` and the peer that owns it, among `wanted` (after the cell was woken)."
  def owned_cell(cluster, prefix, wanted \\ [:n2, :n3]) do
    Enum.find_value(1..40, fn i ->
      cell = "#{prefix}#{i}"
      {200, _} = write(cluster, :n1, cell, 0)
      {:ok, node} = owner(cluster, :n1, "log", cell)
      if name_of(cluster, node) in wanted, do: {cell, name_of(cluster, node)}
    end)
  end

  @doc "Operating system time in microseconds, the clock that event timestamps use."
  def now, do: System.os_time(:microsecond)

  @doc "Posts to the cell through `via` until it answers 200; returns the ms since `t0` (from `now/0`)."
  def serve_again(cluster, via, cell, t0) do
    Atanor.Test.Await.until(
      fn ->
        case write(cluster, via, cell, System.unique_integer([:positive])) do
          {200, _} -> div(now() - t0, 1_000)
          _ -> nil
        end
      end,
      60_000
    )
  end

  @doc "Events of the cluster matching `event` and a predicate on `meta`."
  def events(cluster, event, fun \\ fn _ -> true end),
    do: for(%{event: ^event} = e <- Cluster.events(cluster), fun.(e.meta), do: e)

  @doc "Like `events/3`, once one matches: nodes forward their events to the cluster asynchronously."
  def await_events(cluster, event, fun \\ fn _ -> true end),
    do: Await.until(fn -> events(cluster, event, fun) |> then(&(&1 != [] and &1)) end)

  @doc "What `via`'s detector knows of its peers, by peer name."
  def views(cluster, via) do
    {:ok, peers} = Cluster.call(cluster, via, Atanor.Detector, :peers, [Cluster.instance(cluster)])
    Map.new(peers, &{name_of(cluster, &1.node), &1})
  end

  @doc "The state `via` has for `target`."
  def state(cluster, via, target), do: views(cluster, via)[target].state

  def await_state(cluster, via, target, expected, timeout \\ 15_000),
    do: Await.until(fn -> state(cluster, via, target) == expected end, timeout)

  @doc "The first node event of `observer` about `target`, with its operating system time."
  def event(cluster, observer, name, target, fun \\ fn _ -> true end) do
    node = Cluster.node(cluster, target)

    Enum.find(Cluster.events(cluster), fn e ->
      e.node == observer and e.event == [:atanor, :node, name] and e.meta.node == node and fun.(e.meta)
    end)
  end

  def await_event(cluster, observer, name, target, fun \\ fn _ -> true end),
    do: Await.until(fn -> event(cluster, observer, name, target, fun) end, 20_000)

  def events_about(cluster, names) do
    for e <- Cluster.events(cluster), e.event in Enum.map(names, &[:atanor, :node, &1]), do: e
  end

  def ms_since(t0, event), do: div(event.at - t0, 1_000)
end
