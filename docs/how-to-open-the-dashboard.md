# How to open the dashboard

**The question:** How do I open the read-only dashboard and see the workers,
deployments, routes, cells, alarms, jobs and metrics of my nodes in a browser?

This guide stands alone for a project that already runs Atanor. What each page
shows is in [screens.md](screens.md).

## Prerequisites

- A project that runs Atanor, for example the one in
  [how-to-write-a-native-worker.md](how-to-write-a-native-worker.md).
- The dashboard is optional, so Atanor does not bring Phoenix with it. Add these
  to the `deps` of your project:

  ```elixir
  {:phoenix, "~> 1.8"},
  {:phoenix_live_view, "~> 1.2"},
  {:phoenix_live_dashboard, "~> 0.9"},
  {:telemetry_metrics, "~> 1.2"}
  ```

  Then run `mix deps.get` and `mix deps.compile atanor --force`. Atanor
  compiles its dashboard only when it finds these packages, and Mix does not
  recompile it by itself when they appear.

## Steps

1. Start a local node. `mix atanor.dev` starts the dashboard on port 4002 with a
   random token and prints the URL to open:

   ```sh
   mix atanor.dev --port 4020
   ```

   ```text
   Atanor listening on http://127.0.0.1:4020
     127.0.0.1/c -> counter
   Dashboard on http://127.0.0.1:4002/workers?token=JWaeD5vOqwApzmh9dR5OdDt7
   ```

   `--dashboard-port PORT` (0 picks a free port) and `--dashboard-token TOKEN`
   choose them; `--no-dashboard` leaves the dashboard out.

   In an application, give the option to `Atanor`. The token is required, the
   listener is on loopback unless you pass `ip:`, and a VM runs one dashboard:

   ```elixir
   {Atanor, name: MyApp.Atanor, store: store, data_dir: dir,
    dashboard: [token: System.fetch_env!("ATANOR_DASHBOARD_TOKEN"), port: 4002]}
   ```

2. Open the URL, with the token. The browser is sent to the same page without
   the token in the address and keeps a cookie that says it is signed in.
   Without the token the answer is 401:

   ```sh
   curl -i localhost:4002/workers
   ```

   ```text
   HTTP/1.1 401 Unauthorized
   ```

3. Move between the pages with the menu: Workers, Deployments, Routes, Cells,
   Alarms and Jobs are Atanor's, and Metrics charts its telemetry events. The other
   pages are LiveDashboard's own. On a cluster, the "Selected node" menu picks
   the node whose routes and cells you see. "Update every" sets the refresh.

4. Open Metrics while the node serves traffic. The charts start when you open
   the page and keep no earlier history. The groups are Requests, Cluster, Wasm,
   Connections, Alarms, Jobs, Cells, and the native counters of the WASM library
   (Wasm native) and of Alambique (Alambique native), which the dashboard polls
   every 5 seconds.

The dashboard is read-only: no page changes a deployment. Use
[how-to-deploy-a-worker.md](how-to-deploy-a-worker.md) for that.

## Troubleshooting

- **`Dashboard not started: add {:phoenix, ...}`** from `mix atanor.dev`: the
  project lacks the dependencies above, or Atanor was compiled before you added
  them. Run `mix deps.get` and `mix deps.compile atanor --force`. Passing
  `--dashboard-port` without them is an error.
- **`ArgumentError: :dashboard needs a :token`** or **`... needs these
  dependencies`**: the option is invalid without a non-empty token, or Atanor
  was compiled without the dashboard (same fix).
- **401 with the right token.** Only a `GET` with `?token=` signs in. A restart
  of the node signs everyone out: open the new URL.
- **The page loads but stays empty or disconnected.** The socket accepts only
  the origin the page was served from. Open the address the node listens on
  (for example `127.0.0.1`, not a name that points to it through a proxy).
- **Address already in use.** Port 4002 is taken. Pass `--dashboard-port`.
- **`{:error, ...}` or "did not answer" on Routes or Cells.** The selected node
  does not run this instance, or did not answer within 5 seconds.

## Next steps

- [screens.md](screens.md) for what each page shows.
- [how-to-use-the-admin-api.md](how-to-use-the-admin-api.md) for the same data
  as JSON, and [telemetry.md](telemetry.md) for the events behind Metrics.
