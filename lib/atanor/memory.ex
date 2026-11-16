defmodule Atanor.Memory do
  @moduledoc false
  # The memory ceiling of the awake cells (Alambique `awake: [max_bytes:]`), derived from the node's memory
  # limit unless the operator sets it (design §4.3).

  @mib 1_048_576
  @default_refuse_fraction 0.85
  # The least the awake cells get, as a share of the limit, when the baseline leaves almost no headroom.
  @min_awake_fraction 0.1

  @doc """
  `{max_bytes, source}` for the awake cells. `explicit` is `awake: [max_bytes:]` when the operator gave it
  (a `nil` value there means no ceiling). The source is `:option`, `:limit_bytes`, `:cgroup` or `:none`.

  Derived, it is `awake_fraction` of the headroom between the working set at boot (`baseline`: the BEAM and the
  data directory before any cell is awake; `nil` when unreadable) and the refuse mark, so the cells hibernate
  before the node refuses. It is at least a tenth of the limit and at most `limit * awake_fraction`, which is
  all of it without a baseline (design §4.3).
  """
  @spec awake_max_bytes(map, {:ok, pos_integer | nil} | :error, non_neg_integer | nil) :: {pos_integer | nil, atom}
  def awake_max_bytes(memory, explicit, baseline \\ nil)
  def awake_max_bytes(_memory, {:ok, max_bytes}, _baseline), do: {max_bytes, :option}

  def awake_max_bytes(memory, :error, baseline) do
    case limit(memory) do
      {nil, _source} -> {nil, :none}
      {bytes, source} -> {derived_awake(memory, bytes, baseline), source}
    end
  end

  defp derived_awake(memory, limit, nil), do: max(1, trunc(limit * memory.awake_fraction))

  defp derived_awake(memory, limit, baseline) do
    mark = limit * (memory.refuse_fraction || @default_refuse_fraction)
    ceiling = limit * memory.awake_fraction

    (mark - baseline)
    |> Kernel.*(memory.awake_fraction)
    |> max(limit * @min_awake_fraction)
    |> min(ceiling)
    |> trunc()
    |> max(1)
  end

  @doc """
  `{:ok, bytes}`: the working set of the cgroup, its usage minus the file cache the kernel can drop (without
  `memory.stat` all usage counts); `:error` when `memory.current` cannot be read.
  """
  @spec working_set(map) :: {:ok, non_neg_integer} | :error
  def working_set(%{current_path: current_path, stat_path: stat_path}) do
    with {:ok, text} <- File.read(current_path),
         {current, _} <- Integer.parse(text) do
      {:ok, max(current - inactive_file(stat_path), 0)}
    else
      _ -> :error
    end
  end

  defp inactive_file(path) do
    with {:ok, text} <- File.read(path),
         [_, bytes] <- Regex.run(~r/^inactive_file (\d+)$/m, text) do
      String.to_integer(bytes)
    else
      _ -> 0
    end
  end

  @doc """
  The bytes that wakes in flight may hold: `wake_fraction` of the headroom between the refuse mark and the
  limit (`refuse_fraction` nil counts as the default 0.85). `nil` when the node has no limit.
  """
  @spec wake_budget(map) :: non_neg_integer | nil
  def wake_budget(memory), do: share(memory, memory.wake_fraction)

  @doc """
  The bytes that guests waiting for I/O may hold: the rest of that headroom, `1 - wake_fraction` of it.
  `nil` when the node has no limit.
  """
  @spec waiting_budget(map) :: non_neg_integer | nil
  def waiting_budget(memory), do: share(memory, 1 - memory.wake_fraction)

  defp share(memory, fraction) do
    case limit(memory) do
      {nil, _source} ->
        nil

      {bytes, _source} ->
        headroom = bytes * (1 - (memory.refuse_fraction || @default_refuse_fraction))
        trunc(headroom * fraction)
    end
  end

  @doc """
  How many guests that wait (or calls that queue for one) fit in `budget` when each holds `guest_bytes`
  (design §14.2): 1 to 256. Below the cost of one guest the minimum of one stays over the budget.
  """
  @spec waiting_limit(non_neg_integer, pos_integer) :: pos_integer
  def waiting_limit(budget, guest_bytes), do: budget |> div(guest_bytes) |> clamp(1, 256)

  # Alambique's `restore: [edge_bytes:]` and `[fetch_concurrency:]` defaults.
  @edge_bytes 65_536
  @fetch_concurrency 16

  @doc """
  The wake limits for a budget (design §4.3). One wake holds at most `max_inflight_bytes` of what it reads
  plus `(fetch_concurrency + 2) * edge_bytes` (Alambique design §6.3), so: `max_inflight_bytes` is a sixteenth
  of the budget (1 to 64 MiB), and `max_wakes` as many wakes of that cost as fit (1 to 256), with Alambique's
  default of 16 requests at once. The worst case, `max_wakes` times the cost, is within the budget
  once one wake's cost is. A file larger than `max_inflight_bytes` is read alone and costs its own size; the
  limits cannot know it. Wakes above `max_wakes` wait in Alambique's queue and hold nothing; a wake that fails
  on the store backs off before it starts again, so neither adds to the wakes in flight.
  """
  @spec wake_limits(non_neg_integer, pos_integer) :: %{
          max_wakes: pos_integer,
          max_inflight_bytes: pos_integer
        }
  def wake_limits(budget, edge_bytes \\ @edge_bytes) do
    inflight = budget |> div(16) |> clamp(@mib, 64 * @mib)
    wakes = budget |> div(inflight + (@fetch_concurrency + 2) * edge_bytes) |> clamp(1, 256)
    %{max_wakes: wakes, max_inflight_bytes: inflight}
  end

  defp clamp(value, low, high), do: value |> max(low) |> min(high)

  @doc "`{bytes | nil, source}`: the node's memory limit, `nil` when it has none."
  def limit(%{limit_bytes: bytes}) when is_integer(bytes), do: {bytes, :limit_bytes}
  def limit(%{cgroup_path: path}), do: {cgroup_limit(path), :cgroup}

  # cgroup v2: a byte count, or "max" for no limit. A missing or unreadable file is no limit either.
  defp cgroup_limit(path) do
    with {:ok, text} <- File.read(path),
         {bytes, ""} when bytes > 0 <- Integer.parse(String.trim(text)) do
      bytes
    else
      _ -> nil
    end
  end
end
