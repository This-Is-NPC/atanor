defmodule Atanor.Rebalance.Plan do
  @moduledoc false
  # The decisions of the rebalance on join (design §8.1), with no process and no clock so that they can be
  # checked alone. A plan belongs to one membership. It is made of rounds: a round lists the cells awake here
  # whose preferred node is another, coldest first, and hands them out one by one.
  #
  # `attempted` is the guard against loops: a cell this plan handed out is not handed out again while the
  # membership stays, whether its move worked, failed, or the cell came back to this node. A cell that was
  # looked at and left (`:stay`: asleep, pinned, its target blocked) is not looked at again either, so that
  # the rounds end.

  defstruct queue: :queue.new(), tries: %{}, deferred: 0, attempted: MapSet.new()

  @type id :: String.t()
  @type t :: %__MODULE__{}
  @type verdict :: {:move, node} | :stay | :busy

  # Examined per step, and how many steps a busy cell is tried before the round leaves it for the next one.
  @examine 20
  @busy_tries 4

  @spec new :: t
  def new, do: %__MODULE__{}

  @doc """
  Starts a round from `entries`, a list of `{id, last_used}` (`last_used` is `nil` while the cell wakes).
  `preferred` maps an id to its preferred node, `self` is this node and `pinned` the cells to leave alone.
  """
  @spec round(t, [{id, integer | nil}], (id -> node), node, Enumerable.t()) :: t
  def round(plan, entries, preferred, self, pinned) do
    ids =
      for {id, last_used} <- entries,
          is_integer(last_used),
          not MapSet.member?(plan.attempted, id),
          not Enum.member?(pinned, id),
          preferred.(id) != self,
          do: {last_used, id}

    queue = ids |> Enum.sort() |> Enum.map(&elem(&1, 1)) |> :queue.from_list()
    %{plan | queue: queue, tries: %{}, deferred: 0}
  end

  @spec pending(t) :: non_neg_integer
  def pending(plan), do: :queue.len(plan.queue)

  @doc """
  The next cell to move. `check` tells for a cell whether it moves now, `:stay` where it is or `:busy` (a call
  is in flight): a busy cell waits for the next step and is left for the next round after a few. A step looks
  at each cell of the queue once, up to a bound, so a queue of busy cells does not spin.
  """
  @spec next(t, (id -> verdict)) :: {{:move, id, node}, t} | {:none, t}
  def next(plan, check), do: next(plan, check, min(@examine, pending(plan)), [])

  defp next(plan, _check, 0, busy), do: {:none, requeue(plan, busy)}

  defp next(plan, check, left, busy) do
    case :queue.out(plan.queue) do
      {:empty, _} ->
        {:none, requeue(plan, busy)}

      {{:value, id}, queue} ->
        plan = %{plan | queue: queue}

        case check.(id) do
          {:move, target} ->
            {{:move, id, target}, requeue(%{plan | attempted: MapSet.put(plan.attempted, id)}, busy)}

          :stay ->
            next(%{plan | attempted: MapSet.put(plan.attempted, id)}, check, left - 1, busy)

          :busy ->
            next(plan, check, left - 1, [id | busy])
        end
    end
  end

  defp requeue(plan, busy) do
    Enum.reduce(Enum.reverse(busy), plan, fn id, plan ->
      tries = Map.get(plan.tries, id, 0) + 1

      if tries >= @busy_tries,
        do: %{plan | deferred: plan.deferred + 1, tries: Map.delete(plan.tries, id)},
        else: %{plan | queue: :queue.in(id, plan.queue), tries: Map.put(plan.tries, id, tries)}
    end)
  end
end
