defmodule Atanor.Store do
  @moduledoc """
  Atanor's view of an `Alambique.Store` under `<prefix>/` (design §5). Keys
  passed in and returned are relative to the prefix.

  Every function takes the store as the name of a running instance, or as the
  handle from `open/2` for tools that run without a node.
  """

  alias Atanor.Registry

  @typedoc "A `{store_module, store_config, prefix_with_slash}` handle."
  @type handle :: {module, term, String.t()}
  @type t :: atom | handle

  @doc "A handle on the objects under `prefix` in `{module, config}`."
  @spec open({module, term}, String.t()) :: handle
  def open({mod, config}, prefix), do: {mod, config, prefix <> "/"}

  @doc "The handle of a running instance's metadata store."
  @spec handle(t) :: handle
  def handle({_, _, _} = handle), do: handle

  def handle(name) when is_atom(name) do
    config = Registry.config(name)
    open(config.meta_store, config.prefix)
  end

  @doc "Writes an object."
  def put(store, key, body, condition \\ :none, meta \\ %{}) do
    {mod, config, prefix} = handle(store)
    call(mod, :put, [config, prefix <> key, body, condition, meta])
  end

  @doc "Reads an object."
  def get(store, key) do
    {mod, config, prefix} = handle(store)
    call(mod, :get, [config, prefix <> key])
  end

  @doc "Reads an object's etag and metadata."
  def head(store, key) do
    {mod, config, prefix} = handle(store)
    call(mod, :head, [config, prefix <> key])
  end

  @doc """
  Lists keys under `prefix`, in order, after `start_after`. `limit` defaults to
  1000 for library callers; an instance's `metadata.page_size` is passed by
  `Atanor.Deployments`.
  """
  def list(store, key_prefix, start_after \\ nil, limit \\ 1000) do
    {mod, config, prefix} = handle(store)
    start = start_after && prefix <> start_after

    with {:ok, keys, next} <- call(mod, :list, [config, prefix <> key_prefix, start, limit]) do
      {:ok, Enum.map(keys, &String.replace_prefix(&1, prefix, "")), next && String.replace_prefix(next, prefix, "")}
    end
  end

  @doc "Deletes an object."
  def delete(store, key) do
    {mod, config, prefix} = handle(store)
    call(mod, :delete, [config, prefix <> key])
  end

  # Atanor calls the metadata store itself, outside Alambique's own wrapper
  # (which answers `{:store_crashed, ...}` for the cells). A store that raises
  # (an operator's custom store; `Alambique.Store.S3` no longer does) answers like
  # one that fails, so callers retry at their next poll instead of crashing.
  defp call(mod, function, args) do
    apply(mod, function, args)
  rescue
    exception -> {:error, {:store_exception, exception}}
  catch
    :exit, reason -> {:error, {:store_exit, reason}}
  end
end
