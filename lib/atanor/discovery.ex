defmodule Atanor.Discovery do
  @moduledoc """
  Connects this node to the nodes that Alambique's node registry lists (design §8.16).

  It runs when the instance has `alambique: [registry: ...]` and the VM is distributed. Each peer of
  `Alambique.peers/1` carries an `advertise`, which is the Erlang node name of the peer
  (`atanor@node-2.cluster`). On `[:alambique, :registry, :peers_changed]` and every refresh period it
  dials the peers it is not connected to.

  Only the peers of the same group are dialled: the group is the `"group"` of the registry's `meta`
  (`ATANOR_GROUP` in the daemon), and none matches none. A node of another group, such as the node that
  replaces this one in a swap, is listed in the store and is left alone.

  It never disconnects a node, and a peer that leaves the registry stays connected: the failure
  detector decides when a connected peer is down (design §8.7). A peer that expired or left is dialled
  no more, because only the current listing is read.

  Events: `[:atanor, :discovery, :joined | :left | :connect | :invalid | :ignored]` (docs/telemetry.md).
  """
  use GenServer

  require Logger

  @default_refresh_ms 10_000
  # A Node.connect that cannot reach a host takes net_setuptime (7 s); the dial runs in a task.
  @max_dials 16
  # Erlang node name: name@host, no space, at most 255 characters.
  @node_name ~r/\A[A-Za-z0-9_.+-]+@[A-Za-z0-9_.:-]+\z/

  @type peer :: %{required(:advertise) => String.t(), optional(atom) => term}

  @doc """
  The nodes to dial: the nodes of the `peers` of `group`, minus `self` and the `connected` ones, without
  duplicates, and the `advertise` strings that are not node names.
  """
  @spec targets([peer], node, [node], String.t() | nil) :: {[node], [String.t()]}
  def targets(peers, self, connected, group \\ nil) do
    {valid, invalid} =
      peers
      |> Enum.filter(&(group_of(&1) == group))
      |> Enum.map(& &1.advertise)
      |> Enum.split_with(&(is_binary(&1) and byte_size(&1) <= 255 and Regex.match?(@node_name, &1)))

    nodes =
      valid
      |> Enum.uniq()
      |> Enum.map(&String.to_atom/1)
      |> Enum.reject(&(&1 == self or &1 in connected))

    {nodes, invalid}
  end

  @doc "The group of a peer or of a registry's options: `meta[\"group\"]`, or `nil`."
  @spec group_of(map | keyword) :: String.t() | nil
  def group_of(%{meta: meta}), do: Map.get(meta || %{}, "group")
  def group_of(registry) when is_list(registry), do: registry |> Keyword.get(:meta, %{}) |> Map.get("group")

  @doc """
  Starts the process for an Alambique instance.

  Options: `:instance` (the instance) and `:refresh_ms` (see `refresh_ms/1`), and for tests
  `:peers` (a function that returns the listing), `:connect` (a function of a node that returns a
  boolean) and `:self`.
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc "The refresh period of an instance: the registry's `refresh_ms`, else its `renew_ms`, else 10 s."
  @spec refresh_ms(keyword) :: pos_integer
  def refresh_ms(registry), do: registry[:refresh_ms] || registry[:renew_ms] || @default_refresh_ms

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    instance = Keyword.fetch!(opts, :instance)
    me = self()
    id = {__MODULE__, instance}

    :telemetry.attach(
      id,
      [:alambique, :registry, :peers_changed],
      &__MODULE__.peers_changed/4,
      {me, instance}
    )

    {:ok, tasks} = Task.Supervisor.start_link()

    state = %{
      instance: instance,
      id: id,
      refresh_ms: Keyword.fetch!(opts, :refresh_ms),
      peers: Keyword.get(opts, :peers, fn -> Alambique.peers(instance) end),
      connect: Keyword.get(opts, :connect, &Node.connect/1),
      self: Keyword.get(opts, :self, node()),
      group: Keyword.get(opts, :group),
      tasks: tasks,
      dialing: MapSet.new(),
      failing: MapSet.new()
    }

    send(self(), :dial)
    {:ok, state}
  end

  @doc false
  # Runs in the registry process of Alambique: only tells this process.
  def peers_changed(_event, _measurements, %{instance: instance} = meta, {pid, instance}),
    do: send(pid, {:peers_changed, meta})

  def peers_changed(_event, _measurements, _meta, _config), do: :ok

  @impl true
  def handle_info({:peers_changed, meta}, state) do
    announce(:joined, state.instance, Map.get(meta, :joined, []))
    ignore(state, Map.get(meta, :joined, []))
    announce(:left, state.instance, Map.get(meta, :left, []))
    {:noreply, dial(state)}
  end

  def handle_info(:dial, state) do
    Process.send_after(self(), :dial, state.refresh_ms)
    {:noreply, dial(state)}
  end

  def handle_info({:dialed, node, result}, state) do
    :telemetry.execute([:atanor, :discovery, :connect], %{}, %{instance: state.instance, node: node, result: result})
    dialing = MapSet.delete(state.dialing, node)

    failing =
      case result do
        :ok ->
          if node in state.failing, do: Logger.info("atanor discovery: connected to #{node} after failing")
          MapSet.delete(state.failing, node)

        :failed ->
          unless node in state.failing, do: Logger.warning("atanor discovery: cannot connect to #{node}; trying again")
          MapSet.put(state.failing, node)
      end

    {:noreply, %{state | dialing: dialing, failing: failing}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: :telemetry.detach(state.id)

  # The listing is read at each dial: the dial set is exactly the live peers now, minus this node and
  # the nodes that are connected or being dialled.
  defp dial(state) do
    {nodes, invalid} = targets(state.peers.(), state.self, Node.list(), state.group)

    for advertise <- invalid do
      Logger.warning(
        "atanor discovery: ignoring a peer that advertises #{inspect(advertise)}, which is not a node name"
      )

      :telemetry.execute([:atanor, :discovery, :invalid], %{}, %{instance: state.instance, advertise: advertise})
    end

    nodes =
      nodes |> Enum.reject(&MapSet.member?(state.dialing, &1)) |> Enum.take(@max_dials - MapSet.size(state.dialing))

    me = self()
    connect = state.connect

    for node <- nodes do
      Task.Supervisor.start_child(state.tasks, fn ->
        send(me, {:dialed, node, if(connect.(node) == true, do: :ok, else: :failed)})
      end)
    end

    %{state | dialing: Enum.into(nodes, state.dialing)}
  end

  defp ignore(state, peers) do
    for %{advertise: advertise, node_id: node_id} = peer <- peers, group_of(peer) != state.group do
      Logger.info("atanor discovery: not connecting to #{node_id}, which is of group #{inspect(group_of(peer))}")

      :telemetry.execute([:atanor, :discovery, :ignored], %{}, %{
        instance: state.instance,
        node_id: node_id,
        advertise: advertise
      })
    end
  end

  defp announce(event, instance, peers) do
    for %{advertise: advertise, node_id: node_id} <- peers do
      Logger.info("atanor discovery: peer #{node_id} #{event} (#{advertise})")

      :telemetry.execute([:atanor, :discovery, event], %{}, %{
        instance: instance,
        node_id: node_id,
        advertise: advertise
      })
    end
  end
end
