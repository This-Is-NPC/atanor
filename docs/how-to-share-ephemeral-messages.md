# How to share cursors, presence and signals between sockets without touching the cell

**The question:** How do I send messages that are never stored (cursors,
typing indicators, presence, signals) to every WebSocket that watches a cell,
on any node, without a callback on the cell's owner and without writing to the
cell?

This guide builds on [how-to-use-websockets.md](how-to-use-websockets.md); read
its first three steps first. It stands alone otherwise.

## What you get

A cell has an ephemeral **channel**. Sockets join it; a message published to it
reaches every socket in it, on every node, as a frame. Nothing is written to the
cell, no transaction runs, and the cell's owner is not called. A message is not
kept: a socket that is not in the channel at that moment misses it.

Use `Env.send_to_cell/3` instead when the receiving socket must run worker code
with access to the cell (it runs `handle_ws/3` on the owner once per socket).

## Prerequisites

- A worker with `handle_ws/3` and `"sockets": true`, and the cell's namespace
  under `bindings.cells` (see the WebSockets guide).
- `websocat` to try it (any WebSocket client works).

## Steps

1. Join the channel from `handle_ws/3`, in the callback that handles the
   client's "join" message. `id:` is optional and names the member for
   presence.

   ```elixir
   def handle_ws({:text, "join " <> room}, state, env) do
     :ok = Atanor.Env.join_channel(env, {"rooms", room}, id: state.user)
     {:ok, state}
   end
   ```

   Joining twice counts once. A socket leaves with
   `Atanor.Env.leave_channel(env, {"rooms", room})` or when it closes.

2. Publish from anywhere: any callback of any node, or any process that has an
   env. A published message is a frame, `{:text, data}` or `{:binary, data}`.

   ```elixir
   :ok = Atanor.Env.publish(env, {"rooms", "room-1"}, {:text, ~s({"typing":"ada"})})
   ```

   Every socket in the channel gets the frame as it is. The worker's
   `handle_ws/3` does not run for it.

3. Let clients publish cursor frames without a callback on the owner. Implement
   `handle_ws_local/3`. It sees each frame a client sends first, on the node
   that holds the socket, and says whether the frame ends there (`:drop`) or
   goes on to `handle_ws/3` on the owner (`:pass`).

   ```elixir
   @impl true
   def handle_ws_local({:text, "cursor " <> position}, state, env) do
     # Validate and shape it: the client cannot choose who it is.
     frame = {:text, Jason.encode!(%{user: state.user, cursor: position})}
     Atanor.Env.publish(env, {"rooms", state.room}, frame)
     :drop
   end

   def handle_ws_local(_frame, _state, _env), do: :pass
   ```

   `state` is what `handle_ws/3` last returned, read-only; put the user and the
   room there when the socket joins. The callback has no access to cells: any
   cell function returns `{:error, {:not_granted, {:cell, namespace}}}`. It runs
   in the socket's process, so keep it short.

4. Ask who is in the channel. This is presence, read from the nodes when you
   ask (it is not stored):

   ```elixir
   {:ok, %{count: 3, ids: ["ada", "bob"]}} =
     Atanor.Env.channel_members(env, {"rooms", "room-1"})
   ```

   `count` includes the members that joined without an `id:`. For a presence
   list that updates itself, publish a "joined" or "left" message when a socket
   joins or leaves.

5. Try it. Two terminals, after the worker joined both sockets to `room-1`:

   ```sh
   websocat ws://localhost:4123/room/room-1     # type: cursor 10,20
   ```

   The other terminal prints `{"user":"ada","cursor":"10,20"}`.

## WASM workers

Import `atanor:cell/sockets@0.1.0` (set `"sockets": true`, grant the
namespace). The interface has four more functions:

| Function | Does |
| --- | --- |
| `join-channel(namespace, key, id: option<string>)` | Joins the socket being served. Not available in `on-open`. |
| `leave-channel(namespace, key)` | Leaves; succeeds when not in it. |
| `publish(namespace, key, message)` | `message` is `text(string)` or `binary(list<u8>)`. Also works in `on-frame`. |
| `channel-members(namespace, key)` | `{count: u32, ids: list<string>}`. |

To handle client frames without a call on the owner, also export
`atanor:worker/socket-local@0.1.0`: `on-frame(socket, frame)` returns `pass` or
`drop`. It runs in a fresh instance on the socket's node for every text or
binary frame, before `on-message`, so a guest that exports it pays one more
instantiation per frame. The call has no access to cells (`not-granted`), and
`socket` is the connection's id, which the guest can use to stamp what it
publishes. The Rust test guest
[channel.rs](../test/fixtures/guests/src/channel.rs) is a complete example.

## Limits

Operator option `channels:`, all positive integers:

| Key | Default | Meaning |
| --- | --- | --- |
| `max_message_bytes` | 16 384 | The largest message `publish` accepts. Over it: `{:error, :too_large}` (WASM: `failed(":too_large")`). |
| `max_subscriptions` | 16 | Channels one socket can be in. Over it: `{:error, :too_many_subscriptions}`. |
| `max_channels` | 10 000 | Channels with a member on one node. Over it: `{:error, :too_many_channels}`. |
| `max_channels_per_namespace` | 2 000 | Channels with a member on one node in one namespace, so one worker cannot use up the node's channels. Over it: `{:error, :too_many_channels}`. |
| `max_queue` | 1 000 | Messages waiting in one socket's mailbox. A socket over it misses the next messages until it catches up (a client that reads too slowly); `[:atanor, :channel, :dropped]` counts them. |

A WebSocket frame is also bound by `websocket.max_frame_bytes`, and a socket by
`websocket.max_frames_per_s` (100) with a burst of `websocket.frame_burst`
(200), which also bounds how fast one socket can publish. A remote join, leave
or presence query is bounded by `sockets.attach_timeout_ms`; a node that does not
answer gives `{:error, :node_unreachable}`.

## What is guaranteed

- A message reaches every socket that was in the channel when it was published
  and stays in it, once, on any node.
- The messages of one publisher (one process: a socket, or one worker call)
  reach each socket in the order they were published. Messages of different
  publishers have no common order.
- Delivery is at most once, and a socket that reads too slowly (over `max_queue`
  messages waiting) is skipped. A message to a socket whose node is unreachable is
  lost; the socket may be gone as well. Nothing is retried or stored.
- A publication is one distribution message for each node that has members,
  however many sockets they have there, and then one message for each local
  socket.

## Troubleshooting

- **`{:error, {:not_granted, :sockets}}`** Add `"sockets": true` to the
  manifest's `bindings`.
- **`{:error, {:not_granted, {:cell, "rooms"}}}`** Grant the namespace under
  `bindings.cells`. Inside `handle_ws_local/3` this is the answer to every cell
  function; only `publish` and `channel_members` work there.
- **`{:error, :not_a_socket}`** `join_channel` works only inside WebSocket
  callbacks; `ws_init` runs before the socket exists, so join in the first
  message.
- **A client's frames still reach the owner** The worker has no
  `handle_ws_local/3` (or the guest does not export `socket-local`), or it
  returned `:pass`.
- **Nothing arrives** The socket joined a different `{namespace, key}`, or
  joined after the message was published.

## Next steps

- [telemetry.md](telemetry.md#ephemeral-channel-events) for the events.
- [design.md](design.md#76-ephemeral-channels) for the model and the choices.
