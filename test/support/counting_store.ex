defmodule Atanor.Test.CountingStore do
  @moduledoc "A store that counts the reads of the keys that contain a fragment, and passes every call to another store."
  @behaviour Alambique.Store

  @doc "Wraps `{module, config}`; `reads/1` counts the `get` calls of keys with `fragment`."
  def wrap({module, config}, fragment), do: {__MODULE__, {module, config, fragment, :counters.new(1, [])}}

  def reads({__MODULE__, {_, _, _, counter}}), do: :counters.get(counter, 1)

  @impl true
  def put({m, c, _, _}, key, body, condition, meta), do: m.put(c, key, body, condition, meta)

  @impl true
  def get({m, c, fragment, counter}, key) do
    if String.contains?(key, fragment), do: :counters.add(counter, 1, 1)
    m.get(c, key)
  end

  @impl true
  def head({m, c, _, _}, key), do: m.head(c, key)

  @impl true
  def get_range({m, c, _, _}, key, offset, length), do: m.get_range(c, key, offset, length)

  @impl true
  def list({m, c, _, _}, prefix, start_after, limit), do: m.list(c, prefix, start_after, limit)

  @impl true
  def delete({m, c, _, _}, key), do: m.delete(c, key)
end
