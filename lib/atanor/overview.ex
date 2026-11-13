defmodule Atanor.Overview do
  @moduledoc false
  # Read-only views of an instance, shared by the admin API and the dashboard
  # (design §10). The functions that describe one node are called on every node
  # of the instance with `:erpc`, so they stay public.

  alias Atanor.{
    Alarms,
    Cell,
    Deployments,
    Detector,
    Diagnostics,
    Jobs,
    Manifest,
    Registry,
    Release,
    Store,
    Sweeps,
    TCP
  }

  alias Atanor.Deployments.Watcher

  @doc "The nodes of the instance."
  def nodes(name), do: Watcher.nodes(name)

  def health(name) do
    %{
      status: status(Registry.state(name)),
      node: node(),
      nodes: nodes(name),
      workers: length(Registry.deployments(name)),
      store: store_breakers(name)
    }
  end

  @doc """
  The circuit breaker of each store location, read from its state without a request (design §10.2).
  It never changes `ready/1`: see design §10.2 for why an open breaker does not take the node out.
  """
  def store_breakers(name) do
    for {location, breaker} <- Alambique.breaker_status(alambique(name)), into: %{} do
      {location, %{breaker | state: Atom.to_string(breaker.state)}}
    end
  end

  @doc "The state of this node's drain, as the admin API shows it (design §8.11)."
  def drain(name), do: name |> Atanor.drain_status() |> drain_body()

  @doc false
  def drain_body(status) do
    errors =
      for {cell, reason} <- Map.get(status, :errors, []),
          do: %{cell: to_string_or_inspect(cell), reason: inspect(reason)}

    status |> Map.put(:errors, errors) |> Map.put(:node, node())
  end

  defp to_string_or_inspect(cell) when is_binary(cell), do: cell
  defp to_string_or_inspect(other), do: inspect(other)

  @doc "Whether this node serves, for a load balancer: the HTTP status and the body."
  def ready(name) do
    case Registry.state(name) do
      :ready -> {200, %{status: "ready", node: node()}}
      {:starting, reason} -> {503, %{status: "starting", node: node(), reason: reason}}
      :draining -> {503, %{status: "draining", node: node(), reason: "the node is handing its cells off"}}
      :stopping -> {503, %{status: "stopping", node: node(), reason: "the node is stopping"}}
    end
  end

  @doc """
  Whether this node can serve cells, for a balancer: `ready/1` plus a quorum. A node that lost
  the majority answers calls with 503 `no_quorum` (design §8.10); with `takeover.quorum` off it
  never does, so the quorum is not asked.
  """
  def serving(name) do
    case ready(name) do
      {200, body} ->
        if Registry.config(name).takeover.quorum and not quorum?(name),
          do: {503, %{body | status: "no_quorum"} |> Map.put(:reason, "this node is not a majority of the cluster")},
          else: {200, %{body | status: "serving"}}

      other ->
        other
    end
  end

  defp quorum?(name) do
    Detector.quorum?(name)
  catch
    :exit, _ -> false
  end

  defp status(:ready), do: "ok"
  defp status({:starting, _}), do: "starting"
  defp status(:draining), do: "draining"
  defp status(:stopping), do: "stopping"

  @doc "What this node's memory is made of (`GET /runtime`); the cgroup is the one of `:memory` `:cgroup_path`."
  def runtime(name) do
    Atanor.RuntimeSample.sample(name, Path.dirname(Registry.config(name).memory.cgroup_path))
  end

  @doc "The HTTP and TCP routes this node serves."
  def routes(name) do
    tcp =
      for listener <- Enum.sort(Registry.listeners(name)), {:ok, port} <- [TCP.port(name, listener)] do
        {:ok, deployment} = Registry.listener(name, listener)
        %{listener: listener, port: port, worker: Atanor.Deployment.worker(deployment)}
      end

    %{
      node: node(),
      http:
        for({host, path, worker} <- Enum.sort(Registry.routes(name)), do: %{host: host, path: path, worker: worker}),
      tcp: tcp
    }
  end

  @doc "How this node sees each of its peers: the failure detector's state, phi and last heartbeat."
  def peers(name) do
    nodes =
      for peer <- Detector.peers(name) do
        %{
          peer
          | node: Atom.to_string(peer.node),
            state: Atom.to_string(peer.state),
            reason: peer.reason && inspect(peer.reason)
        }
      end

    %{node: node(), nodes: nodes}
  end

  @doc "The placement of hot cells as this node sees it (design §8.15)."
  def hot_cells(name) do
    case Atanor.HotCells.status(name) do
      {:error, :disabled} -> %{enabled: false, node: node()}
      status -> status |> Map.put(:enabled, true) |> stringify()
    end
  end

  defp stringify(term) when is_atom(term) and term not in [nil, true, false], do: Atom.to_string(term)
  defp stringify(term) when is_map(term), do: Map.new(term, fn {k, v} -> {k, stringify(v)} end)
  defp stringify(term) when is_list(term), do: Enum.map(term, &stringify/1)
  defp stringify(term), do: term

  @doc "The platform says that `node` is gone (design §8.9)."
  def gone(name, node) do
    case Enum.find(Detector.peers(name), &(Atom.to_string(&1.node) == node)) do
      nil -> {:error, :unknown_node}
      peer -> with :ok <- Detector.gone(name, peer.node), do: {:ok, %{node: node, state: "down"}}
    end
  end

  @doc "The heads of all workers, from the store."
  def workers(name) do
    with {:ok, heads} <- Deployments.list(name),
         do: {:ok, %{workers: Enum.map(heads, &Atanor.Deployments.Head.to_map/1)}}
  end

  @doc "The head of one worker and the manifest this node serves for it."
  def worker(name, worker) do
    with {:ok, head} <- Deployments.head(name, worker) do
      deployment =
        case Registry.deployment(name, worker) do
          {:ok, deployment} -> Map.put(Manifest.to_map(deployment.manifest), "id", deployment.id)
          :error -> nil
        end

      {:ok, Map.put(Atanor.Deployments.Head.to_map(head), :deployment, deployment)}
    end
  end

  @doc "What this node applied for each worker, with the reason when it could not."
  def deployments(name) do
    status = Deployments.status(name)

    workers =
      for {worker, %{head: head, applied: applied, error: error}} <- Enum.sort(status) do
        active = with {:ok, deployment} <- Registry.deployment(name, worker), do: deployment.id

        %{
          worker: worker,
          head: head,
          applied: applied,
          serving: if(is_binary(active), do: active),
          error: error && inspect(error)
        }
      end

    %{release: Release.info(name), workers: workers}
  end

  @doc "One page of crash reports."
  def crashes(name, opts), do: Diagnostics.list(name, opts)

  @doc "One crash report."
  def crash(name, node, id), do: Diagnostics.get(name, node, id)

  @doc "Lets a frozen cell wake again and forgets its recorded crashes."
  def unfreeze(name, {ns, key}) do
    with {:ok, id} <- Cell.id({ns, key}) do
      Alambique.unfreeze(Registry.config(name).alambique, id)
    end
  end

  @doc "The number of live cells on this node."
  def cells_count(name), do: %{count: Alambique.cells(alambique(name), limit: 1).count}

  @doc "One page of the live cells of this node, in id order, after `after_id`."
  def cells_page(name, after_id, limit) do
    page = Alambique.cells(alambique(name), after: after_id, limit: limit)
    cells = for id <- page.cells, {:ok, {ns, key}} <- [Cell.parse(id)], do: %{namespace: ns, key: key, id: id}
    %{cells: cells, next: page.next}
  end

  @doc "One page of the pending alarms of the instance, from the store index."
  def alarms_page(name, after_key, limit), do: Alarms.pending(name, after_key, limit)

  @doc "The job slots of this node."
  def jobs_stats(name), do: Jobs.stats(name)

  @doc "One page of a cell's jobs."
  def jobs_page(name, {ns, key}, opts), do: Jobs.page(name, {ns, key}, opts)

  @doc "One job of a cell."
  def job(name, {ns, key}, id), do: Jobs.get(name, {ns, key}, id)

  @doc "The dead-letter index, newest last."
  def dead_letters(name, after_key, limit) do
    with {:ok, keys, _next} <- Store.list(Store.handle(name), "jobs/dead/", after_key, limit + 1) do
      {page, rest} = Enum.split(keys, limit)

      entries =
        for key <- page,
            {:ok, body, _etag, _meta} <- [Store.get(Store.handle(name), key)],
            do: Jason.decode!(body)

      {:ok, %{dead: entries, next: if(rest != [], do: List.last(page))}}
    end
  end

  @doc "The operation records."
  def operations(name, after_key \\ nil, limit \\ 100), do: Sweeps.list(name, after_key, limit)

  @doc "One operation."
  def operation(name, id) do
    case Sweeps.get(name, id) do
      {:ok, op, _etag} -> {:ok, op}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Asks every node of the instance for `fun`; a node that fails is marked."
  def gather(name, fun, args \\ []) do
    nodes = nodes(name)
    timeout = Registry.config(name).overview.timeout_ms
    results = :erpc.multicall(nodes, __MODULE__, fun, [name | args], timeout)

    entries =
      for {node, result} <- Enum.zip(nodes, results), into: %{} do
        case result do
          {:ok, report} -> {Atom.to_string(node), Map.put(report, :status, :ok)}
          {_class, reason} -> {Atom.to_string(node), %{status: :error, reason: inspect(reason)}}
        end
      end

    %{partial: Enum.any?(entries, fn {_, report} -> report.status == :error end), nodes: entries}
  end

  @doc "Calls `fun` on one node."
  def call_node(name, node, fun, args) do
    {:ok, :erpc.call(node, __MODULE__, fun, [name | args], Registry.config(name).overview.timeout_ms)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp alambique(name), do: Registry.config(name).alambique
end
