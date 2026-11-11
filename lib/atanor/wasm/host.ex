defmodule Atanor.Wasm.Host do
  @moduledoc """
  Answers the calls a guest makes through its imports (design §4). Each
  call runs in the process that invoked the guest, with that request's env,
  so the grants are the ones of the pinned deployment.

  An outbound HTTP call ends within `timeout_ms`, the time the guest has left.
  Replies are `{:ok, value}` or `{:error, kind, message}` with `kind` one of
  `:not_granted`, `:missing` or `:failed`.
  """

  alias Alambique.Tx
  alias Atanor.{Env, Registry, Request}

  # Errors of Alambique's limits reach the guest as `failed("<code>: <text>")`; the codes are documented
  # in wit/cell/sql.wit (design §4.3).
  @limit_messages %{
    statement_timeout: "the statement ran longer than the cell's sql statement_timeout_ms",
    result_too_large: "the result is over the cell's sql max_result_rows or max_result_bytes",
    overloaded: "this node is at its awake limits; retry later",
    busy: "too many calls are waiting on this cell; retry later",
    batch_too_large: "the results of the batch are over the wasm max_batch_bytes; nothing was applied",
    message_too_large: "the message is over the wasm max_cell_message_bytes"
  }
  @limit_errors Map.keys(@limit_messages)

  @doc false
  @spec handle(Env.t(), atom, list, non_neg_integer) :: tuple
  def handle(env, op, args, timeout_ms) do
    if op == :http, do: http(env, args, timeout_ms), else: within(timeout_ms, fn -> run(env, op, args) end)
  rescue
    exception -> {:error, :failed, Exception.message(exception)}
  catch
    kind, reason -> {:error, :failed, Exception.format_banner(kind, reason)}
  end

  # A cell call waits for a leaving owner only while the guest has time left.
  defp within(timeout_ms, fun) do
    previous = Atanor.Cell.begin_handler(timeout_ms)

    try do
      fun.()
    after
      Atanor.Cell.end_handler(previous)
    end
  end

  defp run(env, op, [ns, key, sql, params]) when op in [:query, :execute] do
    fun = if op == :query, do: &Env.query/5, else: &Env.execute/5
    env |> fun.({ns, key}, sql, Enum.map(params, &param/1), []) |> rows()
  end

  defp run(env, :query_bounded, [ns, key, sql, params, max_lag_ms]) do
    env |> Env.query({ns, key}, sql, Enum.map(params, &param/1), consistency: {:bounded, max_lag_ms}) |> rows()
  end

  defp run(env, :partition, [ns, key, partition_key]) do
    case Env.partition(env, {ns, key}, partition_key) do
      {:ok, cell} -> {:ok, cell}
      error -> error(error)
    end
  end

  defp run(env, :batch, [ns, key, statements]) do
    cap = Registry.config(env.instance).wasm.max_batch_bytes

    result =
      Env.transaction(env, {ns, key}, fn tx ->
        statements
        |> Enum.map(&Tuple.to_list/1)
        |> Enum.reduce({[], 0}, fn [sql, params], acc ->
          with {:ok, result} <- Tx.execute(tx, sql, Enum.map(params, &param/1)),
               {:ok, acc} <- add_result(acc, result, cap) do
            acc
          else
            {:error, reason} -> Tx.rollback(tx, reason)
          end
        end)
        |> elem(0)
        |> Enum.reverse()
      end)

    case result do
      {:ok, results} -> {:ok, Enum.map(results, &wire_rows/1)}
      error -> error(error)
    end
  end

  defp run(env, :enqueue, [ns, key, kind, payload, scheduled, max, unique, period, idempotency]) do
    spec = %{
      kind: kind,
      payload: payload,
      scheduled_at_ms: scheduled,
      max_attempts: max,
      unique_key: unique,
      unique_period: period,
      idempotency_key: idempotency
    }

    env |> Env.enqueue({ns, key}, spec) |> job_id()
  end

  defp run(env, :enqueue_batch, [ns, key, statements, kind, payload, scheduled, max, unique, period, idempotency]) do
    spec = %{
      kind: kind,
      payload: payload,
      scheduled_at_ms: scheduled,
      max_attempts: max,
      unique_key: unique,
      unique_period: period,
      idempotency_key: idempotency
    }

    result =
      Env.transaction(env, {ns, key}, fn tx ->
        for [sql, params] <- Enum.map(statements, &Tuple.to_list/1) do
          case Tx.execute(tx, sql, Enum.map(params, &param/1)) do
            {:ok, _} -> :ok
            {:error, reason} -> Tx.rollback(tx, reason)
          end
        end

        Atanor.Jobs.enqueue(tx, env, {ns, key}, spec)
      end)

    case result do
      {:ok, result} -> job_id(result)
      error -> error(error)
    end
  end

  defp run(env, :set_alarm, [ns, key, at_ms, payload]), do: env |> Env.set_alarm({ns, key}, at_ms, payload) |> ok()
  defp run(env, :cancel_alarm, [ns, key]), do: env |> Env.cancel_alarm({ns, key}) |> ok()
  defp run(env, :attach, [ns, key]), do: env |> Env.attach({ns, key}) |> ok()

  defp run(env, :send_to_cell, [ns, key, message]) do
    if byte_size(message) > Registry.config(env.instance).wasm.max_cell_message_bytes,
      do: error({:error, :message_too_large}),
      else: env |> Env.send_to_cell({ns, key}, message) |> ok()
  end

  defp run(env, :join_channel, [ns, key, id]), do: env |> Env.join_channel({ns, key}, id: id) |> ok()
  defp run(env, :leave_channel, [ns, key]), do: env |> Env.leave_channel({ns, key}) |> ok()
  defp run(env, :publish, [ns, key, frame]), do: env |> Env.publish({ns, key}, frame) |> ok()

  defp run(env, :channel_members, [ns, key]) do
    case Env.channel_members(env, {ns, key}) do
      {:ok, %{count: count, ids: ids}} -> {:ok, {count, ids}}
      other -> error(other)
    end
  end

  defp run(env, :secret, [name]) do
    case Env.secret(env, name) do
      {:ok, value} -> {:ok, value}
      {:error, {:missing_secret, name}} -> {:error, :missing, name}
      other -> error(other)
    end
  end

  defp run(env, :call, [worker, method, path, query, headers, body]) do
    request = %Request{
      method: method,
      host: worker,
      path: path,
      query: query,
      headers: lowercase(headers),
      body: body
    }

    env |> Env.call(worker, request) |> response()
  end

  defp http(env, [method, scheme, host, port, path, query, headers, body], timeout_ms) do
    request = %Request{
      method: method,
      scheme: scheme,
      host: host,
      port: if(port == 0, do: default_port(scheme), else: port),
      path: path,
      query: query,
      headers: lowercase(headers),
      body: body
    }

    env |> Env.fetch(request, timeout_ms: timeout_ms) |> response()
  end

  defp default_port("http"), do: 80
  defp default_port(_), do: 443

  @doc false
  # Adds a statement's result to the batch `{results, bytes}` (newest first), or `{:error, :batch_too_large}`
  # as soon as the sum passes `cap`. It walks the rows and copies nothing.
  @spec add_result({list, non_neg_integer}, map, pos_integer) ::
          {:ok, {list, non_neg_integer}} | {:error, :batch_too_large}
  def add_result({results, bytes}, result, cap) do
    bytes = bytes + result_bytes(result)
    if bytes > cap, do: {:error, :batch_too_large}, else: {:ok, {[result | results], bytes}}
  end

  @doc false
  # Text and blobs count by length, any other value 8 bytes.
  @spec result_bytes(%{columns: [binary], rows: [list]}) :: non_neg_integer
  def result_bytes(%{columns: columns, rows: rows}) do
    Enum.reduce(columns, 0, &(byte_size(&1) + &2)) +
      Enum.reduce(rows, 0, fn row, acc -> Enum.reduce(row, acc, &(value_bytes(&1) + &2)) end)
  end

  defp value_bytes(value) when is_binary(value), do: byte_size(value)
  defp value_bytes({:blob, value}) when is_binary(value), do: byte_size(value)
  defp value_bytes(_), do: 8

  defp param({:blob, _} = blob), do: blob
  defp param(value), do: value

  defp lowercase(headers), do: for({name, value} <- headers, do: {String.downcase(name), value})

  defp job_id({:ok, id}) when is_binary(id), do: {:ok, id}
  defp job_id({:ok, {:duplicate, id}}), do: {:ok, id}
  defp job_id(other), do: error(other)

  defp ok(:ok), do: {:ok, nil}
  defp ok(other), do: error(other)

  defp rows({:ok, result}), do: {:ok, wire_rows(result)}
  defp rows(other), do: error(other)

  defp wire_rows(%{columns: columns, rows: rows}), do: {columns, rows}

  defp response({:ok, %{status: status, headers: headers, body: body}}), do: {:ok, {status, headers, to_binary(body)}}
  defp response(other), do: error(other)

  defp to_binary(body) when is_binary(body), do: body
  defp to_binary(body), do: IO.iodata_to_binary(body)

  @doc false
  # The guest's view of an error answer of a cell or worker function.
  def error({:error, {:not_granted, binding}}), do: {:error, :not_granted, describe(binding)}
  def error({:error, {:invalid_option, key}}), do: {:error, :failed, "invalid option: #{key}"}
  def error({:error, reason}) when is_binary(reason), do: {:error, :failed, reason}
  def error({:error, {:bad_params, message}}), do: {:error, :failed, "bad_params: #{message}"}

  def error({:error, reason}) when reason in @limit_errors,
    do: {:error, :failed, "#{reason}: #{Map.fetch!(@limit_messages, reason)}"}

  # The transaction was rolled back, so nothing was applied.
  def error({:error, {:store, _}}),
    do: {:error, :failed, "store_unavailable: the store did not answer; nothing was applied, retry later"}

  # The lease could not be read for a read or a lookup: nothing was applied.
  def error({:error, {:lease_unreadable, _}}),
    do: {:error, :failed, "store_unavailable: the store did not answer; nothing was applied, retry later"}

  # The cell stopped on a failed upload, which may have reached the store.
  def error({:error, {:sync_failed, _}}),
    do: {:error, :failed, "sync_failed: the commit could not be uploaded; the write may or may not be applied"}

  # A write whose batch was sent when the cell stopped, for any reason.
  def error({:error, :outcome_unknown}),
    do: {:error, :failed, "unknown_outcome: the write may or may not be applied; do not repeat it blindly"}

  def error({:error, reason}), do: {:error, :failed, inspect(reason)}

  defp describe({_kind, name}), do: to_string(name)
  defp describe(binding) when is_atom(binding), do: Atom.to_string(binding)
end
