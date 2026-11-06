defmodule Atanor.Deployments.Watcher do
  @moduledoc """
  Applies the store's heads on a node (design §2). It loads every head when it
  starts, before the node joins the cluster (design §2.1), again every `:poll_interval_ms`, and when a node that moved a head
  sends a notice over the `:pg` group of the store's prefix, so polling repairs
  missed notices.

  A head is applied by fetching its package, checking the hash, and
  activating it through `Atanor.Workers`. A head that cannot be applied
  (`{:code_mismatch, expected, loaded}`, a route the operator does not allow,
  a package that does not parse) leaves the previous deployment serving and is
  recorded in `Atanor.Deployments.status/1`. It is retried only when the head
  changes, whereas store errors and a module the node does not have yet
  (`{:module_not_loaded, name}`) are retried at the next poll.

  The first load is complete when every head was read and either applied or
  recorded as failed, so one broken worker does not keep the node out. A store
  error is not a result: the load repeats every `:ready` `:retry_ms` and, after
  `:timeout_ms`, the watcher stops and the instance does not start.
  """
  use GenServer

  require Logger

  alias Atanor.{Deployments, Package, Registry, Store, Workers}
  alias Atanor.Deployments.Head

  @scope Atanor.PG

  def child_spec(config) do
    %{id: __MODULE__, start: {GenServer, :start_link, [__MODULE__, config, [name: server(config.name)]]}}
  end

  @doc false
  def status(name), do: GenServer.call(server(name), :status)

  @doc false
  def sync(name), do: GenServer.call(server(name), :sync, :infinity)

  @doc "Tells the nodes sharing the instance's store that `worker`'s head changed."
  @spec notify(atom, String.t()) :: :ok
  def notify(name, worker) do
    for pid <- :pg.get_members(@scope, group(Registry.config(name).prefix)), do: send(pid, {:head_changed, worker})
    :ok
  end

  @doc "The nodes that run an instance with the same prefix as `name`, this one included."
  @spec nodes(atom) :: [node]
  def nodes(name),
    do:
      @scope |> :pg.get_members(group(Registry.config(name).prefix)) |> Enum.map(&node/1) |> Enum.uniq() |> Enum.sort()

  defp server(name), do: Module.concat(name, Watcher)
  defp group(prefix), do: {Deployments, prefix}

  @impl true
  def init(config) do
    state = %{
      name: config.name,
      poll_ms: config.poll_interval_ms,
      seen: %{},
      heads: %{},
      status: %{},
      cache: %{},
      listing: nil,
      pending: %{}
    }

    started = System.monotonic_time()
    deadline = System.monotonic_time(:millisecond) + config.ready.timeout_ms

    case first_load(state, config.ready.retry_ms, deadline) do
      {:ok, state} ->
        :telemetry.execute(
          [:atanor, :deployments, :loaded],
          %{duration: System.monotonic_time() - started, workers: map_size(state.status)},
          %{instance: config.name, node: node()}
        )

        Registry.put_state(config.name, {:starting, "joining the cluster"})
        :pg.join(@scope, group(config.prefix), self())
        Process.send_after(self(), :poll, state.poll_ms)
        {:ok, state}

      {:error, reason} ->
        {:stop, {:deployments_not_loaded, reason}}
    end
  end

  defp first_load(state, retry_ms, deadline) do
    state = load_all(state)

    case unloaded(state) do
      nil ->
        {:ok, state}

      reason ->
        Registry.put_state(state.name, {:starting, reason})

        if System.monotonic_time(:millisecond) + retry_ms > deadline do
          {:error, reason}
        else
          Process.sleep(retry_ms)
          first_load(state, retry_ms, deadline)
        end
    end
  end

  defp unloaded(%{listing: reason}) when reason != nil, do: "could not list the workers: #{inspect(reason)}"

  defp unloaded(%{pending: pending}) do
    case Enum.sort(pending) do
      [] -> nil
      [{worker, reason} | _] -> "could not read #{worker}: #{inspect(reason)}"
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}
  def handle_call(:sync, _from, state), do: {:reply, :ok, load_all(state)}

  @impl true
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, state.poll_ms)
    {:noreply, load_all(state)}
  end

  def handle_info({:head_changed, worker}, state), do: {:noreply, load_worker(state, worker)}
  def handle_info(_, state), do: {:noreply, state}

  defp load_all(state) do
    case Deployments.workers(state.name) do
      {:ok, workers} ->
        workers |> Enum.reduce(%{state | listing: nil, pending: %{}}, &load_worker(&2, &1)) |> prune_cache()

      {:error, reason} ->
        Logger.warning("atanor: could not list the workers in the store: #{inspect(reason)}")
        %{state | listing: reason}
    end
  end

  defp load_worker(state, worker) do
    state = %{state | pending: Map.delete(state.pending, worker)}

    case Store.get(state.name, "workers/#{worker}/head") do
      {:ok, json, etag, _meta} ->
        if state.seen[worker] == etag, do: state, else: decode_head(state, worker, etag, json)

      {:error, :not_found} ->
        state

      {:error, reason} ->
        Logger.warning("atanor: could not read the head of #{worker}: #{inspect(reason)}")
        %{state | pending: Map.put(state.pending, worker, reason)}
    end
  end

  defp decode_head(state, worker, etag, json) do
    case Head.decode(json) do
      {:ok, head} -> apply_head(%{state | heads: Map.put(state.heads, worker, head)}, worker, etag, head)
      {:error, reason} -> record(state, worker, etag, %{head: nil, error: reason})
    end
  end

  defp apply_head(state, worker, etag, %Head{active: nil}) do
    Workers.deactivate(state.name, worker)
    record(state, worker, etag, %{head: nil, applied: nil, error: nil})
  end

  defp apply_head(state, worker, etag, %Head{active: id}) do
    case state.status do
      %{^worker => %{applied: ^id}} ->
        record(state, worker, etag, %{head: id, error: nil})

      _ ->
        case package(state, id) do
          {:ok, package, state} -> activate(state, worker, etag, package)
          {:retry, reason} -> retry(state, worker, id, reason)
          {:error, reason} -> record(state, worker, etag, %{head: id, error: reason})
        end
    end
  end

  defp activate(state, worker, etag, package) do
    case safe_activate(state.name, package) do
      {:ok, _deployment} ->
        record(state, worker, etag, %{head: package.id, applied: package.id, error: nil})

      # The store could not say who owns a namespace: nothing is known about the package, so try again.
      {:error, {:store_unavailable, reason}} ->
        retry(state, worker, package.id, reason)

      # The node may get the module later (a deploy of the release, code loaded by hand): the head stays
      # unseen, so every poll tries it again, and the first load does not wait for it.
      {:error, {:module_not_loaded, _} = reason} ->
        if state.status[worker][:error] != reason,
          do: Logger.warning("atanor: worker #{worker}, package #{package.id} not applied: #{inspect(reason)}")

        put_status(state, worker, %{head: package.id, error: reason})

      {:error, reason} ->
        Logger.warning("atanor: worker #{worker}, package #{package.id} not applied: #{inspect(reason)}")
        record(state, worker, etag, %{head: package.id, error: reason})
    end
  end

  # One head must never stop the node from applying the others: a crash while applying is that head's error.
  defp safe_activate(name, package) do
    Workers.activate(name, package)
  rescue
    exception ->
      Logger.error("atanor: applying package #{package.id} crashed: #{Exception.message(exception)}")
      {:error, {:apply_crashed, exception.__struct__}}
  catch
    kind, reason ->
      Logger.error("atanor: applying package #{package.id} failed: #{inspect({kind, reason}, limit: 5)}")
      {:error, {:apply_crashed, kind}}
  end

  # A store error says nothing about the package: leave the head unseen.
  defp retry(state, worker, id, reason) do
    Logger.warning("atanor: could not fetch package #{id} of #{worker}: #{inspect(reason)}")
    put_status(%{state | pending: Map.put(state.pending, worker, reason)}, worker, %{head: id})
  end

  defp record(state, worker, etag, fields),
    do: put_status(%{state | seen: Map.put(state.seen, worker, etag)}, worker, fields)

  defp put_status(state, worker, fields) do
    current = Map.get(state.status, worker, %{head: nil, applied: nil, error: nil})
    %{state | status: Map.put(state.status, worker, Map.merge(current, fields))}
  end

  defp package(state, id) do
    case state.cache do
      %{^id => package} ->
        {:ok, package, state}

      _ ->
        case Deployments.fetch_package(state.name, id) do
          {:ok, %Package{} = package} -> {:ok, package, %{state | cache: Map.put(state.cache, id, package)}}
          {:error, reason} -> if permanent?(reason), do: {:error, reason}, else: {:retry, reason}
        end
    end
  end

  defp permanent?(:not_found), do: true
  defp permanent?({:invalid_package, _}), do: true
  defp permanent?({:package_id_mismatch, _, _}), do: true
  defp permanent?(_), do: false

  # Packages are immutable, so the cache keeps the active and the previous
  # package of each head: the ones a switch or a rollback needs next.
  defp prune_cache(state) do
    keep =
      for {_, head} <- state.heads, id <- [head.active | Enum.take(head.previous, 1)], id, into: MapSet.new(), do: id

    %{state | cache: Map.filter(state.cache, fn {id, _} -> id in keep end)}
  end
end
