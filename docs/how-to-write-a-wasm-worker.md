# How to write a WASM worker

**The question:** How do I write a worker as a WebAssembly component, give it
a cell, and run it on a local node?

This guide stands alone. It uses [examples/hello-wasm](../examples/hello-wasm).
For the native kind, see [how-to-write-a-native-worker.md](how-to-write-a-native-worker.md);
deploying works the same way ([how-to-deploy-a-worker.md](how-to-deploy-a-worker.md)).

A WASM worker is a component that exports `wasi:http/incoming-handler`. It
can be written in any language whose toolchain produces such a component. I
tested only Rust (`wasm32-wasip2` target, with the `wasi` crate 0.14 and
`wit-bindgen` 0.51). Other languages that produce `wasi:http` components
(for example JavaScript with `jco`, Go with TinyGo, or Python with
`componentize-py`) should work, but I did not run them.

## Prerequisites

- The tools of the [README](../README.md#requirements).
- Rust with the `wasm32-wasip2` target: `rustup target add wasm32-wasip2`
  (`mise.toml` already lists it).

## Steps

1. Write the guest. This one answers every request with its path.
   `guest/Cargo.toml` has `crate-type = ["cdylib"]` and `wasi = "0.14"`:

   ```rust
   use wasi::exports::http::incoming_handler::Guest;
   use wasi::http::proxy::export;
   use wasi::http::types::{Fields, IncomingRequest, OutgoingBody, OutgoingResponse, ResponseOutparam};

   struct Hello;

   impl Guest for Hello {
       fn handle(request: IncomingRequest, out: ResponseOutparam) {
           let path = request.path_with_query().unwrap_or_default();
           let headers = Fields::from_list(&[("content-type".to_string(), b"text/plain".to_vec())]).unwrap();
           let response = OutgoingResponse::new(headers);
           let body = response.body().unwrap();
           ResponseOutparam::set(out, Ok(response));

           let stream = body.write().unwrap();
           stream.blocking_write_and_flush(format!("hello from wasm, you asked for {path}\n").as_bytes()).unwrap();
           drop(stream);
           OutgoingBody::finish(body, None).unwrap();
       }
   }

   export!(Hello);
   ```

2. Build it and put the component next to the manifest:

   ```sh
   cd examples/hello-wasm/guest
   cargo build --release --target wasm32-wasip2
   cp target/wasm32-wasip2/release/hello_guest.wasm ../hello.wasm
   ```

3. Write `atanor.json`. `kind` is `wasm` and `component` is the file name of
   the component in the project directory. A package carries the file; the
   manifest has no `module`.

   ```json
   {
     "manifest_version": 1,
     "name": "hello",
     "kind": "wasm",
     "component": "hello.wasm",
     "routes": [{"http": {"host": "localhost", "path": "/hello"}}]
   }
   ```

4. Run a node from the project directory:

   ```sh
   cd examples/hello-wasm
   mise exec -- mix atanor.dev --port 4000
   ```

   ```text
   Atanor listening on http://127.0.0.1:4000
     localhost/hello -> hello
   ```

5. Call it:

   ```text
   $ curl -i 'http://localhost:4000/hello/world?x=1'
   HTTP/1.1 200 OK
   content-length: 48
   content-type: text/plain

   hello from wasm, you asked for /hello/world?x=1
   ```

## Use bindings

A component uses a cell, a secret, another worker or outbound HTTP by
importing an interface, and only if the manifest grants it. The interfaces
are in [wit/](../wit): `atanor:cell/sql@0.1.0`, `atanor:config/secrets@0.1.0`
and `atanor:worker/call@0.1.0`; outbound HTTP is the standard
`wasi:http/outgoing-handler`.

1. In the guest's WIT world, import the interface and generate bindings with
   `wit-bindgen`. [test/fixtures/guests](../test/fixtures/guests) shows a
   world file (`wit/worlds.wit`), the `wit/deps` folder (the WASI 0.2.12
   WIT from `wasmtime-wasi-http`, and links to `wit/`, assembled by
   `mise run build:wasm-fixtures`) and one guest per binding.
2. Call it. A cell is addressed by `{namespace, key}`:

   ```rust
   use bindings::atanor::cell::sql::{self, Address, Value};

   let cell = Address { namespace: "notes".into(), key: "alice".into() };
   sql::execute(&cell, "INSERT INTO notes (body) VALUES (?)", &[Value::Text("hi".into())])?;
   let rows = sql::query(&cell, "SELECT body FROM notes", &[])?;
   ```

   `batch` runs several statements in one transaction. The results of all its
   statements together may not pass the node's `wasm.max_batch_bytes` (64 MiB by
   default): past it the batch is rolled back and fails with
   `failed("batch_too_large: ...")`. For a namespace that
   declares `partitions`, `sql::partition(&logical, &partition_key)` returns the
   address to use ([how-to-partition-a-cell.md](how-to-partition-a-cell.md)).
   `sql::query_bounded(&cell, sql, &params, max_lag_ms)` is a read that accepts
   data up to that many milliseconds old and may be answered by a replica on the
   node ([how-to-read-from-replicas.md](how-to-read-from-replicas.md)); `query`
   is always strong. A guest built before `query-bounded` existed still loads.
   `sockets::send_to_cell` takes messages up to `wasm.max_cell_message_bytes`
   (1 MiB by default).
