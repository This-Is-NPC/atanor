defmodule Atanor.Sweeps.Undo.Cell do
  @moduledoc false
  # One cell of an undo report (design §15.10): read the position the operation
  # recorded and the cell's head, restore the cell at that position and at
  # `:latest` into temporary files, and compare the two copies table by table.
  # The live cell is only read; the copies are removed before this returns.

  alias Alambique.Sqlite
  alias Atanor.{Cell, Restore}

  @has_table "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '_atanor_undo'"
  @position """
  SELECT u.before_txid, u.before_at_ms, j.state
  FROM _atanor_undo u LEFT JOIN _atanor_jobs j ON j.id = u.job_id
  WHERE u.operation_id = ? LIMIT 1
  """
  # Library tables are not the worker's; Atanor's own are reported apart.
  @tables ~S"""
  SELECT name FROM sqlite_master
  WHERE type = 'table' AND name NOT LIKE 'sqlite\_%' ESCAPE '\' AND name NOT LIKE '\_alambique\_%' ESCAPE '\'
  ORDER BY name
  """
  @schema ~S"""
  SELECT type, name, tbl_name, coalesce(sql, '') FROM sqlite_master
  WHERE name NOT LIKE 'sqlite\_%' ESCAPE '\' AND name NOT LIKE '\_alambique\_%' ESCAPE '\'
    AND name NOT LIKE '\_atanor\_%' ESCAPE '\' AND tbl_name NOT LIKE '\_atanor\_%' ESCAPE '\'
  ORDER BY type, name
  """

  @doc """
  The cell's report entry, or `:no_position` when the cell holds none for
  `operation_id`. `files` are the paths of the copies before and after.
  """
  @spec run(atom, map, Cell.address(), String.t(), {Path.t(), Path.t()}) :: map | :no_position
  def run(instance, config, {namespace, key} = address, operation_id, files) do
    id = namespace <> "." <> key

    with {:ok, position} <- position(instance, address, operation_id),
         {:ok, head} <- Cell.position(instance, address, timeout: config.sweeps.undo_timeout_ms) do
      compare(config, id, %{position | head: head}, files)
    else
      :none -> :no_position
      {:error, reason} -> entry(config, id, nil, %{"restorable" => false, "error" => error("position", reason)})
    end
  end

  defp position(instance, address, operation_id) do
    case Cell.query(instance, address, @has_table) do
      {:ok, %{rows: []}} ->
        :none

      {:ok, _} ->
        case Cell.query(instance, address, @position, [operation_id]) do
          {:ok, %{rows: [[txid, at_ms, state]]}} -> {:ok, %{txid: txid, at_ms: at_ms, job_state: state, head: nil}}
          {:ok, %{rows: []}} -> :none
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp compare(config, id, position, {before_path, latest_path}) do
    deadline = System.monotonic_time(:millisecond) + config.sweeps.undo_timeout_ms
    clock = Alambique.Feed.ctx(config.alambique).clock

    outcome =
      try do
        with {:ok, location} <- locate(config.alambique, id),
             {:ok, _} <- restore(location, clock, id, before_path, {:txid, position.txid}, "before", deadline),
             {:ok, latest} <- restore(location, clock, id, latest_path, :latest, "latest", deadline),
             :ok <- not_behind(latest, position),
             {:ok, before_state} <- describe(before_path, "before", deadline),
             {:ok, current_state} <- describe(latest_path, "latest", deadline) do
          {:ok, latest.txid, before_state, current_state}
        end
      after
        File.rm(before_path)
        File.rm(latest_path)
      end

    case outcome do
      {:ok, current_txid, before_state, current_state} ->
        fields = %{"restorable" => true, "error" => nil, "current_txid" => current_txid}
        entry(config, id, position, Map.merge(fields, diff(before_state, current_state)))

      {:error, error} ->
        entry(config, id, position, %{"restorable" => false, "error" => error})
    end
  end

  defp entry(config, id, position, fields) do
    base = %{
      "cell" => id,
      "before_txid" => position && position.txid,
      "before_at_ms" => position && position.at_ms,
      "head_txid" => position && position.head.txid,
      "job_state" => position && position.job_state,
      "frozen" => frozen(config, id)
    }

    Map.merge(base, fields)
  end

  # Alambique's frozen flag, read without waking the cell.
  defp frozen(config, id) do
    case Alambique.frozen?(config.alambique, id) do
      {:ok, frozen?} -> frozen?
      {:error, _} -> nil
    end
  end

  # -- restore -----------------------------------------------------------------

  # Cells are located by listing each location of the placement for the exact id.
  defp locate(alambique, id) do
    locations = Alambique.Feed.ctx(alambique).locations

    found =
      Enum.find_value(locations, fn location ->
        case Alambique.list_cells(alambique, location: location, prefix: id, limit: 1) do
          {:ok, %{cells: [^id | _]}} -> location
          _ -> nil
        end
      end)

    if found, do: {:ok, found}, else: {:error, error("locate", "cell is not in the schema index of any location")}
  end

  defp restore(location, clock, id, path, target, stage, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, error("timeout", :timeout)}
    else
      case Restore.to_file(location, clock, id, path, target, remaining) do
        {:ok, result} -> {:ok, result}
        {:error, :timeout} -> {:error, error("timeout", :timeout)}
        {:error, reason} -> {:error, error(stage, reason)}
      end
    end
  end

  # A store that lost the cell's history restores `:latest` as an empty database.
  defp not_behind(%{txid: txid}, %{txid: before}) when txid >= before, do: :ok

  defp not_behind(%{txid: txid}, %{txid: before}),
    do: {:error, error("latest", "the store holds the cell up to txid #{txid}, behind the recorded position #{before}")}

  # -- describe and compare ----------------------------------------------------------

  # `%{tables: %{name => {rows, hash}}, schema: hash}`. Position 0 restores an
  # empty database.
  defp describe(path, stage, deadline) do
    case Sqlite.open(path, readonly: true) do
      {:ok, conn} ->
        {:ok, watchdog} =
          :timer.apply_after(max(deadline - System.monotonic_time(:millisecond), 0), Sqlite, :interrupt, [conn])

        try do
          read(conn, stage)
        after
          :timer.cancel(watchdog)
          Sqlite.close(conn)
        end

      {:error, reason} ->
        {:error, error(stage, reason)}
    end
  end

  defp read(conn, stage) do
    with {:ok, %{rows: names}} <- Sqlite.run(conn, @tables, []),
         {:ok, tables} <- tables(conn, List.flatten(names)),
         {:ok, %{rows: objects}} <- Sqlite.run(conn, @schema, []) do
      {:ok, %{tables: tables, schema: schema_hash(objects)}}
    else
      {:error, "interrupted"} -> {:error, error("timeout", :timeout)}
      {:error, reason} -> {:error, error(stage, reason)}
    end
  end

  defp tables(conn, names) do
    Enum.reduce_while(names, {:ok, %{}}, fn name, {:ok, acc} ->
      case table(conn, name) do
        {:ok, summary} -> {:cont, {:ok, Map.put(acc, name, summary)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # Row count and a hash of the rows ordered by all their columns, streamed.
  defp table(conn, name) do
    quoted = Restore.quote_identifier(name)

    with {:ok, %{rows: columns}} <- Sqlite.run(conn, "PRAGMA table_info(#{quoted})", []),
         order = Enum.join(1..max(length(columns), 1), ", "),
         {:ok, stmt} <- Sqlite.prepare(conn, "SELECT * FROM #{quoted} ORDER BY #{order}") do
      try do
        digest(stmt, :crypto.hash_init(:sha256), 0)
      after
        Sqlite.release(stmt)
      end
    end
  end

  defp digest(stmt, hash, count) do
    case Sqlite.step(stmt) do
      {:row, row} -> digest(stmt, :crypto.hash_update(hash, :erlang.term_to_binary(row)), count + 1)
      :done -> {:ok, {count, Base.encode16(:crypto.hash_final(hash), case: :lower)}}
      {:error, _} = error -> error
    end
  end

  defp schema_hash(objects) do
    normalized = for [type, name, table, sql] <- objects, do: [type, name, table, String.split(sql)]
    :crypto.hash(:sha256, :erlang.term_to_binary(normalized)) |> Base.encode16(case: :lower)
  end

  defp diff(before_state, current_state) do
    names = Enum.sort(Enum.uniq(Map.keys(before_state.tables) ++ Map.keys(current_state.tables)))

    {host, worker} =
      names
      |> Enum.map(fn name ->
        {rows_before, hash_before} = Map.get(before_state.tables, name, {nil, nil})
        {rows_current, hash_current} = Map.get(current_state.tables, name, {nil, nil})

        %{"name" => name, "before" => rows_before, "current" => rows_current, "changed" => hash_before != hash_current}
      end)
      |> Enum.split_with(&String.starts_with?(&1["name"], "_atanor_"))

    %{"tables" => worker, "host_tables" => host, "schema_changed" => before_state.schema != current_state.schema}
  end

  defp error(stage, reason),
    do: %{"stage" => stage, "message" => if(is_binary(reason), do: reason, else: inspect(reason))}
end
