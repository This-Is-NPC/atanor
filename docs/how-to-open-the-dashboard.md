# How to open the dashboard

**The question:** How do I open the read-only dashboard and see the workers,
deployments, routes, cells, alarms, jobs and metrics of my nodes in a browser?

This guide stands alone for a node of the release image. What each page
shows is in [screens.md](screens.md).

## Prerequisites

- Docker, and a node of the release image. The [local node guide](how-to-run-a-node-locally.md)
  starts one without the dashboard; step 1 below restarts it with the dashboard.
- A browser on the same machine as the node.
- A node in your own application: see [in your own application](#in-your-own-application).

## Steps

1. Make a dashboard token and start the node with the dashboard. The dashboard
   is on only when `ATANOR_DASHBOARD_TOKEN` is set, to 32 bytes or more. The
   node reads the token from a file, as the local guide does. Run this in the
   directory of the local guide, with `IMAGE` set as in its step 1:

   ```sh
   openssl rand -hex 24 | tr -d '\n' > atanor-secrets/dashboard_token
   chmod 644 atanor-secrets/dashboard_token
   docker rm -f atanor-node
   docker run -d --name atanor-node --network atanor-net --stop-timeout 90 \
     -p 127.0.0.1:4000:4000 -p 127.0.0.1:4001:4001 -p 127.0.0.1:4002:4002 \
     -v "$PWD/atanor-secrets:/run/secrets:ro" \
     -e ATANOR_STORE=s3://atanor -e ATANOR_S3_ENDPOINT=http://atanor-store:8333 \
     -e AWS_ACCESS_KEY_ID_FILE=/run/secrets/access_key -e AWS_SECRET_ACCESS_KEY_FILE=/run/secrets/secret_key \
     -e ATANOR_ADMIN_TOKEN_FILE=/run/secrets/admin_token -e ATANOR_COOKIE_FILE=/run/secrets/cookie \
     -e ATANOR_DASHBOARD_TOKEN_FILE=/run/secrets/dashboard_token \
     -e ATANOR_ADVERTISE=atanor-node.local "$IMAGE"
   ```

   Wait until the node is ready, as in step 4 of the local guide. The dashboard
   listens on port 4002 in the container; `-p 127.0.0.1:4002:4002` publishes it
   on loopback only. Its settings are `ATANOR_DASHBOARD_LISTEN` (default
   `0.0.0.0:4002`) and the token; see [configuration](configuration.md).

2. Open the dashboard with the token. Read the token with
   `cat atanor-secrets/dashboard_token` and open:

   ```text
   http://127.0.0.1:4002/workers?token=<dashboard token>
   ```

   The browser is sent to the same page without the token in the address and
   keeps a cookie that says it is signed in. Without the token the answer is 401:

   ```sh
   curl -i localhost:4002/workers
   ```

   ```text
   HTTP/1.1 401 Unauthorized
   ```

3. Move between the pages with the menu: Workers, Deployments, Routes, Cells,
   Alarms and Jobs are Atanor's, and Metrics charts its telemetry events. Home,
   Memory Allocators and Applications are LiveDashboard's own. The dashboard
   does not serve its Processes, Ports, Sockets, ETS and OS Data pages, nor the
   detail of a process: a menu entry is hidden and its address redirects to the
   home page. On a cluster, the "Selected node" menu picks
   the node whose routes and cells you see. "Update every" sets the refresh.

4. Open Metrics while the node serves traffic. The charts start when you open
   the page and keep no earlier history. The groups are Requests, Cluster, Wasm,
   Connections, Alarms, Jobs, Cells, and the native counters of the WASM library
   (Wasm native) and of Alambique (Alambique native), which the dashboard polls
   every 5 seconds.

The dashboard is read-only: no page changes a deployment. Use
[how-to-deploy-a-worker.md](how-to-deploy-a-worker.md) for that.

## In your own application

A node that runs in your own application (a [derived image](how-to-build-a-derived-image.md))
gives the option to `Atanor` instead. The dashboard is optional there, so
Atanor does not bring Phoenix with it. Add these to the `deps` of your project:

```elixir
{:phoenix, "~> 1.8"},
{:phoenix_live_view, "~> 1.2"},
{:phoenix_live_dashboard, "~> 0.9"},
{:telemetry_metrics, "~> 1.2"}
```

Then run `mix deps.get` and `mix deps.compile atanor --force`. Atanor compiles
its dashboard only when it finds these packages, and Mix does not recompile it
by itself when they appear.

```elixir
{Atanor, name: MyApp.Atanor, store: store, data_dir: dir,
 dashboard: [token: System.fetch_env!("ATANOR_DASHBOARD_TOKEN"), port: 4002]}
```

The token is required, the listener is on loopback unless you pass `ip:`, and a
VM runs one dashboard. The cookie lasts `cookie_max_age_s` seconds (86 400, one
day by default). The dashboard listens on plain http, so it cannot tell that a
proxy in front of it serves https: pass `secure_cookie: true` then, and the
cookie gets `Secure`. Its default is the node's `behind_tls_proxy` option
(`ATANOR_BEHIND_TLS_PROXY` in the release, [TLS at the proxy](how-to-run-in-production.md#tls-at-the-proxy)),
so a node declared behind a TLS proxy needs no other setting. Leave it `false` for a loopback dashboard, which a
browser reaches over http and would not send a `Secure` cookie to. A dashboard that binds outside loopback
without `behind_tls_proxy` logs a warning at start: its token passes in clear.

## Troubleshooting

- **The dashboard does not answer.** The node has no dashboard when
  `ATANOR_DASHBOARD_TOKEN` is unset or shorter than 32 bytes. Set it, then start
  the node again.
- **`ArgumentError: :dashboard needs a :token`** or **`... needs these
  dependencies`** (in your own application): the option needs a non-empty token,
  or Atanor was compiled without the dashboard. Add the dependencies above, then
  run `mix deps.compile atanor --force`.
- **429 with the right token.** The client address made `max_failures` (10)
  wrong tokens in `failure_window_ms` (60 seconds, options of `dashboard:`). The
  answer has `Retry-After`; wait that long. The address is the peer of the
  connection, so behind a proxy every client shares the limit.
- **401 with the right token.** Only a `GET` with `?token=` signs in. A restart
  of the node signs everyone out, and so does the end of `cookie_max_age_s`:
  open the URL with the token again. With `secure_cookie: true` the browser
  keeps the cookie only over https.
- **The page loads but stays empty or disconnected.** The socket accepts only
  the origin the page was served from. Open the address the node listens on
  (for example `127.0.0.1`, not a name that points to it through a proxy).
- **Address already in use.** Port 4002 on your machine is taken. Publish another
  host port, for example `-p 127.0.0.1:4012:4002`, and open that port.
- **`{:error, ...}` or "did not answer" on Routes or Cells.** The selected node
  does not run this instance, or did not answer within 5 seconds.

## Next steps

- [screens.md](screens.md) for what each page shows.
- [how-to-use-the-admin-api.md](how-to-use-the-admin-api.md) for the same data
  as JSON, and [telemetry.md](telemetry.md) for the events behind Metrics.
