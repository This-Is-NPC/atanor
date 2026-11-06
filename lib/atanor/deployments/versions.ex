defmodule Atanor.Deployments.Versions do
  @moduledoc """
  The index of the packages uploaded for a worker (design §5.5). Packages are
  stored by hash, so the store has no list per worker; each deploy also writes
  two small objects:

    * `versions/<worker>/id/<package id>`: a guard that makes recording the same
      package again a no-op (its body is the key of the log entry);
    * `versions/<worker>/log/<unix microseconds>-<package id>`: the entry
      (`package_id`, `kind`, `size`, `uploaded_at`, `uploaded_by`), which lists
      oldest first.

  Entries are never changed or deleted.
  """

  alias Atanor.{Package, Store}

  @doc "Records an upload. Recording a package again keeps the first entry."
  @spec record(Store.t(), Package.t(), map) :: :ok | {:error, term}
  def record(store, %Package{} = package, uploaded_by) do
    worker = package.manifest.name
    guard = "versions/#{worker}/id/#{package.id}"
    us = System.os_time(:microsecond)
    key = "versions/#{worker}/log/" <> String.pad_leading(Integer.to_string(us), 16, "0") <> "-" <> package.id

    entry =
      Jason.encode!(%{
        package_id: package.id,
        kind: package.manifest.kind,
        size: byte_size(package.bytes),
        uploaded_at: us |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601(),
        uploaded_by: uploaded_by
      })

    case Store.put(store, guard, key, :if_none_match) do
      {:ok, _} -> put_entry(store, key, entry)
      # The guard exists: heal an entry a crash left out, with the first key.
      {:error, :precondition_failed} -> heal(store, guard, entry)
      {:error, _} = error -> error
    end
  end

  defp heal(store, guard, entry) do
    with {:ok, key, _, _} <- Store.get(store, guard), do: put_entry(store, key, entry)
  end

  defp put_entry(store, key, entry) do
    case Store.put(store, key, entry, :if_none_match) do
      {:ok, _} -> :ok
      {:error, :precondition_failed} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc "A page of the entries of `worker`, oldest first, after the cursor `after_id`."
  @spec list(Store.t(), String.t(), String.t() | nil, pos_integer) :: {:ok, [map], String.t() | nil} | {:error, term}
  def list(store, worker, after_id, limit) do
    prefix = "versions/#{worker}/log/"

    with {:ok, keys, next} <- Store.list(store, prefix, after_id && prefix <> after_id, limit) do
      entries =
        for key <- keys, {:ok, json, _, _} <- [Store.get(store, key)], {:ok, entry} <- [Jason.decode(json)] do
          Map.put(entry, "id", String.replace_prefix(key, prefix, ""))
        end

      {:ok, entries, next && String.replace_prefix(next, prefix, "")}
    end
  end
end
