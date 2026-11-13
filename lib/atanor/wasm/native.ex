defmodule Atanor.Wasm.Native do
  @moduledoc """
  The Rust NIF (design §14). Internal: use `Atanor.Wasm`.

  `prepare/2` runs on a dirty CPU scheduler. `compile/5` and `invoke/5` only
  queue the work: guests run on threads of the crate's own pool and never
  occupy a BEAM scheduler. Results and host calls arrive as messages to the
  pid given to `invoke/5`:

    * `{:atanor_wasm, tag, :done, result, stderr, timing}`
    * `{:atanor_wasm, tag, :host, id, op, args}`, answered with `host_reply/2`
  """

  use Rustler, otp_app: :atanor, crate: "atanor_wasm", path: "native/atanor_wasm", mode: :release

  @doc "Starts the engine, the pool and the epoch ticker once per VM."
  @spec configure(map) :: :ok | {:error, String.t()}
  def configure(_settings), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Starts the compile pool once per VM (`:threads` and `:queue`)."
  @spec configure_compile(map) :: :ok | {:error, String.t()}
  def configure_compile(_settings), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Queues the compile of `bytes`, or the load of the compiled code cached under
  `key` in `dir`, on the crate's compile pool; `:overloaded` when its queue is
  full. The result arrives at `pid` as `{:atanor_compile, tag, result}`, where
  `result` is `{:ok, {reference, :compiled | :disk | :recompiled}}` or
  `{:error, message}`.
  """
  @spec compile(binary, String.t() | nil, String.t() | nil, pid, String.t()) :: :ok | :overloaded
  def compile(_bytes, _dir, _key, _pid, _tag), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Links the granted imports of a compiled component; tells whether it exports
  the socket handler and the local socket handler.
  """
  @spec prepare(reference, map) :: {:ok, {reference, boolean, boolean}} | {:error, {atom, String.t()}}
  def prepare(_compiled, _grants), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Queues a call and returns `{:ok, ticket}`, or `:overloaded` when it is refused (the queue is full, or the
  worker has `:worker_calls` calls). The call is
  `{:http, method, scheme, authority, path_query, headers, body}`,
  `{:alarm, namespace, key, payload}`, `{:ws_open, socket, method, path, query,
  headers}`, `{:ws_message, socket, :text | :binary | :cell, data}`,
  `{:ws_local, socket, :text | :binary, data}` or `{:ws_close, socket}`.
  """
  @spec invoke(reference, tuple, map, pid, non_neg_integer) :: {:ok, reference} | :overloaded
  def invoke(_prepared, _request, _limits, _pid, _tag), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Takes back a call that no thread has started: `true`, and it never runs and sends no result. `false` when
  it started or ended, and its result still arrives.
  """
  @spec withdraw(reference) :: boolean
  def withdraw(_ticket), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Answers a host call. A reply of `:host_reply_dirty_bytes` or more is copied
  on a dirty scheduler, a smaller one on a normal scheduler.
  """
  @spec host_reply(non_neg_integer, term) :: :ok
  def host_reply(id, reply) do
    case reply_entry(reply, Atanor.Wasm.settings().host_reply_dirty_bytes) do
      :small -> host_reply_small(id, reply)
      :large -> host_reply_large(id, reply)
    end
  end

  @doc false
  @spec reply_entry(term, pos_integer) :: :small | :large
  def reply_entry(reply, threshold), do: if(size(reply) >= threshold, do: :large, else: :small)

  # A binary's size is free; other terms cost a walk of the term, not of its binaries.
  defp size(reply) when is_binary(reply), do: byte_size(reply)
  defp size(reply), do: :erlang.external_size(reply)

  @doc false
  def host_reply_small(_id, _reply), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def host_reply_large(_id, _reply), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Counters and gauges of the native library."
  @spec stats() :: %{atom => integer}
  def stats, do: :erlang.nif_error(:nif_not_loaded)
end
