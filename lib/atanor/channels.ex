defmodule Atanor.Channels do
  @moduledoc """
  Ephemeral channels (design §7.6): messages for the sockets that joined a
  cell's channel, on any node. A message is never written to the cell, runs no
  transaction and needs no call on the cell's owner.

  A socket joins a `:pg` group named by the instance's prefix and the cell.
  Membership lives on the socket's own node. A publisher sends one message to
  the `Atanor.Channels` server of each node that has members; the server sends
  it to its local members. Messages of one publisher reach each subscriber in
  the order they were published.

  Delivery skips a member whose mailbox holds more than `max_queue` messages, so
  a slow client cannot make its node's memory grow without bound.

  The server of a node also counts what its sockets joined, for the limits of
  the `:channels` option, and what they attached to cells, for `:sockets`'
  `:max_attachments`, and answers presence queries.
  """

  use GenServer

  alias Atanor.{Cell, Registry}

  @scope Atanor.PG
  @type frame :: {:text | :binary, binary}

  @doc false
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Joins the socket `pid` to the channel of `cell`, known to the others by `id`
  (`nil` for an anonymous member). Joining again replaces the id. A remote join
  asks the socket's own node and is bounded by `:sockets`' `:attach_timeout_ms`.
  """
  @spec join(atom, pid, Cell.address(), binary | nil) :: :ok | {:error, term}
  def join(instance, pid, cell, id) when node(pid) == node() do
    channels = Registry.config(instance).channels
    GenServer.call(__MODULE__, {:join, pid, group(instance, cell), id, channels})
  end

  def join(instance, pid, cell, id), do: remote(instance, node(pid), __MODULE__, :join, [instance, pid, cell, id])

  @doc false
  # Attaches the local socket `pid` to the `Atanor.Sockets` group, counted against `max` per socket.
  @spec attach(pid, term, pos_integer) :: :ok | {:error, :too_many_attachments}
  def attach(pid, group, max), do: GenServer.call(__MODULE__, {:attach, pid, group, max})

  @doc "Removes the socket `pid` from the channel of `cell`; succeeds when it is not in it."
  @spec leave(atom, pid, Cell.address()) :: :ok | {:error, term}
  def leave(instance, pid, cell) when node(pid) == node(),
    do: GenServer.call(__MODULE__, {:leave, pid, group(instance, cell)})

  def leave(instance, pid, cell), do: remote(instance, node(pid), __MODULE__, :leave, [instance, pid, cell])

  @doc """
  Sends `frame` to the members of the channel of `cell` on every node, one
  message per node. `{:error, :too_large}` when it is over `:max_message_bytes`.
  """
  @spec publish(atom, Cell.address(), frame) :: :ok | {:error, :too_large}
  def publish(instance, cell, {_kind, data} = frame) do
    if byte_size(data) > Registry.config(instance).channels.max_message_bytes do
      rejected(:too_large, cell)
    else
      {nodes, subscribers} = broadcast(instance, group(instance, cell), {:atanor_channel, frame})

      :telemetry.execute(
        [:atanor, :channel, :publish],
        %{count: 1, bytes: byte_size(data), nodes: nodes, subscribers: subscribers},
        %{
          instance: instance,
          cell: cell
        }
      )
    end
  end

  @doc """
  Who is in the channel of `cell`, on any node: the number of members and the
  ids the anonymous ones lack.
  """
  @spec members(atom, Cell.address()) :: {:ok, %{count: non_neg_integer, ids: [binary]}} | {:error, term}
  def members(instance, cell) do
    group = group(instance, cell)
    pids = :pg.get_members(@scope, group)
    timeout = Registry.config(instance).sockets.attach_timeout_ms
    nodes = pids |> Enum.map(&node/1) |> Enum.uniq()

    results = :erpc.multicall(nodes, GenServer, :call, [__MODULE__, {:ids, group}], timeout)

    if Enum.all?(results, &match?({:ok, _}, &1)),
      do: {:ok, %{count: length(pids), ids: Enum.flat_map(results, fn {:ok, ids} -> ids end)}},
      else: {:error, :node_unreachable}
  end

  @doc false
  # Sends `message` to the members of `group` on every node: one message per
  # node, then a send per local member (`deliver/3`). Returns `{nodes,
  # subscribers}`. Used by `Atanor.Sockets` too.
  @spec broadcast(atom, term, term) :: {non_neg_integer, non_neg_integer}
  def broadcast(instance, group, message) do
    max_queue = Registry.config(instance).channels.max_queue
    pids = :pg.get_members(@scope, group)

    {local, remote} = Enum.split_with(pids, &(node(&1) == node()))
    deliver(local, group, message, max_queue)

    remote_nodes = remote |> Enum.map(&node/1) |> Enum.uniq()
    for node <- remote_nodes, do: send({__MODULE__, node}, {:atanor_broadcast, group, message, max_queue})

    {length(remote_nodes) + if(local == [], do: 0, else: 1), length(pids)}
  end

  # The one local delivery. A member with more than `max_queue` messages waiting
  # is too slow to follow: it misses this one, and the drops are counted.
  defp deliver(pids, group, message, max_queue) do
    dropped =
      Enum.count(pids, fn pid ->
        slow? = match?({:message_queue_len, n} when n > max_queue, Process.info(pid, :message_queue_len))
        if not slow?, do: send(pid, message)
        slow?
      end)

    if dropped > 0,
      do: :telemetry.execute([:atanor, :channel, :dropped], %{count: dropped}, %{cell: cell_of(group), node: node()})
  end

  @doc false
  def group(instance, {ns, key}), do: {__MODULE__, Registry.config(instance).prefix, ns, key}

  @doc false
  # A call to the socket's own node, bounded by `:sockets`' `:attach_timeout_ms`.
  # `{:error, :node_unreachable}` when the node does not answer.
  def remote(instance, node, module, fun, args) do
    timeout = Registry.config(instance).sockets.attach_timeout_ms

    try do
      :erpc.call(node, module, fun, args, timeout)
    catch
      _kind, _reason -> {:error, :node_unreachable}
    end
  end

  # pids: %{pid => {monitor, %{group => id}}} (channels and attachments); groups: %{channel => members on
  # this node}; spaces: %{namespace => channels with a member on this node}.
  @impl true
  def init(nil), do: {:ok, %{pids: %{}, groups: %{}, spaces: %{}}}

  @impl true
  def handle_call({:join, pid, group, id, limits}, _from, state) do
    {monitor, joined} = Map.get(state.pids, pid, {nil, %{}})

    cond do
      is_map_key(joined, group) ->
        {:reply, :ok, put_in(state.pids[pid], {monitor, Map.put(joined, group, id)})}

      count(joined, true) >= limits.max_subscriptions ->
        {:reply, rejected(:too_many_subscriptions, cell_of(group)), state}

      not is_map_key(state.groups, group) and map_size(state.groups) >= limits.max_channels ->
        {:reply, rejected(:too_many_channels, cell_of(group)), state}

      not is_map_key(state.groups, group) and
          Map.get(state.spaces, namespace(group), 0) >= limits.max_channels_per_namespace ->
        {:reply, rejected(:too_many_channels, cell_of(group)), state}

      true ->
        :ok = :pg.join(@scope, group, pid)
        monitor = monitor || Process.monitor(pid)
        state = put_in(state.pids[pid], {monitor, Map.put(joined, group, id)})
        {:reply, :ok, add_group(state, group)}
    end
  end

  def handle_call({:attach, pid, group, max}, _from, state) do
    {monitor, joined} = Map.get(state.pids, pid, {nil, %{}})

    cond do
      is_map_key(joined, group) ->
        {:reply, :ok, state}

      count(joined, false) >= max ->
        {:reply, rejected(:too_many_attachments, cell_of(group)), state}

      true ->
        :ok = :pg.join(@scope, group, pid)
        monitor = monitor || Process.monitor(pid)
        {:reply, :ok, put_in(state.pids[pid], {monitor, Map.put(joined, group, nil)})}
    end
  end

  def handle_call({:leave, pid, group}, _from, state), do: {:reply, :ok, leave_group(state, pid, group)}

  def handle_call({:ids, group}, _from, state) do
    ids = for pid <- :pg.get_local_members(@scope, group), id = state.pids[pid] |> joined_id(group), do: id
    {:reply, ids, state}
  end

  @impl true
  def handle_info({:atanor_broadcast, group, message, max_queue}, state) do
    deliver(:pg.get_local_members(@scope, group), group, message, max_queue)
    {:noreply, state}
  end

  def handle_info({:DOWN, _monitor, :process, pid, _reason}, state) do
    {{_, joined}, pids} = Map.pop(state.pids, pid, {nil, %{}})
    state = joined |> Map.keys() |> Enum.filter(&channel?/1) |> Enum.reduce(%{state | pids: pids}, &drop_group(&2, &1))
    {:noreply, state}
  end

  defp joined_id({_monitor, joined}, group), do: joined[group]
  defp joined_id(nil, _group), do: nil

  defp leave_group(state, pid, group) do
    case state.pids do
      %{^pid => {monitor, %{^group => _} = joined}} ->
        :pg.leave(@scope, group, pid)
        joined = Map.delete(joined, group)

        pids =
          if joined == %{} do
            Process.demonitor(monitor, [:flush])
            Map.delete(state.pids, pid)
          else
            Map.put(state.pids, pid, {monitor, joined})
          end

        drop_group(%{state | pids: pids}, group)

      _ ->
        state
    end
  end

  defp channel?(group), do: elem(group, 0) == __MODULE__
  defp count(joined, channels?), do: Enum.count(joined, fn {group, _} -> channel?(group) == channels? end)
  defp namespace({_, _prefix, ns, _key}), do: ns

  defp add_group(state, group) do
    case state.groups do
      %{^group => n} ->
        put_in(state.groups[group], n + 1)

      _ ->
        %{
          state
          | groups: Map.put(state.groups, group, 1),
            spaces: Map.update(state.spaces, namespace(group), 1, &(&1 + 1))
        }
    end
  end

  defp drop_group(state, group) do
    case state.groups do
      %{^group => 1} ->
        ns = namespace(group)

        spaces =
          if state.spaces[ns] == 1, do: Map.delete(state.spaces, ns), else: Map.update!(state.spaces, ns, &(&1 - 1))

        %{state | groups: Map.delete(state.groups, group), spaces: spaces}

      %{^group => n} ->
        put_in(state.groups[group], n - 1)
    end
  end

  defp cell_of({_, _prefix, ns, key}), do: {ns, key}

  defp rejected(reason, cell) do
    :telemetry.execute([:atanor, :channel, :rejected], %{count: 1}, %{reason: reason, cell: cell})
    {:error, reason}
  end
end