3. Grant it in the manifest, with the same names as for a native worker:

   ```json
   "bindings": {"cells": {"notes": {"migrations": [[1, "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)"]]}}}
   ```

## Run code at a later time and serve WebSockets

Jobs use the same export model: grant `"jobs": true`, import
`atanor:cell/jobs@0.1.0` (`enqueue`, `enqueue-batch`) and export
`atanor:worker/job-handler@0.1.0`. See
[how-to-use-jobs.md](how-to-use-jobs.md).

A component receives alarms and WebSockets by exporting a handler. The
manifest grants the binding and the component exports the matching
interface; activation refuses a mismatch (see Troubleshooting). Each call to a
handler runs in a fresh instance under the limits below, so a handler keeps
nothing in memory between calls: keep state in cells.

**Alarms.** Set `"alarms": true` and grant the cell's namespace. The guest
sets its alarm with `atanor:cell/alarms` and handles it by exporting
`atanor:worker/alarm-handler`. Add to the guest's world file:

```wit
world worker {
  include wasi:http/proxy@0.2.12;
  import atanor:cell/sql@0.1.0;
  import atanor:cell/alarms@0.1.0;
  export atanor:worker/alarm-handler@0.1.0;
}
```

```rust
use bindings::atanor::cell::alarms;
use bindings::atanor::cell::sql::{self, Address, Value};
use bindings::exports::atanor::worker::alarm_handler::Guest as AlarmHandler;

// In the HTTP handler: fire in three seconds, with "ping" as the payload.
alarms::set_alarm("hits", "alice", now_ms + 3_000, b"ping")?;

impl AlarmHandler for Handler {
    fn handle_alarm(namespace: String, key: String, payload: Vec<u8>) -> Result<(), String> {
        let cell = Address { namespace, key };
        sql::execute(&cell, "INSERT INTO fires (payload) VALUES (?)", &[Value::Text(String::from_utf8_lossy(&payload).into_owned())])
            .map(|_| ())
            .map_err(|_| "cannot write the cell".to_string())
    }
}
```

`Ok(())` finishes the alarm. An `Err`, a trap or a limit is retried with
backoff, so handlers must be safe to repeat
([how-to-use-alarms.md](how-to-use-alarms.md)).

**WebSockets.** Export `atanor:worker/socket-handler`; every request with
`Upgrade: websocket` on the worker's route is upgraded. To send to other
sockets, set `"sockets": true`, grant the namespace and import
`atanor:cell/sockets@0.1.0`.

```wit
world worker {
  include wasi:http/proxy@0.2.12;
  import atanor:cell/sockets@0.1.0;
  export atanor:worker/socket-handler@0.1.0;
}
```

```rust
use bindings::atanor::cell::sockets;
use bindings::exports::atanor::worker::socket_handler::{
    Frame, Guest as SocketHandler, Incoming, Reply, Request, Upgrade,
};

impl SocketHandler for Handler {
    // The socket id is the same in every call of one connection.
    fn on_open(_socket: String, _request: Request) -> Result<Upgrade, String> {
        Ok(Upgrade::Accept)
    }

    fn on_message(_socket: String, message: Incoming) -> Result<Reply, String> {
        let frames = match message {
            Incoming::Text(t) if t == "join" => {
                sockets::attach("rooms", "lobby").map_err(|_| "cannot attach".to_string())?;
                vec![Frame::Text("joined".into())]
            }
            Incoming::Text(t) => {
                sockets::send_to_cell("rooms", "lobby", t.as_bytes()).map_err(|_| "cannot send".to_string())?;
                vec![]
            }
            // A message sent to a cell the socket is attached to.
            Incoming::Cell(bytes) => vec![Frame::Text(String::from_utf8_lossy(&bytes).into_owned())],
            Incoming::Binary(_) => vec![],
        };
        Ok(Reply { frames, close: false })
    }

    fn on_close(_socket: String) {}
}
```

