# How to write a native worker

**The question:** How do I write an Elixir worker, give it a cell, and run it
on a local node?

This guide stands alone. It uses [examples/hello-native](../examples/hello-native),
which you can read next to it.

## Prerequisites

- The tools of the [README](../README.md#requirements): Elixir, Erlang, Rust,
  and Alambique, a required dependency (its release tag is in `alambique.ref`).
- A Mix project. The example is a complete one.

## Steps

1. Add Atanor to the project. `alambique_testkit` is only for the in-memory
   store of `mix atanor.dev`. Atanor and the test kit must use the same
   Alambique, the release tag in Atanor's `alambique.ref`; replace `<tag>` with
   it (the example reads the file instead).

   ```elixir
   defp deps do
     [
       {:atanor, path: "path/to/atanor"},
       {:alambique, git: "https://github.com/This-Is-NPC/alambique.git", tag: "<tag>", override: true},
       {:alambique_testkit,
        git: "https://github.com/This-Is-NPC/alambique.git", tag: "<tag>", subdir: "testkit", only: :dev}
     ]
   end
   ```

2. Write the worker. It implements `Atanor.Worker`; `handle_request/2` gets an
   `Atanor.Request` and the `Atanor.Env`, and returns an `Atanor.Response`.
   The env is the only way to reach cells, secrets, outbound HTTP and other
   workers.

   ```elixir
   defmodule Hello.Worker do
     @behaviour Atanor.Worker
     alias Atanor.{Env, Request, Response}

     @impl true
     def handle_request(%Request{path: "/hello/" <> name}, env) do
       {:ok, _} = Env.execute(env, {"hits", name}, "UPDATE hits SET n = n + 1")
       {:ok, %{rows: [[n]]}} = Env.query(env, {"hits", name}, "SELECT n FROM hits")
       %Response{headers: [{"content-type", "application/json"}], body: Jason.encode!(%{hello: name, greetings: n})}
     end
   end
   ```

   `request.path` and `request.host` are canonical: the host is lower case
   without a trailing dot, and `%61` in the path arrives as `a` (other
   escapes stay, with upper-case hex). A request with a `.` or `..` segment,
   an escaped `/` or a bad escape never reaches the worker
   ([design §7.1](design.md#71-http)). `request.headers` and `request.body`
   are not printed when a request is inspected, so a crash log does not hold
   credentials.

   To serve a Plug (for example Phoenix) implement `plug(env)` instead. It
   returns `{plug_module, opts}`, and the plug finds the env in
   `conn.private[:atanor]`.

3. Write `atanor.json` at the project root. `module` is the module name with
   the `Elixir.` prefix. `bindings` lists everything the worker may use: here
   one cell namespace with its migrations. `routes` says which traffic it gets.

   ```json
   {
     "manifest_version": 1,
     "name": "hello",
     "kind": "native",
     "module": "Elixir.Hello.Worker",
     "bindings": {
       "cells": {
         "hits": {"migrations": [[1, "CREATE TABLE hits (n INTEGER NOT NULL)"], [2, "INSERT INTO hits (n) VALUES (0)"]]}
       }
     },
     "routes": [{"http": {"host": "localhost", "path": "/hello"}}]
   }
   ```

   A migration is `[version, sql]`, with versions counting up from 1. `sql` is
   one statement or a list of statements. To change the schema later, append a
   migration; never edit one that shipped. The full format is in
   [design.md](design.md#3-workers).

4. Start the node from the project directory.

   ```sh
   mise exec -- mix atanor.dev --port 4123
   ```

   Expected output:

   ```text
   Atanor listening on http://127.0.0.1:4123
     localhost/hello -> hello
   ```

5. Call it. The route host is `localhost`, so use that name in the URL.

   ```text
   $ curl -s http://localhost:4123/hello/ada
   {"hello":"ada","greetings":1}
   $ curl -s http://localhost:4123/hello/ada
   {"hello":"ada","greetings":2}
   $ curl -s http://localhost:4123/hello/bob
   {"hello":"bob","greetings":1}
   $ curl -s http://localhost:4123/x
   {"error":"not_found"}
   ```

   Each name is its own cell, so `bob` starts at 1. The data is in the
   in-memory store and is gone when the node stops.

   To answer any `Host` (a load balancer or probe that sends the node's IP),
   route `"host": "*"`. It is tried after exact and `*.domain` hosts, so
   specific routes still win, and the operator's `hosts:` must list `"*"` for
   the worker.

## Grant other bindings

Add them to `bindings` and use them through the env. Everything not granted
returns `{:error, {:not_granted, binding}}`.

| Manifest | Use |
| --- | --- |
| `"secrets": ["API_TOKEN"]` | `Atanor.Env.secret(env, "API_TOKEN")`. The operator supplies the value with `secrets: %{"hello" => %{"API_TOKEN" => "..."}}` in `{Atanor, opts}`; it is never in the manifest. |
| `"http": {"allow": ["api.example.com"]}` | `Atanor.Env.fetch(env, %Atanor.Request{...})`. Entries are `host`, `host:port`, `scheme://host[:port]` or `*.example.com` (subdomains only). Redirects are checked again, never go from https to http and do not carry `authorization`, `cookie` or `proxy-authorization` to another origin. The fetch ends after `calls: [fetch_timeout_ms:]` (30,000) and a body over `calls: [fetch_max_bytes:]` (8,000,000) is refused. Addresses that are private, loopback or link-local are refused unless the operator permits them (design section 4). |
| `"workers": ["auth"]` | `Atanor.Env.call(env, "auth", %Atanor.Request{...})`, at most 8 levels deep. The callee must agree: its manifest lists you in `"callable_by": ["hello"]` (a top-level key) or the operator sets `callers: %{"auth" => ["hello"]}`; otherwise the call returns `{:not_granted, {:worker, "auth"}}`. The callee's `auth:` rules do not apply, it gets no `x-atanor-claims`, and it does not get your WebSocket. |

A namespace under `"cells"` also grants its change feed:
`Atanor.Env.changes(env, namespace, position, limit)` reads a page, and
`Atanor.Env.subscribe(env, namespace, from: :now)` delivers changes to the
calling process. Reading does not wake the cells and delivery is at least once.
[how-to-follow-cell-changes.md](how-to-follow-cell-changes.md) covers
positions, backpressure and a cache example.

A namespace can add `"partitions": 6` next to its `migrations` to spread a very
busy cell over six cells, each with its own writer; the worker then addresses
cells with `Atanor.Env.partition/3`
([how-to-partition-a-cell.md](how-to-partition-a-cell.md)).

## Other traffic

A native worker can also receive raw TCP connections, over TLS or STARTTLS,
or through a Ranch protocol such as gen_smtp
([how-to-serve-tcp.md](how-to-serve-tcp.md)), WebSockets
([how-to-use-websockets.md](how-to-use-websockets.md)), alarms
([how-to-use-alarms.md](how-to-use-alarms.md)) and jobs
([how-to-use-jobs.md](how-to-use-jobs.md)).

## Run it in your own application

Compile the worker module into the same release as the node, then publish its
package and activate it. [how-to-deploy-a-worker.md](how-to-deploy-a-worker.md)
shows how, against a shared bucket, and how to switch versions and roll back.

## Run it on several nodes

With a `route_key/2` that names a cell, Atanor runs `handle_request/2` on the
node that owns the cell, whichever node received the request. The example has
one; [how-to-run-a-cluster.md](how-to-run-a-cluster.md) runs it on three nodes.
The handler gets plain data and must not keep state of its own between
requests. A request that only reads can say so with `{:cell, ns, key,
consistency: {:bounded, ms}}`: it then runs on the node that received it, reads
from a replica there and cannot write
([how-to-read-from-replicas.md](how-to-read-from-replicas.md)).

## Troubleshooting

- **`invalid manifest at <path>: ...`** The path names the first invalid key.
  Unknown keys are errors too.
- **`invalid manifest at manifest_version: is required`** Add
  `"manifest_version": 1` as the first key.
- **`{:module_not_loaded, "Elixir.Hello.Worker"}`** The module is not compiled in this
  project, or `module` is misspelled.
- **`{:not_a_worker, ...}` or `{:no_handler, ...}`** Add `@behaviour
  Atanor.Worker` and implement `handle_request/2`, `plug/1` or another handler
  (`handle_ws/3`, `handle_tcp/3`, `ranch_protocol/1`, `handle_alarm/3`).
- **`{:namespace_owned, "notes", owner}`** Another worker activated the namespace
  first and owns it. Use another namespace name, or ask the operator to list
  both workers in `namespaces: %{"notes" => [...]}`
  ([design §3.3](design.md#33-what-a-manifest-may-grant)).
- **`{:namespace_not_allowed, ...}`, `{:http_not_allowed, ...}`,
  `{:module_not_allowed, ...}`** The operator's `namespaces:`, `http_allow:` or
  `modules:` option does not list what the manifest asks for.
- **`{:namespace_conflict, ...}`** Another worker grants the same namespace
  with different migrations or different `partitions`. Make them identical.
- **`{:route_taken, ...}`** Another worker already holds that host and path.
- **`{:host_not_allowed, ...}` or `{:listener_not_configured, ...}`** The
  operator's `hosts:` or `listeners:` option does not allow the route.
- **404 from `curl`** The `Host` header must match a route. `127.0.0.1` does
  not match a route for `localhost`.
- **`{:error, :statement_timeout}`, `{:error, :result_too_large}` or
  `{:error, {:bad_params, message}}` from a cell call.** The statement ran past
  `alambique: [sql: [statement_timeout_ms: ...]]` (default 10,000 ms), returned
  more than `max_result_rows` (100,000) or `max_result_bytes` (64 MiB), or got
  the wrong number of parameters. Narrow the statement; repeating it fails the
  same way. Inside `transaction/4`, pass the error to `Alambique.Tx.rollback/2`.
- **`{:error, :overloaded}` or `{:error, :busy}` from a cell call.** The node is
  at `alambique: [awake: [max_cells:, max_wakes:, max_bytes:]]` (every awake
  cell has callers waiting, so none can hibernate to make room) or `max_pending`
  calls are already queued, running or waiting for an upload on the cell. The call did not run. Retry after a moment; if the
  worker answers 5xx the ingress sends 503 `overloaded` with `Retry-After`.
  Defaults and the other limits: [design §4.3](design.md#43-limits-on-cell-calls-and-their-errors).
- **500 `internal_error`** The worker raised, returned something other than
  an `Atanor.Response`, or hit an unexpected error. The node log names the
  worker and deployment. A cell call that could not run is not this: it is
  **503 `unavailable`** with a `reason` (`no_quorum`, `owner_unreachable`,
  `owner_down`, `fenced`, `deployment_unavailable`) and `Retry-After`, also when
  the worker maps the error to 500. A call routed toward a node of another
  store is **500 `foreign_store`**, a configuration error (see
  [docs/how-to-run-a-cluster.md](how-to-run-a-cluster.md)).
- **413** The body is over `max_body_bytes` (default 1,000,000).
- **`AlambiqueTestkit.MemoryStore is not available`** Add `alambique_testkit`
  to the project's dev dependencies, as in step 1.

## Next steps

- [design.md](design.md): bindings (section 4), routing (section 7), the
  deployment guarantee D1 (section 5) and the change feed (section 16).
