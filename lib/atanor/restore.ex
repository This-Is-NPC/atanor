defmodule Atanor.Restore do
  @moduledoc false
  # Restored copies of cells in temporary files, for the migration rehearsal
  # (design §17.3) and the undo report (design §15.10). Only the public
  # Alambique API: `Ops.restore/5` writes a local file and never touches the
  # live cell.

  alias Alambique.{Ops, Replication}

  @doc """
  Restores `cell` from `location` at `target` (`:latest`, `{:txid, n}` or
  `{:timestamp, ms}`) into the file `path`. A cell with no history at the
  target leaves no file.
  """
  @spec to_file(Alambique.Location.t(), {module, term}, String.t(), Path.t(), Replication.target(), pos_integer) ::
          {:ok, Replication.Restore.result()} | {:error, term}
  def to_file(location, clock, cell, path, target, timeout_ms) do
    ctx =
      Replication.ctx(
        store: location.store,
        prefix: location.prefix,
        node: "atanor-restore-" <> Atom.to_string(node()),
        clock: clock,
        timeout_ms: timeout_ms
      )

    Ops.restore(ctx, cell, path, target)
  end

  @doc "Removes the entries of `root` not modified for `stale_ms`: leftovers of a killed node."
  @spec remove_abandoned(Path.t(), pos_integer) :: :ok
  def remove_abandoned(root, stale_ms) do
    cutoff = System.os_time(:second) - div(stale_ms, 1000)

    for entry <- File.ls!(root),
        path = Path.join(root, entry),
        {:ok, %{mtime: mtime}} <- [File.stat(path, time: :posix)],
        mtime < cutoff,
        do: File.rm_rf(path)

    :ok
  end

  @doc "Quotes an SQL identifier."
  @spec quote_identifier(String.t()) :: String.t()
  def quote_identifier(name), do: ~s("#{String.replace(name, ~s("), ~s(""))}")
end
