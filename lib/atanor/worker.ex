defmodule Atanor.Worker do
  @moduledoc """
  Behaviour of native workers (design §3.1). A worker implements the
  callbacks of the traffic it serves; all are optional, but a worker needs at
  least one of `plug/1`, `handle_request/2`, `handle_ws/3`, `handle_tcp/3`,
  `ranch_protocol/1`, `handle_alarm/3` or `handle_job/2`. The manifest must
  agree: a `tcp` route of the default protocol needs `handle_tcp/3`, a
  `"protocol": "ranch"` route needs `ranch_protocol/1`, and `"alarms": true`
  needs `handle_alarm/3`.

  The module must be compiled into the node, and named by the manifest's
  `module`.

  Every callback runs through `Atanor.Dispatch`. Arguments and results are
  plain data, and a callback that raises, exits or returns another shape is
  logged and its request, connection or alarm fails.

  ## HTTP

  `plug/1` serves HTTP on the ingress node when present; `handle_request/2`
  serves the rest and `Atanor.Env.call/3`.

  ## Routing keys

  `route_key/2` binds work to a cell (design §7.2). It is consulted with an
  `Atanor.Request` for `handle_request/2`, and with `{:tcp, state}` for TCP
  connections (see below). The namespace it returns must be granted by the
  manifest. For a partitioned namespace (design §4.2) return the four-element
  form `{:cell, namespace, key, partition_key}`: the request runs on the owner
  of the partition cell that holds `partition_key`.

  A request that only reads can end the key with options,
  `{:cell, namespace, key, consistency: {:bounded, ms}}` (after the partition
  key for a partitioned namespace). It then runs on the node that received it
  instead of the owner, reads with that bound by default, and cannot write:
  `Atanor.Env.execute/5` and the other writes return `{:error, :read_only}`
  (design §19.3). `consistency: :strong` is the default.

  ## TCP

  A manifest route `{"tcp": {"listener": "smtp"}}` sends the connections the
  operator's `smtp` listener accepts to the worker. Atanor passes bytes as
  they arrive, with no framing, so the worker splits lines or frames itself
  and keeps its own buffer in `state`.

  After each `handle_tcp/3` that continues or replies, and while the
  connection is unbound, Atanor asks `route_key({:tcp, state}, env)`. Once it
  returns a cell the connection is bound to it for good: later callbacks run
  for that cell, and the key is not asked again. The callback that returned
  the state runs unbound, so a worker that needs the cell for a command
  (`RCPT TO`, `LOGIN`) records the argument in `state`, replies, and gets the
  cell from the next chunk on.

  A connection keeps the deployment it started on until it closes.

  ## STARTTLS

  On a listener with `tls_mode: :starttls`, a worker upgrades the connection by
  returning `{:starttls, iodata, state}` from `handle_tcp/3`: Atanor sends the
  bytes (for example `"220 Ready to start TLS\r\n"`), runs the TLS handshake
  with the listener's current options and continues with the same worker
  state over the encrypted socket. The handshake either succeeds or the
  connection closes; there is no callback for the upgrade itself. Do not
  return it on a plain or implicit-TLS listener; that closes the connection.

  ## Ranch protocol listeners

  A manifest route `{"tcp": {"listener": "smtp", "protocol": "ranch"}}` on a
  listener configured with `protocol: :ranch` runs the worker's own Ranch
  protocol (for example gen_smtp) instead of the `handle_tcp/3` callbacks.
  `ranch_protocol/1` receives the `Atanor.Env` of the connection, resolved at
  accept, and returns `{module, opts}`. Atanor adds the env and the listener's
  current TLS options to `opts`; see `Atanor.TCP.Ranch`.

  ## WebSockets

  A request that asks to upgrade to a WebSocket on a route of a worker that
  implements `handle_ws/3` is accepted if `ws_init/2` accepts it. Frames and
  cell messages (`Atanor.Env.attach/2`, `Atanor.Env.send_to_cell/3`) reach
  `handle_ws/3`, on the cell's owner.

  Ephemeral channels (`Atanor.Env.join_channel/3`, `Atanor.Env.publish/3`)
  carry messages between sockets without a callback on the owner. A worker
  that wants a client's frames to reach a channel implements
  `handle_ws_local/3`, which sees each frame first, on the socket's node.

  ## Alarms

  `handle_alarm/3` runs when an alarm set with `Atanor.Env.set_alarm/4` is
  due (design §7.4). It is called at least once; make it idempotent.
  """

  alias Atanor.{Cell, Env, Request, Response}

  @type bytes :: iodata
  @type frame :: {:text | :binary, binary}

  @doc "Handles one request. Plain data in and out, so it can run on another node."
  @callback handle_request(Request.t(), Env.t()) :: Response.t()

  @doc """
  A Plug that serves the worker's HTTP requests on the ingress node, for
  Phoenix and LiveView. The env is in `conn.private[:atanor]`. The request
  body is not read or limited by Atanor. A WebSocket upgrade made by the plug
  (`WebSockAdapter.upgrade/4`) passes through the ingress.
  """
  @callback plug(Env.t()) :: {module, term}

  @doc """
  The cell that should serve `input`, a request or `{:tcp, state}` (design
  §7.2).
  """
  @callback route_key(input :: Request.t() | {:tcp, term}, Env.t()) ::
              {:cell, namespace :: String.t(), key :: String.t()}
              | {:cell, namespace :: String.t(), key :: String.t(), partition_key :: binary}
              | {:cell, namespace :: String.t(), key :: String.t(), opts :: [consistency: Env.consistency()]}
              | {:cell, namespace :: String.t(), key :: String.t(), partition_key :: binary,
                 opts :: [consistency: Env.consistency()]}
              | :none

  @doc """
  A TCP connection was accepted. `info` is `%{listener: name, peer: {ip,
  port}}`. Without this callback the initial state is `nil`. `{:close,
  bytes}` sends the bytes and closes.
  """
  @callback tcp_init(info :: map, Env.t()) :: {:ok, state :: term} | {:reply, bytes, state :: term} | {:close, bytes}

  @doc """
  Bytes arrived on a TCP connection. `{:close, bytes}` sends the bytes and
  closes. `{:starttls, bytes, state}` sends the bytes, upgrades the connection
  to TLS (only on a `tls_mode: :starttls` listener) and continues with
  `state` over TLS.
  """
  @callback handle_tcp(data :: binary, state :: term, Env.t()) ::
              {:continue, state :: term}
              | {:reply, bytes, state :: term}
              | {:starttls, bytes, state :: term}
              | {:close, bytes}

  @doc """
  For a `"protocol": "ranch"` route: the Ranch protocol that serves the
  connection, `{module, opts}`. `env` is the deployment resolved at accept.
  Atanor adds `:atanor_env`, `:atanor_tls_options`, `:tls_options` and, for
  the gen_smtp `{callback, opts}` form, `:atanor_env` in `:callbackoptions`.
  """
  @callback ranch_protocol(Env.t()) :: {module, term}

  @doc """
  A WebSocket upgrade request arrived. `{:reject, response}` answers the
  request without upgrading. Without this callback every upgrade is accepted
  with the state `nil`.
  """
  @callback ws_init(Request.t(), Env.t()) :: {:ok, state :: term} | {:reject, Response.t()}

  @doc """
  A frame or a message sent to a cell the socket is attached to arrived.
  `{:reply, frames, state}` pushes frames to the client, `{:stop, state}`
  closes the socket.
  """
  @callback handle_ws({:text | :binary, binary} | {:cell_message, term}, state :: term, Env.t()) ::
              {:ok, state :: term} | {:reply, [frame], state :: term} | {:stop, state :: term}

  @doc """
  A frame arrived on a socket: decides on the socket's own node whether it goes
  to `handle_ws/3` on the owner (`:pass`) or ends here (`:drop`). `state` is the
  one `handle_ws/3` last returned, read-only. The callback validates and shapes
  the frame and publishes with `Atanor.Env.publish/3`; the env cannot reach
  cells. Keep it short: it runs in the socket's process. Without this callback
  every frame passes.
  """
  @callback handle_ws_local({:text | :binary, binary}, state :: term, Env.t()) :: :pass | :drop

  @doc """
  An alarm of `cell` is due. `{:error, reason}` or a raise schedules a retry.
  """
  @callback handle_alarm(Cell.address(), payload :: binary, Env.t()) :: :ok | {:error, term}

  @doc """
  Runs one job of `cell` (design §15). The job is at least once: retries and
  takeovers reuse the job id and its idempotency key. `{:error, reason}` or a
  raise schedules a retry.
  """
  @callback handle_job(Atanor.Jobs.Job.t(), Env.t()) :: :ok | {:error, term}

  @optional_callbacks handle_request: 2,
                      plug: 1,
                      route_key: 2,
                      tcp_init: 2,
                      handle_tcp: 3,
                      ranch_protocol: 1,
                      ws_init: 2,
                      handle_ws: 3,
                      handle_ws_local: 3,
                      handle_alarm: 3,
                      handle_job: 2
end
