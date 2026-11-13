# How to build a derived image

**The question:** How do I run my own Elixir code, a Phoenix and LiveView app
included, in the same VM as an Atanor node, as a container image, and deploy a
native worker to it?

This guide stands alone for someone with an Elixir project and Docker. It uses
[examples/live-counter](../examples/live-counter): a LiveView page and a native
worker in one release with the node. [cluster/load](../cluster/load) is a
second, smaller consumer of the same files.

## What you get

A derived image is a Mix release of **your** app that has Atanor as a
dependency. Your supervision tree starts the node first, then your own processes
(the Phoenix endpoint here), so your code and Atanor share one VM: your code can
call a worker, and a native worker can call your modules, with no network between them.

The release is named `atanor`, so the image is laid out like the
[product image](how-to-build-the-release.md): the same entry point, the same
start script, the same environment variables
([configuration.md](configuration.md#the-daemon-environment-and-file)) and the
same `atanor deploy` command. `mix atanor.release` writes the files that make
that so.

This is the way to run Elixir code, Phoenix and LiveView included, with Atanor.
Adding Atanor to the supervision tree of an app that you release your own way
is not a supported way to install it.

## Prerequisites

- An Elixir 1.17 or later project with a Mix release (the example is one).
- Docker with BuildKit (Docker 23 or later). Elixir, Erlang and Rust are in the
  build stage; the first build compiles the Rust crates of Atanor and Alambique
  and takes several minutes ([what it costs](#what-it-costs)).
- To run the check at the end: `mise install`, plus `curl`, `openssl` and `python3` on the host.

## Steps

1. Add Atanor to `mix.exs`, and name the release `atanor`. In your app use a
   release tag; the example uses a path because it lives in this repository:

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
       {:atanor, git: "https://github.com/This-Is-NPC/atanor.git", tag: "v0.3.0"},
       {:phoenix, "~> 1.8"},
       {:phoenix_live_view, "~> 1.2"}
     ]
   end
   ```

   Run `mix deps.get`. Alambique comes with Atanor: do not declare it.

2. Start the node in your supervision tree, before your own processes
   ([lib/live_counter/application.ex](../examples/live-counter/lib/live_counter/application.ex)):

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
   [how-to-write-a-native-worker.md](how-to-write-a-native-worker.md)
   ([worker.ex](../examples/live-counter/lib/live_counter/worker.ex),
   [atanor.json](../examples/live-counter/atanor.json)). The page reaches it in the same VM
   by running the active deployment as the ingress does:

   ```elixir
   {:ok, deployment} = Atanor.Registry.deployment(Atanor.Daemon.instance(), "counter")
   Atanor.Workers.invoke(Atanor.Env.new(Atanor.Daemon.instance(), deployment), %Atanor.Request{path: "/counter"})
   ```

   Atanor has no shorter public call for this yet, and the manifest `callable_by` rules do not apply to it.

4. Write what your app needs at run time. Do not name a variable `ATANOR_*`
   unless it is one of the daemon's: the daemon refuses an unknown one. The
   example reads `PORT` and `SECRET_KEY_BASE` in
   [config/runtime.exs](../examples/live-counter/config/runtime.exs).

5. Write the release files and the Dockerfile:

   ```sh
   cd examples/live-counter
   mix atanor.release
   ```

   ```text
   wrote      rel/env.sh.eex
   wrote      rel/overlays/bin/atanor-entrypoint
   wrote      Dockerfile
   wrote      Dockerfile.dockerignore

   Build the image, from this directory, with `../..` as the context:
     docker build -f Dockerfile -t my-app ../..
   ```

   The two `rel/` files are copies of the product's (`daemon/rel`); the
   Dockerfile builds the release on the same Elixir, Rust and Debian bases as the
   product image, compiles the Rust crates, and runs it as the user `atanor`
   (uid 10001). Commit them. The task leaves a file that differs from what it
   would write; `--force` replaces it. Rerun it after you update Atanor.
   In a project with Atanor in `deps/` the build context is the project
   directory and the command is `docker build -t my-app .`. `-f` is resolved from the
   directory where you run the command, so run the printed command from the project directory. The build argument
   `EXTRA_PACKAGES` adds Debian packages (for example `curl`), `RELEASE_ID`
   sets the id the node reports ([design 17.1](design.md#171-release-identity)).

6. Build the image, from the same directory (`examples/live-counter`):

   ```sh
   docker build -f Dockerfile -t live-counter ../..
   ```

7. Start it. The node needs the same environment as the product image
   ([how-to-build-the-release.md](how-to-build-the-release.md#build-the-image)),
   and the app its own variables; `<...>` marks a value you choose:

   ```sh
   docker run -d --name live-counter -p 4000:4000 -p 4001:4001 -p 4010:4010 \
     -v <secrets dir>:/run/secrets:ro \
     -e ATANOR_STORE=s3://<bucket>/<prefix> -e ATANOR_S3_ENDPOINT=<S3 endpoint URL> \
     -e AWS_ACCESS_KEY_ID_FILE=/run/secrets/access_key \
     -e AWS_SECRET_ACCESS_KEY_FILE=/run/secrets/secret_key \
     -e ATANOR_ADMIN_TOKEN_FILE=/run/secrets/admin_token \
     -e ATANOR_ADVERTISE=<host or IP with a dot, such as node-1.example> \
     -e ATANOR_COOKIE_FILE=/run/secrets/cookie \
     -e SECRET_KEY_BASE=<64 or more random bytes, hex> \
     live-counter
   ```

   Port 4000 is Atanor's ingress, 4001 its admin API and 4010 the Phoenix
   endpoint. The page answers on 4010 at once; it says the worker is not
   deployed yet.

8. Deploy the native worker **through the node**. A native package holds the MD5
   of its module, which only a node can check against the code it runs, so
   `--bucket` refuses it. Use `--url` (or a profile) and a token, after the
   nodes run the new image. The image holds the command and the compiled
   module, so mount only the directory with `atanor.json`:

   ```sh
   docker run --rm --network container:live-counter -v "$PWD:/w:ro" \
     -e ATANOR_URL=http://127.0.0.1:4001 -e ATANOR_TOKEN="$(cat <secrets dir>/admin_token)" \
     live-counter deploy /w --ebin /opt/atanor/lib/live_counter-0.1.0/ebin --activate
   ```

   The `deploy` command takes about 15 s to start (it runs in a BEAM `eval`); the 0.4 s of
   [What it costs](#what-it-costs) starts after it ends. The route of
   [atanor.json](../examples/live-counter/atanor.json) is the host `counter.localhost` and the path
   `/counter`, so call it on port 4000 with that host:

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

## Check the image

`mise run image:derived-smoke` runs these steps against a disposable
SeaweedFS (everything is named `atanor-smoke-derived-*` and removed at the end).
It checks that the node is ready, that the page answers 200, that the worker
deployed with `--url` is served by the ingress, that a LiveView mounted over a
WebSocket shows the count the worker serves and renders the next one after a
click ([scripts/liveview-click](../scripts/liveview-click)), and that one VM runs
`atanor`, `phoenix`, `phoenix_live_view` and the app.

```text
built the derived image in 275.3 s
size  derived image: 54.5 MB (54521254 bytes)
ok    the node of the derived image was ready on /health/ready in 38.8 s (docker run to HTTP 200)
ok    the LiveView page answered 200 on port 4010 and said the counter worker is not deployed yet
ok    deploy --url activated the native worker counter 4157af28333a17fef0d8092b9a89c2ddb27f2fee50f185b8dca7aad267146ce9; the ingress served {"count":0} 0.4 s later
ok    a POST to the worker on the ingress (port 4000) shows on the page (port 4010): the page read the cell through the worker
ok    LiveView: page count 1, mounted over a WebSocket, a click rendered 2
ok    the click reached the cell: the worker now serves {"count":2}
ok    one VM runs: atanor phoenix phoenix_live_view live_counter on atanor@node-1.smoke
derived-image-smoke: passed
```

`ATANOR_SMOKE_REUSE=1` skips the build and uses the image of the last run.

## What it costs

Measured on the VM of the project (4 vCPU, about 6 GB, Docker 29.7, linux/amd64) for `examples/live-counter`:

| What | Result |
| --- | --- |
| Image size | 54.5 MB (54 521 254 bytes), about the size of the product image (55.0 MB): Phoenix and LiveView were already in it for the dashboard |
| `docker build`, first build of the clone | 405 s |
| The same after a change to one file of the app, with the Cargo cache kept | 275 s |
| `docker run` to HTTP 200 on `/health/ready`, SeaweedFS already up | 33.3 s, 38.8 s and 45.0 s (three runs) |
| Deploy of the native worker (`deploy --url ... --activate`) to the first request served | 0.4 s |

The times are of one machine under no other load of ours. The Dockerfile copies the whole project before
it fetches the dependencies, so any change reruns `mix deps.get` and the Elixir compile of the dependencies;
its cache mounts keep Cargo's registry and the `target` directories of the two Rust crates between builds, which is why the second
build is shorter. The arm64 image is not measured.

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
  not there. Skip what only the running app needs when `System.get_env("RELEASE_COMMAND") == "eval"`,
  as the example does.
- **`bin/atanor rpc` or `remote` says `noconnection`.** The node is named
  `atanor@<ATANOR_ADVERTISE>`, and the machine that connects must resolve that name. Inside the
  container the name has to resolve to the container itself: in the smoke test the container has the
  network alias `node-1.smoke`, its advertise address.
- **The build stops while fetching a dependency.** `mix deps.get` runs in the
  build stage, with the `mix.lock` of your app: commit it. With a path
  dependency the context must hold the dependency: use the command
  `mix atanor.release` printed.
- **The Rust build runs out of memory.** Pass fewer jobs:
  `docker build --build-arg CARGO_BUILD_JOBS=2 ...`.
- **`deploy` answers `module_not_loaded` or `code_mismatch`.** The node runs an
  older image than the package. Roll the node to the image the module comes from
  (`--ebin` must name that release's directory), then deploy again.
- **The page says the counter worker is not deployed.** Deploy it (step 8).
- **The LiveView page loads but never connects.** `check_origin` of the endpoint
  refuses the host name you use. The example turns it off; set it for yours.

## Next steps

- [how-to-deploy-a-worker.md](how-to-deploy-a-worker.md): scoped tokens, rollbacks and rollouts of native code.
- [how-to-run-a-cluster-in-containers.md](how-to-run-a-cluster-in-containers.md): several nodes of an image over one store.
- [how-to-use-websockets.md](how-to-use-websockets.md): sockets served by Atanor's ingress, which the Phoenix socket of this guide does not use.
- [design.md §17.4](design.md#174-the-release-as-the-product-artifact): why the derived image is built this way.
