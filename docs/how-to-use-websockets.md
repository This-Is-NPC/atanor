# How to serve WebSockets and push to a cell's sockets

**The question:** How do I accept WebSocket connections in a native or WASM
worker, and send a message to every socket attached to a cell, on any node?

This guide stands alone. It builds on the worker of
[how-to-write-a-native-worker.md](how-to-write-a-native-worker.md) and uses
[examples/hello-native](../examples/hello-native), whose worker answers WebSocket
text frames.

## Prerequisites

- The tools of the [README](../README.md#requirements).
- `websocat` to try it from a terminal (any WebSocket client works).

## Steps

1. Implement `handle_ws/3`. Every request with `Upgrade: websocket` on the
   worker's route is upgraded; other requests keep going to `handle_request/2`.

   ```elixir
   @impl true
   def handle_ws({:text, text}, state, env) do
     {:ok, n} = greet(env, String.trim(text))
     {:reply, [{:text, "hello #{text}, greeting #{n}"}], state}
   end
   ```

   It receives `{:text, data}`, `{:binary, data}` and `{:cell_message, term}`
   and returns `{:ok, state}`, `{:reply, frames, state}` or `{:stop, state}`.
   To accept or refuse an upgrade, implement `ws_init(request, env)`: return
   `{:ok, state}` or `{:reject, %Atanor.Response{}}`.

2. Start the node and talk to it.

   ```sh
   cd examples/hello-native
   mise exec -- mix atanor.dev --port 4123
   printf 'ada\nbob\nada\n' | websocat -t ws://localhost:4123/hello
   ```

   ```text
   hello ada, greeting 1
   hello bob, greeting 1
   hello ada, greeting 2
   ```

3. To reach sockets from elsewhere, grant `"sockets": true` and a cell
   namespace, then attach the socket to a cell and send to it.

   ```elixir
   # In handle_ws/3 for the frame "join room-1":
   :ok = Atanor.Env.attach(env, {"rooms", "room-1"})
   # In any callback of any node, including handle_request/2:
   :ok = Atanor.Env.send_to_cell(env, {"rooms", "room-1"}, "hi")
   ```

   Every attached socket gets `handle_ws({:cell_message, "hi"}, state, env)`,
   which runs on the cell's owner. Attaching twice counts once, and a socket
   leaves when it closes. Delivery is a plain message: a socket that is not
   attached at that moment misses it. For messages that need no worker code
   (cursors, presence), use an ephemeral channel instead.

## WASM workers

A WASM worker accepts WebSockets by exporting
`atanor:worker/socket-handler@0.1.0`. The node terminates the WebSocket and
calls `on-open(socket, request)`, `on-message(socket, message)` and
`on-close(socket)`, each in a fresh instance under the worker's `limits`, so
the guest keeps state in cells; `socket` is an id, unique to the connection,
that it can store there.

- `on-open` returns `accept` or `reject(response)`. It runs before the socket
  exists, so `attach` is not available in it.
- `on-message` gets `text`, `binary` or `cell` and returns the frames to send
  and whether to close afterwards. An error, a trap or a limit closes the
  socket with 1011.
- With `"sockets": true` and a granted namespace, the guest imports
  `atanor:cell/sockets@0.1.0`: `attach(namespace, key)` in `on-message`, and
  `send-to-cell(namespace, key, message)` anywhere. Cell messages reach the
  guest as `incoming.cell` bytes, and sockets of native and WASM workers
  attached to one cell receive the same messages. A native worker that sends
  something other than a binary reaches native sockets only.

A manifest with `"sockets": true` whose component lacks the export is refused
with `{:missing_export, "atanor:worker/socket-handler@0.1.0"}`. A Rust example
is in
[how-to-write-a-wasm-worker.md](how-to-write-a-wasm-worker.md#run-code-at-a-later-time-and-serve-websockets).

## Phoenix and LiveView

A plug worker (`plug/1`) upgrades inside its Plug with
`WebSockAdapter.upgrade/4`, as Phoenix does; the ingress passes the upgraded
connection through. `ws_init`, the frame limit and `attach` apply to
callback workers only.

## Limits

Operator options, all positive integers:

| Option | Default | Meaning |
| --- | --- | --- |
| `websocket.idle_timeout_ms` | 60 000 | Close a socket that sends nothing for this long. |
| `websocket.max_frame_bytes` | 1 000 000 | A frame over it, or a message spread over several frames whose total is over it, closes the socket with 1009. |
| `websocket.max_frames_per_s` | 100 | Frames one socket may send per second. |
| `websocket.frame_burst` | 200 | Frames a socket may send at once before the rate applies. A socket over the rate is closed with 1008. |
| `sockets.max_attachments` | 16 | Cells one socket can be attached to. Over it: `{:error, :too_many_attachments}`. |

A socket on a route with an `:auth` rule is closed with 1008 when the `exp` of
its token passes, even if frames keep arriving; the client connects again with
a fresh token. This holds for callback workers; a plug worker upgrades inside
its Plug and keeps its own rules.

## Troubleshooting

- **`{:error, {:not_granted, :sockets}}`** Add `"sockets": true` to the
  manifest's `bindings`.
- **`{:error, {:not_granted, {:cell, "rooms"}}}`** Grant the namespace under
  `bindings.cells`.
- **`{:error, :not_a_socket}`** `attach` works only inside WebSocket
  callbacks, where the env carries the socket.
- **The upgrade answers 404** The worker has no `handle_ws/3`, or no
  `handle_request/2` for plain requests.
- **The socket closes with code 1011** A callback raised or returned another
  shape, or a WASM handler failed or hit a limit; the node log has the
  details.

## Next steps

- [how-to-share-ephemeral-messages.md](how-to-share-ephemeral-messages.md) to
  send cursors and presence to the sockets of a cell without a callback on its
  owner.
- [how-to-use-alarms.md](how-to-use-alarms.md) to wake a cell later.
- [design.md](design.md#73-tcp-and-websockets): attached sockets across nodes.
