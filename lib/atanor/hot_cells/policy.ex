defmodule Atanor.HotCells.Policy do
  @moduledoc """
  The decisions of the placement of hot cells (design §8.15) as pure functions of
  the metrics, the view of the cluster and the settings (`hot_cells:`). The
  `Atanor.HotCells` server collects the inputs and acts on the answer.
  """

  @typedoc "What one cell did since the last sample: calls per second and calls waiting on the cell."
  @type sample :: %{reads: number, writes: number, queue: non_neg_integer}

  @typedoc "What a node tells its peers."
  @type load :: %{cpu: number, tags: [String.t()], hot: non_neg_integer, age_ms: non_neg_integer}

  @type stay :: :not_pressured | :residence | :cap | :cooldown | :on_dedicated | :no_target | :no_margin
  @type decision :: {:move, node, :load | :affinity} | {:stay, stay}

  @doc """
  Whether a cell is hot. A cell that was hot stays hot until every signal is
  under its exit threshold; a cell that was not becomes hot when one signal
  reaches its enter threshold.
  """
  @spec hot?(boolean, sample, map) :: boolean
  def hot?(was_hot?, sample, cfg) do
    if was_hot? do
      sample.writes >= cfg.write_exit or sample.reads >= cfg.read_exit or sample.queue >= cfg.queue_exit
    else
      sample.writes >= cfg.write_enter or sample.reads >= cfg.read_enter or sample.queue >= cfg.queue_enter
    end
  end

  @doc "Whether the node is under CPU pressure, with the same two thresholds as `hot?/3`."
  @spec pressured?(boolean, number, map) :: boolean
  def pressured?(true, cpu, cfg), do: cpu >= cfg.cpu_exit
  def pressured?(false, cpu, cfg), do: cpu >= cfg.cpu_enter

  @typedoc "The replica switch of a cell on its owner (see `replicas/4`)."
  @type replicas :: %{since: integer | nil, on: boolean, hot_at: integer, pending: boolean}

  @doc """
  What to do with the read replicas of a cell that this node serves, given its reads per second in the
  cluster (design §19.4). Returns the entry to keep and `:on`, `:off` or `nil`.

  A cell with `replica_enter` reads per second for `sustain_ms` gets its replicas turned on. They stay on until
  the rate has been under `replica_exit` for `replica_hold_ms`. The entry changes `on` only when the change was
  made (`confirm_replicas/3`).
  """
  @spec replicas(replicas | nil, number, integer, map) :: {replicas | nil, :on | :off | nil}
  def replicas(nil, reads, now, cfg) do
    if reads >= cfg.replica_enter,
      do: replicas(%{since: now, on: false, hot_at: now, pending: false}, reads, now, cfg),
      else: {nil, nil}
  end

  def replicas(%{pending: true} = entry, _reads, _now, _cfg), do: {entry, nil}

  def replicas(%{on: false} = entry, reads, now, cfg) do
    cond do
      reads < cfg.replica_enter -> {nil, nil}
      now - entry.since >= cfg.sustain_ms -> {%{entry | hot_at: now}, :on}
      true -> {%{entry | hot_at: now}, nil}
    end
  end

  def replicas(%{on: true} = entry, reads, now, cfg) do
    entry = if reads >= cfg.replica_exit, do: %{entry | hot_at: now}, else: entry
    {entry, if(now - entry.hot_at >= cfg.replica_hold_ms, do: :off)}
  end

  @doc "The entry after `action` was made (`true`) or failed (`false`): a failure is tried again at the next sample."
  @spec confirm_replicas(replicas, :on | :off, boolean) :: replicas | nil
  def confirm_replicas(entry, :on, true), do: %{entry | on: true, since: nil, pending: false}
  def confirm_replicas(_entry, :off, true), do: nil
  def confirm_replicas(entry, _action, false), do: %{entry | pending: false}

  @doc "How hot a cell is, to take the hottest first: its calls per second plus the calls waiting."
  @spec score(sample) :: number
  def score(sample), do: sample.reads + sample.writes + sample.queue

  @doc """
  Where to move a cell that has been hot long enough, if anywhere.

  `ctx` has:

    * `namespace` - the namespace of the cell;
    * `self` - `%{node:, cpu:, tags:, pressured: boolean}`;
    * `peers` - `%{node => load}` of the nodes that can receive a cell now: the
      caller leaves out those that are down, leaving, not members or not heard
      from recently;
    * `since_move_ms` - time since the cell last moved, or `nil`;
    * `moving` - moves in progress in the cluster;
    * `cooling` - `%{node => remaining_ms}` for nodes that took part in a move recently.

  The checks run in this order: residence time, cluster cap, cooldown of this
  node, then the affinity rule of the namespace (a node with the tag the rule
  names), then CPU pressure and the least loaded peer with the margin.
  """
  @spec decide(map, map) :: decision
  def decide(ctx, cfg) do
    cond do
      ctx.since_move_ms != nil and ctx.since_move_ms < cfg.residence_ms -> {:stay, :residence}
      ctx.moving >= cfg.max_moves -> {:stay, :cap}
      Map.has_key?(ctx.cooling, ctx.self.node) -> {:stay, :cooldown}
      true -> place(ctx, cfg)
    end
  end

  defp place(ctx, cfg) do
    ready = Map.reject(ctx.peers, fn {node, _} -> node == ctx.self.node or Map.has_key?(ctx.cooling, node) end)

    case affinity(ctx.namespace, cfg) do
      nil -> by_load(ctx, ready, cfg)
      tag -> by_tag(ctx, ready, tag, cfg)
    end
  end

  # A rule names a tag: the cell goes to a node that has it, whatever the load. A cell already on such a node
  # stays. With no such node to receive it, the load rule decides.
  defp by_tag(ctx, ready, tag, cfg) do
    tagged = Map.filter(ready, fn {_, load} -> tag in load.tags end)

    cond do
      tag in ctx.self.tags -> {:stay, :on_dedicated}
      tagged == %{} -> by_load(ctx, ready, cfg)
      true -> {:move, least_loaded(tagged), :affinity}
    end
  end

  # Only a node under pressure gives cells away, and only to a node that is less loaded by the margin. Nodes
  # that a rule reserves are not offered cells of other namespaces.
  defp by_load(ctx, ready, cfg) do
    reserved = for {_, tag} <- cfg.affinity, do: tag
    open = Map.reject(ready, fn {_, load} -> Enum.any?(load.tags, &(&1 in reserved)) end)

    cond do
      not ctx.self.pressured -> {:stay, :not_pressured}
      open == %{} -> {:stay, :no_target}
      true -> margin(ctx, least_loaded(open), open, cfg)
    end
  end

  defp margin(ctx, target, open, cfg) do
    if open[target].cpu + cfg.margin <= ctx.self.cpu, do: {:move, target, :load}, else: {:stay, :no_margin}
  end

  defp least_loaded(loads), do: loads |> Enum.min_by(fn {node, load} -> {load.cpu, load.hot, node} end) |> elem(0)

  @doc "The tag that the affinity rules name for a namespace, or `nil`."
  @spec affinity(String.t(), map) :: String.t() | nil
  def affinity(namespace, cfg) do
    Enum.find_value(cfg.affinity, fn {ns, tag} -> if ns == namespace, do: tag end)
  end
end
