# How to build a derived image

**The question:** How do I run my own Elixir code, a Phoenix and LiveView app
included, in the same VM as an Atanor node, as a container image, and deploy a
native worker to it?

This guide stands alone for someone with an Elixir project and Docker. Every
command runs in your project. The app of this guide is a LiveView page and a
native worker `counter`, in one release with the node.

## What you get

A derived image is a Mix release of **your** app that has Atanor as a
dependency. Your supervision tree starts the node first, then your own processes
(the Phoenix endpoint here), so your code and Atanor share one VM: your code can
call a worker, and a native worker can call your modules, with no network between them.

The release is named `atanor`, so the image has the same layout as the product
image: the same entry point, the same start script, the same environment
variables ([configuration.md](configuration.md#the-daemon-environment-and-file))
and the same `atanor deploy` command. `mix atanor.release` writes the files that
make that so.

This is the way to run Elixir code, Phoenix and LiveView included, with Atanor.
Adding Atanor to the supervision tree of an app that you release your own way
is not a supported way to install it.

## Prerequisites

- An Elixir 1.17 or later project with a Mix release.
- Docker with BuildKit (Docker 23 or later). Elixir, Erlang and Rust are in the
  build stage; the first build compiles the Rust crates of Atanor and Alambique
  and can take a long time.
- `curl` and `openssl` on the host, for the commands of steps 7 and 8.

## Steps

1. Add Atanor to `mix.exs`, and name the release `atanor`. Use a release tag.
   Alambique comes with Atanor, so do not declare it.

   ```elixir
   def project do
     [
       app: :live_counter,
       # ...
       releases: [atanor: [include_executables_for: [:unix]]]
     ]
   end

   defp deps do
     [
       {:atanor, git: "https://github.com/This-Is-NPC/atanor.git", tag: "v0.10.1"}, # x-release-please-version
       {:phoenix, "~> 1.8"},
       {:phoenix_live_view, "~> 1.2"}
     ]
   end
   ```

   Run `mix deps.get`.

2. Start the node in your supervision tree, before your own processes:

   ```elixir
   def start(_type, _args) do
     children = Atanor.Daemon.children() ++ [{Phoenix.PubSub, name: LiveCounter.PubSub}, LiveCounterWeb.Endpoint]
     Supervisor.start_link(children, strategy: :one_for_one, name: LiveCounter.Supervisor)
   end
   ```

   `Atanor.Daemon.children/0` reads the environment and `ATANOR_CONFIG` as the
   product image does, and fails with every problem found if a setting is wrong.
   It is the same function the product's own application uses, so there is one
   loader. The instance it starts is `Atanor.Daemon.instance()`.

3. Write the native worker and its manifest, as in
   [how-to-write-a-native-worker.md](how-to-write-a-native-worker.md). The worker
   module is `LiveCounter.Worker`: `GET /counter` returns the count and
   `POST /counter` adds one. Its manifest, `atanor.json` at the project root:

   ```json
   {
     "manifest_version": 1,
     "name": "counter",
     "kind": "native",
     "module": "Elixir.LiveCounter.Worker",
     "bindings": {
       "cells": {
         "counter": {"migrations": [[1, "CREATE TABLE hits (n INTEGER NOT NULL)"], [2, "INSERT INTO hits (n) VALUES (0)"]]}
       }
     },
     "routes": [{"http": {"host": "counter.localhost", "path": "/counter"}}]
   }
   ```

   The page reaches the worker in the same VM by running the active deployment
   as the ingress does:

   ```elixir
   {:ok, deployment} = Atanor.Registry.deployment(Atanor.Daemon.instance(), "counter")
   Atanor.Workers.invoke(Atanor.Env.new(Atanor.Daemon.instance(), deployment), %Atanor.Request{path: "/counter"})
   ```

   The manifest `callable_by` rules do not apply to this call.

4. Write what your app needs at run time. Do not name a variable `ATANOR_*`
   unless it is one of the daemon's: the daemon refuses an unknown one. Your
   `config/runtime.exs` reads what the app needs, such as `PORT` and
   `SECRET_KEY_BASE`.

5. Write the release files and the Dockerfile. Run this in the project directory:

   ```sh
   mix atanor.release
   ```

   ```text
   wrote      rel/env.sh.eex
   wrote      rel/overlays/bin/atanor-entrypoint
   wrote      Dockerfile
   wrote      Dockerfile.dockerignore

   Build the image, from this directory, with this directory as the context:
     docker build -t my-app .
   ```

   The two `rel/` files are copied from the `atanor` dependency, which the
   product image uses too. The Dockerfile builds the release on the same Elixir,
   Rust and Debian bases as the product image, compiles the Rust crates, and runs
   it as the user `atanor` (uid 10001). Commit these files. If one already exists
   and differs, `mix atanor.release` keeps it; `--force` replaces it. Rerun the
   task after you update Atanor. The build argument `EXTRA_PACKAGES` adds Debian
   packages (for example `curl`), and `RELEASE_ID` sets the id the node reports
   ([design 17.1](design.md#171-release-identity)).

6. Build the image, from the project directory:

   ```sh
   docker build -t my-app .
   ```

   The Dockerfile copies the whole project before it fetches the dependencies,
   so a change to any file reruns `mix deps.get` and the compile of the
   dependencies. The Cargo cache mounts keep the Rust crates' build between builds.

7. Start it. The node needs the same environment as the product image
   ([configuration.md](configuration.md#the-daemon-environment-and-file)),
   and the app its own variables; `<...>` marks a value you choose:

   ```sh
   docker run -d --name my-app --stop-timeout 90 -p 4000:4000 -p 4001:4001 -p 4010:4010 \
     -v <secrets dir>:/run/secrets:ro \
     -e ATANOR_STORE=s3://<bucket>/<prefix> -e ATANOR_S3_ENDPOINT=<S3 endpoint URL> \
     -e AWS_ACCESS_KEY_ID_FILE=/run/secrets/access_key \
     -e AWS_SECRET_ACCESS_KEY_FILE=/run/secrets/secret_key \
     -e ATANOR_ADMIN_TOKEN_FILE=/run/secrets/admin_token \
     -e ATANOR_ADVERTISE=<host or IP with a dot, such as node-1.example> \
     -e ATANOR_COOKIE_FILE=/run/secrets/cookie \
     -e SECRET_KEY_BASE=<64 or more random bytes, hex> \
     my-app
   ```

   Port 4000 is Atanor's ingress and 4001 its admin API. Port 4010 is the port of
   your app: `PORT` sets it, and the `-p` mapping must match. Until step 8, the
   page says the worker is not deployed yet.

8. Deploy the native worker **through the node**. A native package holds the MD5
   of its module, which only a node can check against the code it runs, so
   `--bucket` refuses it. Use `--url` and a token, after the nodes run the new
   image. Run the command from the project directory, which holds `atanor.json`;
   the image holds the `atanor` command and the compiled module, so only that
   directory is mounted. The `--ebin` path is the directory of your app's
   modules in the image, `lib/<app>-<version>/ebin` from your `mix.exs`:

   ```sh
   docker run --rm --network container:my-app -v "$PWD:/w:ro" \
     -e ATANOR_URL=http://127.0.0.1:4001 -e ATANOR_TOKEN="$(cat <secrets dir>/admin_token)" \
     my-app deploy /w --ebin /opt/atanor/lib/live_counter-0.1.0/ebin --activate
   ```

   The `deploy` command runs in a BEAM `eval`. Call the route of `atanor.json`
   on port 4000 with its host:

   ```sh
   curl -H 'Host: counter.localhost' http://127.0.0.1:4000/counter                # read the count
   curl -H 'Host: counter.localhost' -X POST http://127.0.0.1:4000/counter        # add one
   ```

   Here the command shares the node's network, so the URL is loopback (the CLI
   refuses a token over plain http to another host; use https and a scoped
   token from a CI machine, [how-to-deploy-a-worker.md](how-to-deploy-a-worker.md)). The node
   serves the worker as soon as the command returns.

   To ship new Elixir code, build and roll the new image first, then deploy:
   see [Native code](how-to-deploy-a-worker.md#native-code).

## Troubleshooting

- **`mix atanor.release` says the project has no release named atanor.** Add
  `releases: [atanor: [include_executables_for: [:unix]]]` to `project/0`. The
  name must be `atanor`: the entry point and the start script of the image call
  `bin/atanor`.
- **The node exits at once.** Read `docker logs`. A missing cookie, advertise
  address or an unknown `ATANOR_` variable is named there. `SECRET_KEY_BASE is required` comes from
  your own `config/runtime.exs`.
- **`deploy` fails with `SECRET_KEY_BASE is required` (or another error of your
  `config/runtime.exs`).** The commands of the entry point (`deploy`, `status`, ...) run through
  `bin/atanor eval`, which reads `runtime.exs` too, though it starts no app and your variables are
  not there. Skip what only the running app needs when `System.get_env("RELEASE_COMMAND") == "eval"`.
- **`bin/atanor rpc` or `remote` says `noconnection`.** The node is named
  `atanor@<ATANOR_ADVERTISE>`, and the machine that connects must resolve that name. Inside the
  container the name has to resolve to the container itself, for example with a Docker network alias
  equal to `ATANOR_ADVERTISE`.
- **The build stops while fetching a dependency.** `mix deps.get` runs in the
  build stage, with the `mix.lock` of your app: commit it.
- **The Rust build runs out of memory.** Pass fewer jobs:
  `docker build --build-arg CARGO_BUILD_JOBS=2 -t my-app .`.
- **`deploy` answers `module_not_loaded` or `code_mismatch`.** The node runs an
  older image than the package. Roll the node to the image the module comes from
  (`--ebin` must name that release's directory), then deploy again.
- **The page says the counter worker is not deployed.** Deploy it (step 8).
- **The LiveView page loads but never connects.** `check_origin` of the endpoint
  refuses the host name you use. Set it to the host names of your app.

## Next steps

- [how-to-deploy-a-worker.md](how-to-deploy-a-worker.md): scoped tokens, rollbacks and rollouts of native code.
- [how-to-run-a-cluster.md](how-to-run-a-cluster.md): several nodes of an image over one store.
- [how-to-use-websockets.md](how-to-use-websockets.md): sockets served by Atanor's ingress. The LiveView of this guide uses the socket of Phoenix instead.
- [design.md §17.4](design.md#174-the-release-as-the-product-artifact): why the derived image is built this way.
