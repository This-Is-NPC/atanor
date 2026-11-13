defmodule Atanor.Memory do
  @moduledoc false
  # The memory ceiling of the awake cells (Alambique `awake: [max_bytes:]`), derived from the node's memory
  # limit unless the operator sets it (design §4.3).

  @doc """
  `{max_bytes, source}` for the awake cells. `explicit` is `awake: [max_bytes:]` when the operator gave it
  (a `nil` value there means no ceiling). The source is `:option`, `:limit_bytes`, `:cgroup` or `:none`.
  """
  @spec awake_max_bytes(map, {:ok, pos_integer | nil} | :error) :: {pos_integer | nil, atom}
  def awake_max_bytes(_memory, {:ok, max_bytes}), do: {max_bytes, :option}

  def awake_max_bytes(memory, :error) do
    case limit(memory) do
      {nil, _source} -> {nil, :none}
      {bytes, source} -> {max(1, trunc(bytes * memory.awake_fraction)), source}
    end
  end

  @mib 1_048_576
  @default_refuse_fraction 0.85

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

  # Alambique's `restore: [edge_bytes:]` default.
  @edge_bytes 65_536

  @doc """
  The wake limits for a budget (design §4.3). One wake holds at most `max_inflight_bytes` of what it reads
  plus `(fetch_concurrency + 2) * edge_bytes` (Alambique design §6.3), so: `max_inflight_bytes` is a sixteenth
  of the budget (1 to 64 MiB), `fetch_concurrency` one request per 2 MiB of it (1 to 16), and `max_wakes` as
  many wakes of that cost as fit (1 to 256). The worst case, `max_wakes` times the cost, is within the budget
  once one wake's cost is. A file larger than `max_inflight_bytes` is read alone and costs its own size; the
  limits cannot know it. Wakes above `max_wakes` wait in Alambique's queue and hold nothing; a wake that fails
  on the store backs off before it starts again, so neither adds to the wakes in flight.
  """
  @spec wake_limits(non_neg_integer, pos_integer) :: %{
          max_wakes: pos_integer,
          fetch_concurrency: pos_integer,
          max_inflight_bytes: pos_integer
        }
  def wake_limits(budget, edge_bytes \\ @edge_bytes) do
    inflight = budget |> div(16) |> clamp(@mib, 64 * @mib)
    fetch = inflight |> div(2 * @mib) |> clamp(1, 16)
    wakes = budget |> div(inflight + (fetch + 2) * edge_bytes) |> clamp(1, 256)
    %{max_wakes: wakes, fetch_concurrency: fetch, max_inflight_bytes: inflight}
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