`on-open` may return `Upgrade::Reject(response)` to answer the request
instead. It runs before the socket exists, so attach in `on-message`. An
error from `on-message` closes the socket with code 1011; `close: true` closes
it with 1000 after the frames. The test guests
[alarm.rs](../test/fixtures/guests/src/alarm.rs) and
[socket.rs](../test/fixtures/guests/src/socket.rs) are complete examples.
See [how-to-use-websockets.md](how-to-use-websockets.md) for the limits and
the delivery rules. For messages that are never stored (cursors, presence), the
same import has `join-channel`, `publish` and `channel-members`, and the optional
export `atanor:worker/socket-local` handles client frames without a call on the
owner: see
[how-to-share-ephemeral-messages.md](how-to-share-ephemeral-messages.md).

Limits (design §9): `limits.timeout_ms` (default 30,000; at most the node's
`max_timeout_ms`, 120,000 by default), `limits.memory_bytes` (default 64 MiB for
all the memories of a call together; at most `max_memory_bytes`, 512 MiB by
default), `limits.fuel` (fuel mode only; at most `max_fuel`) and `limits.cpu_ms`
(CPU time; at most the node's limit, 5000 ms by default). A larger value is
lowered to the node's ceiling. A call also holds at most `max_resources` (4,096)
host resources, and each `wasi:http` field set at most `max_field_bytes` (16,384)
bytes. An outbound HTTP request ends with the call's deadline, and its response
is read up to `calls.fetch_max_bytes` (8,000,000). A guest that exceeds one is stopped and the client gets 504
(timeout) or 500 (`limit_exceeded`). A node that is out of guest threads
answers 503. The same limits apply to each alarm and WebSocket call: a
handler that exceeds one fails its alarm attempt, or closes the socket with
1011.

The node keeps pre-mapped slots for the guests' memories and tables (the
`:atanor, :wasm` setting `pooling`, `true` by default), which makes a call
instantiate in 18 microseconds instead of 68 (design §14.9). The slots reserve
address space, about 390 GiB for 12 threads; on a host that limits address space
(`ulimit -v`, `vm.overcommit_memory=2`) set `pooling: false`. A component with
more than 8 memories or 16 tables, or a table larger than `table_elements`,
does not instantiate in either mode.

## Troubleshooting

- **The worker is not applied and the log says `{:not_granted, {:import,
  "atanor:cell/sql@0.1.0"}}`.** The component imports an interface the
  manifest does not grant. Add the binding, or remove the call. The same
  applies to `wasi:http/outgoing-handler` without `http.allow`.
- **`{:missing_export, "atanor:worker/alarm-handler@0.1.0"}`** (or
  `socket-handler`). The manifest has `"alarms": true` (or `"sockets": true`)
  but the component does not export the handler. Export it, or remove the
  grant.
- **`{:unsupported_for_wasm, :tcp}`.** WASM workers cannot serve raw TCP.
- **`{:unsupported_import, name}`.** The component imports an interface this
  node does not provide, such as an `atanor` interface of another version.
- **`{:invalid_component, message}`.** The file is not a component (a core
  module, for example, built for `wasm32-wasi` or `wasm32-unknown-unknown`).
  Build for `wasm32-wasip2`.
- **A cell call fails with `failed("statement_timeout: ...")`,
  `result_too_large`, `bad_params`, `overloaded` or `busy`.** The code starts the
  message of the `failed` case. The first three are about the statement (it ran
  past `statement_timeout_ms`, returned too many rows or bytes, or got the wrong
  parameters): narrow it. `overloaded` and `busy` mean the call did not run;
  retry after a moment. If the guest then answers 5xx, the client gets 503
  `overloaded` with `Retry-After`. The limits and their defaults are in
  [design §4.3](design.md#43-limits-on-cell-calls-and-their-errors).
- **A job call fails with `failed("store_unavailable: ...")` or
  `failed("sync_failed: ...")`.** The first means the store did not answer a
  request of the job's transaction, which was rolled back: nothing ran, retry
  after a moment (a guest that then answers 5xx gets 503 `unavailable` with
  `Retry-After`). The second means the cell stopped on an upload that failed:
  the write may or may not be applied (503 `unknown_outcome`); look at the state
  before repeating a write that is not idempotent.
- **The client gets 500 `internal_error` and the log shows `wasm trap`.** The
  guest panicked or trapped; its stderr, up to `stderr_bytes` (4 KiB by default), is logged just before.
- **503 `overloaded`.** All guest threads were busy and the queue was full or
  the call waited too long. The body is `{"error":"overloaded","reason":"overloaded"}`
  and the response carries `Retry-After` (`http.retry_after_s`, 1 s by default).
  See the node settings in `Atanor.Wasm`.

## Next steps

- [how-to-deploy-a-worker.md](how-to-deploy-a-worker.md) to switch versions and roll back.
- [design.md](design.md) sections 3.2, 4, 9 and 14 for the model and the limits.
- [telemetry.md](telemetry.md) for the events and counters.
