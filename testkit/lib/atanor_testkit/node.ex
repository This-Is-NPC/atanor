defmodule AtanorTestkit.Node do
  @moduledoc """
  One Atanor instance over an `AlambiqueTestkit.MemoryStore`, with a temporary
  data directory and an ephemeral HTTP port (design §11).

      node = AtanorTestkit.Node.start(workers: [manifest])
      on_exit(fn -> AtanorTestkit.Node.stop(node) end)

  `workers:` lists manifest maps whose modules are compiled in this VM; each
  is deployed (published, activated and applied) before `start/1` returns, and
  `start/1` raises when one cannot be applied.

  The node is not linked to the caller, so it outlives the test process until
  `stop/1` runs. Its instance and store stop in order, so cells hibernate
  before the store goes away. Pass `store:` to use another `{module, config}`
  store; the node then does not own it, and must be stopped first.
  """

  alias AlambiqueTestkit.MemoryStore

  @enforce_keys [:name, :pid, :url, :port, :data_dir, :store]
  defstruct [:name, :pid, :url, :port, :data_dir, :store]

  @type t :: %__MODULE__{}

  @doc "Starts a node. Options are those of `Atanor`, with an ephemeral port and a temporary data directory."
  @spec start(keyword) :: t
  def start(opts \\ []) do
    id = System.unique_integer([:positive])
    name = Keyword.get(opts, :name, Module.concat(__MODULE__, "N#{id}"))
    data_dir = Keyword.get(opts, :data_dir, Path.join(System.tmp_dir!(), "atanor-#{id}"))
    File.mkdir_p!(data_dir)

    {store_children, store} =
      case opts[:store] do
        nil ->
          server = Module.concat(name, Store)

          {[%{id: :store, start: {MemoryStore, :start_link, [[name: server]]}}],
           {MemoryStore, MemoryStore.config(server)}}

        store ->
          {[], store}
      end

    # The alarm schedulers and the sockets of one prefix form :pg groups that
    # span the VM, so nodes get a prefix per store: only nodes that share a
    # store (a cluster) may share a prefix.
    prefix = "t#{:erlang.phash2(store)}"

    atanor_opts =
      Keyword.merge([port: 0, prefix: prefix], Keyword.drop(opts, [:store, :workers, :data_dir, :name])) ++
        [name: name, data_dir: data_dir, store: store]

    {:ok, pid} = Supervisor.start_link(store_children ++ [{Atanor, atanor_opts}], strategy: :one_for_one)
    Process.unlink(pid)
    port = Atanor.port(name)

    node = %__MODULE__{
      name: name,
      pid: pid,
      url: "http://127.0.0.1:#{port}",
      port: port,
      data_dir: data_dir,
      store: store
    }

    for manifest <- Keyword.get(opts, :workers, []) do
      case deploy(node, manifest) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          stop(node)
          raise "worker #{manifest["name"]} not deployed: #{inspect(reason)}"
      end
    end

    node
  end

  @doc "Deploys a worker on the node: see `Atanor.Dev.deploy/3`."
  @spec deploy(t, map) :: {:ok, Atanor.Deployment.t()} | {:error, term}
  def deploy(%__MODULE__{name: name}, manifest_map), do: Atanor.Dev.deploy(name, manifest_map)

  @doc "Deactivates a worker on the node: see `Atanor.Dev.undeploy/2`."
  @spec undeploy(t, String.t()) :: {:ok, Atanor.Deployments.Head.t()} | {:error, term}
  def undeploy(%__MODULE__{name: name}, worker), do: Atanor.Dev.undeploy(name, worker)

  @doc "Stops the node and its store, and removes its data directory."
  @spec stop(t) :: :ok
  def stop(%__MODULE__{} = node) do
    if Process.alive?(node.pid), do: Supervisor.stop(node.pid)

    File.rm_rf!(node.data_dir)
    :ok
  end
end
