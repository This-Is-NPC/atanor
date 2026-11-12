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
  def wake_budget(memory) do
    case limit(memory) do
      {nil, _source} ->
        nil

      {bytes, _source} ->
        headroom = bytes * (1 - (memory.refuse_fraction || @default_refuse_fraction))
        trunc(headroom * memory.wake_fraction)
    end
  end

  @doc """
  The wake limits for a budget (design §4.3): `prefetch_bytes` is a sixteenth of it (1 to 64 MiB),
  `fetch_concurrency` one request per 2 MiB of it (1 to 16), and `max_wakes` as many wakes of
  `prefetch_bytes + fetch_concurrency` MiB (a request holds about 1 MiB) as fit (1 to 256).
  The worst case, `max_wakes` times that, is within the budget from 2 MiB up.
  """
  @spec wake_limits(non_neg_integer) :: %{
          max_wakes: pos_integer,
          fetch_concurrency: pos_integer,
          prefetch_bytes: pos_integer
        }
  def wake_limits(budget) do
    prefetch = budget |> div(16) |> clamp(@mib, 64 * @mib)
    fetch = prefetch |> div(2 * @mib) |> clamp(1, 16)
    wakes = budget |> div(prefetch + fetch * @mib) |> clamp(1, 256)
    %{max_wakes: wakes, fetch_concurrency: fetch, prefetch_bytes: prefetch}
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
