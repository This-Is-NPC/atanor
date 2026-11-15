defmodule Atanor.Test.FlakyDeleteStore do
  @moduledoc "A store that refuses the first deletes of keys that contain a fragment with `{:error, :busy}`, and passes every other call to another store."
  @behaviour Alambique.Store

  @doc "Wraps `{module, config}`; the first `failures` deletes of keys with `fragment` fail."
  def wrap({module, config}, fragment, failures),
    do: {__MODULE__, {module, config, fragment, :counters.new(1, []), failures}}

  @impl true
  def delete({m, c, fragment, counter, failures}, key) do
    if String.contains?(key, fragment) and :counters.get(counter, 1) < failures do
      :counters.add(counter, 1, 1)
      {:error, :busy}
    else
      m.delete(c, key)
    end
  end

  @impl true
  def put({m, c, _, _, _}, key, body, condition, meta), do: m.put(c, key, body, condition, meta)

  @impl true
  def get({m, c, _, _, _}, key), do: m.get(c, key)

  @impl true
  def head({m, c, _, _, _}, key), do: m.head(c, key)

  @impl true
  def get_range({m, c, _, _, _}, key, offset, length), do: m.get_range(c, key, offset, length)

  @impl true
  def list({m, c, _, _, _}, prefix, start_after, limit), do: m.list(c, prefix, start_after, limit)
end
