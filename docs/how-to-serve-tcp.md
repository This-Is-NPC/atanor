# How to serve a TCP protocol from a worker

**The question:** How do I let a native worker speak a line-based protocol
(SMTP, IMAP, your own) over raw TCP or TLS, bind a connection to a cell, and
serve it with a protocol library such as gen_smtp?

This guide stands alone. It uses [examples/echo-tcp](../examples/echo-tcp). To
write a worker and run a local node first, see
[how-to-write-a-native-worker.md](how-to-write-a-native-worker.md).

## Prerequisites

- The tools of the [README](../README.md#requirements).
- A free local port. The example uses 2525.
- For TLS, a certificate and its key in PEM files. During development
  `openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem
  -days 1 -subj /CN=localhost` makes a self-signed pair.
- For the gen_smtp section, the optional `gen_smtp` dependency in your project.

## Steps

1. Route a listener name to the worker in `atanor.json`. A manifest names a
   listener, never a port.

   ```json
   "routes": [{"tcp": {"listener": "visits"}}]
   ```

2. Implement the TCP callbacks. Atanor hands over bytes as they arrive and
   does no framing, so the worker keeps a buffer in its state and splits lines
   itself.

   ```elixir
   @impl true
   def tcp_init(_info, _env), do: {:reply, "READY\r\n", %{buffer: "", name: nil}}

   @impl true
   def handle_tcp(data, state, env), do: lines(%{state | buffer: state.buffer <> data}, env, [])
   ```

   `handle_tcp/3` returns `{:continue, state}`, `{:reply, iodata, state}`,
   `{:starttls, iodata, state}` (see step 6) or `{:close, iodata}` (send, then
   close). `tcp_init/2` is optional and gets `%{listener: name, peer: {ip,
   port}}`. A line that never ends is the worker's to refuse: the example
   closes at 256 bytes.

3. Bind the connection to a cell with `route_key/2`. Atanor calls it after
   each callback with `{:tcp, state}` until it returns a cell, then stops
   asking. The cell must be in a namespace the manifest grants.

   ```elixir
   @impl true
   def route_key({:tcp, %{name: name}}, _env) when is_binary(name), do: {:cell, "visits", name}
   def route_key(_input, _env), do: :none
   ```

   The callback that stored `name` ran before the binding; the ones after it
   run for the cell. A connection cannot be rebound.

4. Start a node and map the listener name to a port.

   ```sh
   cd examples/echo-tcp
   mise exec -- mix atanor.dev --port 4124 --listener visits=2525
   ```

   ```text
   Atanor listening on http://127.0.0.1:4124
     tcp visits on 127.0.0.1:2525 -> visits
   ```

   In your own application the mapping is the `listeners:` option of
   `{Atanor, opts}`, for example `listeners: %{"visits" => 2525}`; port 0
   picks a free port and `Atanor.TCP.port/2` tells which. The long form of a
   listener adds TLS and the protocol server:

   ```elixir
   listeners: %{
     "smtp" => [port: 25, protocol: :ranch],
     "submission" => [
       port: 587,
       tls_mode: :starttls,
       tls: [certfile: "/etc/mail/cert.pem", keyfile: "/etc/mail/key.pem"]
     ]
   }
   ```

5. Talk to it. This is a real session; `>` is sent, `<` is received.

   ```text
   < READY
   > HELLO ada
   < OK ada
   > VISIT
   < VISITS 1
   > VISIT
   < VISITS 2
   > NOPE
   < ERR unknown command
   > QUIT
   < BYE
   ```

   A second connection that says `HELLO ada` and `VISIT` gets `VISITS 3`:
   the count lives in the cell `visits.ada`, not in the connection.

6. Upgrade a connection to TLS with STARTTLS. Configure the listener with
   `tls_mode: :starttls` and return `{:starttls, "220 Ready to start TLS\r\n",
   state}` from `handle_tcp/3` where the protocol asks for it.

   ```elixir
   defp line("STARTTLS", state, _env), do: {:starttls, "220 Ready to start TLS\r\n", state}
   ```

   Atanor sends the bytes, performs the TLS handshake with the listener's
   current certificate and continues the same connection and worker state
   over TLS. There is no callback for the upgrade; the next bytes arrive in
   `handle_tcp/3` as usual. Returning `{:starttls, ..., state}` on a plain or
   implicit-TLS listener closes the connection and logs it.

   For implicit TLS, set `tls_mode: :implicit`; the first byte the worker
   sees is already decrypted. In both modes the client verifies the
   certificate against its own trust store; the examples use `:ssl.connect`
   with `verify: :verify_none` because the test certificate is self-signed.

   ```elixir
   {:ok, socket} = :ssl.connect(~c"localhost", 465, [verify: :verify_none, active: false])
   ```

7. Reload a certificate without restarting. Replace the files at the
   configured paths. The node polls their size, mtime and digest every
   `tls.reload_ms` (5 000 by default), and new handshakes use the new pair
   while established connections keep their session. A replacement that does
   not load keeps the previous certificate and logs a warning. To reload at
   once, call the admin API:

   ```sh
   curl -s -X POST -H "authorization: Bearer $TOKEN" \
     localhost:5001/listeners/submission/reload-tls
   ```

   ```json
   {"listener":"submission","reloaded":true}
   ```

   A listener without TLS answers 409 `no_tls`, an unknown one 404, and a
   broken replacement 422 `reload_failed` while the old certificate stays in
   service. The events are in [telemetry.md](telemetry.md).

   To require client certificates (mTLS), set `verify: :verify_peer` and
   `cacertfile` to the CA that signs them, and `fail_if_no_peer_cert: true`
   to refuse clients that present none (the default with `:verify_peer`;
   `false` accepts them and the worker checks `peercert`):

   ```elixir
   tls: [
     certfile: "/etc/mail/cert.pem",
     keyfile: "/etc/mail/key.pem",
     cacertfile: "/etc/mail/clients-ca.pem",
     verify: :verify_peer,
     fail_if_no_peer_cert: true
   ]
   ```

   `:fail_if_no_peer_cert` is refused unless `:verify_peer` is set. Clients
   cannot renegotiate a TLS 1.2 session (`client_renegotiation: false`), which
   closes a way to make a handshake-heavy listener spend CPU.

### Bind a listener to its own address

A listener binds the ingress `ip` (loopback unless you set `ip:`). Give it
`ip:` to bind another address, for example SMTP on a public address while
HTTP stays behind a proxy on loopback:

```elixir
{Atanor,
 ip: {127, 0, 0, 1},
 listeners: %{
   "smtp" => [port: 25, ip: "203.0.113.10", protocol: :ranch],
   "imap" => [port: 143, ip: "::"],
   "lab" => [port: 2525]
 }}
```

`ip:` takes a tuple (`{203, 0, 113, 10}`) or a string (`"203.0.113.10"`,
`"::1"`); `{0, 0, 0, 0}` and `"::"` bind every interface. Here `lab` keeps
the ingress `ip`. An invalid address raises `ArgumentError` when the instance
starts; an address the machine does not own refuses the activation with
`{:listener_failed, name, :eaddrnotavail}`.

### Say which workers may claim a listener

Any worker whose manifest names a configured listener can claim it, and with it
its TLS certificate, unless the listener lists the workers. Do this for every
listener on a node where several teams deploy:

```elixir
listeners: %{"smtp" => [port: 25, protocol: :ranch, workers: ["mail"]]}
```

Another worker that names `smtp` fails with `{:listener_not_allowed, "smtp",
worker}` (HTTP 422 `listener_not_allowed` on upload with `activate`). Without
`workers:` any worker may, which trusts the packages
([design §3.3](design.md#33-what-a-manifest-may-grant)).

## Serve a Ranch protocol (gen_smtp)

A protocol library that speaks Ranch can own the connection instead of the
`handle_tcp/3` callbacks. Ranch is an optional dependency: add `:ranch` to your
project, configure the listener with `protocol: :ranch`, and give the worker a
`ranch_protocol/1` callback. If Ranch is not loaded, the activation is refused
with `{:listener_failed, name, {:missing_dependency, :ranch}}`.

1. Name the protocol in the manifest route. It must match the operator's
   listener; a mismatch refuses the activation.

   ```json
   "routes": [{"tcp": {"listener": "smtp", "protocol": "ranch"}}]
   ```

2. Implement `ranch_protocol/1`. It gets the `Atanor.Env` of the connection,
   resolved when the connection is accepted, and returns the Ranch protocol
   module and its options. This is the whole worker for a gen_smtp server:

   ```elixir
   defmodule Mail.SmtpWorker do
     @behaviour Atanor.Worker

     @impl true
     def ranch_protocol(env) do
       {:gen_smtp_server_session, {Mail.SmtpCallback, [hostname: "mail.example.com", callbackoptions: []]}}
     end
   end
   ```

3. Read the environment in the gen_smtp callback. Atanor adds
   `:atanor_env` and `:atanor_listener` (the name of the listener that
   accepted the connection) to the `callbackoptions` list, which gen_smtp
   passes as the fourth argument of `init/4`. Inbound SMTP and submission can
   share one worker and tell themselves apart by the name:

   ```elixir
   defmodule Mail.SmtpCallback do
     @behaviour :gen_smtp_server_session

     @impl true
     def init(_hostname, _sessions, _peer, opts) do
       env = Keyword.fetch!(opts, :atanor_env)
       listener = Keyword.fetch!(opts, :atanor_listener)  # "smtp" or "submission"
       {:ok, "mail.example.com ESMTP", %{env: env, listener: listener, rcpt: nil}}
     end

     @impl true
     def handle_RCPT(to, state), do: {:ok, %{state | rcpt: to}}

     @impl true
     def handle_DATA(_from, _to, data, state) do
       {:ok, _} = Atanor.Env.execute(state.env, {"mail", state.rcpt}, "INSERT INTO mail (body) VALUES (?)", [data])
       {:ok, "stored", state}
     end
     # ... the other gen_smtp callbacks
   end
   ```

   Atanor also adds, at the top level of the options, `:atanor_env`,
   `:atanor_listener`, `:atanor_tls_options` (the current `:ssl` server options) and, on a
   `tls_mode: :starttls` listener, `:tls_options` under the name gen_smtp
   reads for its own STARTTLS. On an implicit-TLS listener the Ranch
   transport is `ranch_ssl`, so gen_smtp's socket is already encrypted. The
   full set is documented in `Atanor.TCP.Ranch`.

4. Point the operator's listener at the protocol:

   ```elixir
   listeners: %{
     "smtp" => [port: 25, protocol: :ranch],
     "submission" => [
       port: 587,
       protocol: :ranch,
       tls_mode: :starttls,
       tls: [certfile: "/etc/mail/cert.pem", keyfile: "/etc/mail/key.pem"]
     ],
     "smtps" => [
       port: 465,
       protocol: :ranch,
       tls_mode: :implicit,
       tls: [certfile: "/etc/mail/cert.pem", keyfile: "/etc/mail/key.pem"]
     ]
   }
   ```

   Atanor starts one Ranch listener per claimed name with the listener's
   `acceptors` and `max_connections`, resolves the deployment at accept (a
   connection keeps its version, like the `handle_tcp/3` path), and closes
   the listener when the deployment is retired or the node stops. On an
   implicit-TLS listener the `ranch_ssl` transport handshakes with
   `tls.handshake_timeout_ms`; gen_smtp's own STARTTLS uses its fixed 5 s
   timeout.

## Limits and behavior

| Operator option | Default | Effect |
| --- | --- | --- |
| `tcp: [idle_timeout_ms: n]` | 60,000 | Closes a connection that sent nothing for that long (ThousandIsland listeners). |
| `tcp: [max_chunk_bytes: n]` | 65,536 | Most bytes one `handle_tcp/3` call gets. |
| `tcp: [max_connections: n]` | 16,384 | Default connection cap of a listener. |
| `tcp: [acceptors: n]` | 10 | Default acceptor count of a listener. |
| `listeners: [ip: address]` | the ingress `ip` | Address the listener binds: a tuple or a string, IPv4 or IPv6. |
| `listeners: [acceptors: n]` | `tcp.acceptors` | Acceptors of this listener. |
| `listeners: [max_connections: n]` | `tcp.max_connections` | Connection cap of this listener. |
| `listeners: [tls: [handshake_timeout_ms: n]]` | 10,000 | TLS handshake timeout; a protocol's own STARTTLS may use its own. |
| `listeners: [tls: [reload_ms: n]]` | 5,000 | How often the certificate files are checked. |

- A connection keeps the deployment it started on until it closes. After a
  switch, old connections run the old version and new ones the new version.
- Undeploying the worker closes its listener and ends its connections.
- A callback that raises or returns another shape closes the connection and
  is logged; the peer sees nothing of the error.
- WASM workers cannot serve TCP, and therefore cannot use implicit TLS,
  STARTTLS or Ranch protocol listeners (design §3.2).

## Troubleshooting

- **`{:listener_not_configured, "visits"}`** The node has no `listeners:`
  entry (or `--listener`) for that name.
- **`{:listener_failed, "visits", :eaddrinuse}`** Something else holds the
  port. The previous deployment keeps serving. When a node starts and the
  port is taken, the worker is already active: the node logs `TCP listener
  visits not opened: :eaddrinuse` and `/routes` lacks the listener. Free the
  port and restart the node.
- **`{:listener_failed, "smtp", :eaddrnotavail}`** The listener's `ip:` is
  not an address of this machine.
- **`{:listener_failed, "smtp", {:missing_dependency, :ranch}}`** The
  listener or route asks for Ranch and the node does not have the optional
  `:ranch` dependency.
- **`{:listener_protocol_mismatch, "smtp", :ranch, :thousand_island}`** The
  manifest route and the operator's listener disagree on the protocol.
- **`{:listener_taken, "visits", worker}`** Another worker claims the listener.
- **`{:missing_callback, Echo.Worker, {:handle_tcp, 3}}`** A `tcp` route needs
  `handle_tcp/3`; a `"protocol": "ranch"` route instead needs
  `ranch_protocol/1`.
- **The connection closes after a command that names a cell.** The routing
  key named a namespace the manifest does not grant, or an invalid key; the
  node log says so.
- **`{:listeners entry "smtp" tls: ...}` at start.** The certificate or key
  is unreadable, the key does not belong to the certificate, or another TLS
  option is invalid; the message names the option.

## Next steps

- [design.md](design.md#73-tcp-and-websockets): the connection model and
  guarantees.
- [telemetry.md](telemetry.md): connect, disconnect, TLS handshake and reload
  events.
- [how-to-use-the-admin-api.md](how-to-use-the-admin-api.md): the certificate
  reload endpoint.
