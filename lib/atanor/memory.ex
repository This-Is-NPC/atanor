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
