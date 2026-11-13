# How to deploy a worker, switch versions and roll back

**The question:** How do I put a new version of a worker on my nodes, make
them serve it, and go back if it is wrong?

This guide stands alone for the deploy itself, and builds on
[how-to-write-a-native-worker.md](how-to-write-a-native-worker.md) for the
project: it uses [examples/hello-native](../examples/hello-native). You deploy
with the `atanor` command ([reference](cli.md)), in one of two ways:

- **through a node** (the steps below): the command sends the package to a
  node's admin API with a scoped token, and the node writes the store, so you
  never hold the bucket credentials;
- **through the bucket**, with `--bucket` ([below](#deploy-through-the-bucket)):
  the command writes the store itself, for a WASM worker, and needs no node.

Either way the nodes apply the new head on their own at their next poll.

## Prerequisites

- The tools of the [README](../README.md#requirements), and a compiled worker
  project. The commands below run in `examples/hello-native`.
- The `atanor` command on your `PATH`: [cli.md](cli.md#install).
- A node with the admin API. The operator starts it, and holds the operator
  token; deployers get a scoped token (step 2). This guide runs a local node
  over the in-memory store, with admin port 4108 and the operator token
  `demo-token`.

## Concepts in two lines

A **package** is the manifest plus, for a native worker, the MD5 of the
compiled module. Its id is the SHA-256 of its bytes, so the same inputs give
the same id. A worker's **head** names the package that is active and the
previous ones. Nodes apply heads; they do not hold workers of their own.

## Steps

1. Start a node. It deploys the project's worker at start.

   ```sh
   cd examples/hello-native
   mise exec -- mix atanor.dev --port 4107 --admin-port 4108 --admin-token demo-token
   ```

   ```text
   Atanor listening on http://127.0.0.1:4107
     localhost/hello -> hello
   ```

   Leave it running and open another terminal in `examples/hello-native`.

2. The operator logs in under the profile `ops` and creates a token that may
   deploy, activate, roll back and read the worker `hello` only. `login` reads
   the token from standard input; here it comes from a pipe.

   ```sh
   echo demo-token | atanor login --url http://127.0.0.1:4108 --profile ops
   atanor token create ci-hello --profile ops --scope worker:hello:deploy \
     --scope worker:hello:activate --scope worker:hello:rollback --scope worker:hello:read
   ```

   ```text
   logged in to http://127.0.0.1:4108 (profile ops); the token is stored in ~/.config/atanor/config.json
   token atn_f1d739a58341175596fb32cb (ci-hello)
   scopes: worker:hello:deploy worker:hello:activate worker:hello:rollback worker:hello:read
   expires: never
   secret: atn_f1d739a58341175596fb32cb_<secret>
   Keep the secret now: it is not shown again.
   ```

   The deployer logs in with that secret, under the default profile:

   ```sh
   echo "atn_f1d739a58341175596fb32cb_<secret>" | atanor login --url http://127.0.0.1:4108
   ```

   ```text
   logged in to http://127.0.0.1:4108 (profile default); the token is stored in ~/.config/atanor/config.json
   ```

3. See what the node serves.

   ```sh
   atanor status
   ```

   ```text
   hello: active fa48567b0c8764bf0121aa6a9f0d7b40626820cfcccc8d9e5033aaa41e605c8f, revision 1, previous none
   ```

4. Change the worker. Here the new version also claims the path `/greet`:
   copy `atanor.json`, add `{"http": {"host": "localhost", "path": "/greet"}}`
   to `routes`, and call the copy `atanor-v2.json`. A code change works the
   same way, but see "Native code" below.

5. Build the package and upload it. This does not change what runs. The
   command builds the package here, sends it with its SHA-256, and the node
   checks both before it stores anything.

   ```sh
   atanor deploy --manifest atanor-v2.json
   ```

   ```text
   package d497f86a3e8810a9ac08e17caeff25d2f0397b950c3537fb77b8f438278197ef (hello, native, 506 bytes)
   ```

   The node still has no route for `/greet`:

   ```text
   $ curl -s -H 'Host: localhost' http://127.0.0.1:4107/greet/ann
   {"error":"not_found"}
   ```

   The command reads the module's `.beam` from `_build/$MIX_ENV/lib/*/ebin`
   (`dev` by default; `--ebin DIR` names other directories). Uploading the
   package that is already stored changes nothing.

6. List the versions. Every package uploaded for the worker is there, and any
   can be activated.

   ```sh
   atanor versions hello
   ```

   ```text
   hello: active fa48567b0c8764bf0121aa6a9f0d7b40626820cfcccc8d9e5033aaa41e605c8f, revision 1, previous none
   versions, oldest first:
     fa48567b0c8764bf0121aa6a9f0d7b40626820cfcccc8d9e5033aaa41e605c8f  active    native  460 bytes  2026-11-01T21:00:48.781349Z  by token ci-hello (atn_f1d739a58341175596fb32cb)
     d497f86a3e8810a9ac08e17caeff25d2f0397b950c3537fb77b8f438278197ef  -         native  506 bytes  2026-11-01T21:00:49.274813Z  by token ci-hello (atn_f1d739a58341175596fb32cb)
   ```

7. Activate the package. Use the id that step 5 printed. Add `--activate` to
   step 5 to do both at once.

   ```sh
   atanor activate hello d497f86a3e8810a9ac08e17caeff25d2f0397b950c3537fb77b8f438278197ef
   ```

   ```text
   hello: active d497f86a3e8810a9ac08e17caeff25d2f0397b950c3537fb77b8f438278197ef, revision 2, previous fa48567b0c8764bf0121aa6a9f0d7b40626820cfcccc8d9e5033aaa41e605c8f
   ```

   The command moves the head. Connected nodes switch at once; a node that
   missed the notice follows at its next poll (5 seconds by default, the
   `:poll_interval_ms` option). After at most that long:

   ```text
   $ curl -s -H 'Host: localhost' http://127.0.0.1:4107/greet/ann
   {"error":"try /hello/<name>"}
   ```

   A request that started before the switch finishes on the version it
   started on. `atanor status hello` also shows whether the node you asked
   applied the head:

   ```text
   hello: active d497f86a3e8810a9ac08e17caeff25d2f0397b950c3537fb77b8f438278197ef, revision 2, previous fa48567b0c8764bf0121aa6a9f0d7b40626820cfcccc8d9e5033aaa41e605c8f
   applied by nonode@nohost: d497f86a3e8810a9ac08e17caeff25d2f0397b950c3537fb77b8f438278197ef
   ```

8. Roll back.

   ```sh
   atanor rollback hello
   ```

   ```text
   hello: active fa48567b0c8764bf0121aa6a9f0d7b40626820cfcccc8d9e5033aaa41e605c8f, revision 3, previous none
   ```

   After the nodes switch `/greet/ann` is `not_found` again and `/hello/ann` still
   works. Rolling back again goes one version further, until there is none:
   `atanor: the worker has no previous package to return to`. The head keeps
   the last 20 previous versions.

9. Stop the node with `Ctrl+C` twice. `atanor logout --profile ops` removes the
   operator's token from your machine; `atanor token revoke atn_f1d7...` ends a
   token for good ([cli.md](cli.md#atanor-token-revoke-token_id)).

## In CI

Give the job a token with only the scopes it needs, and no config file:

```sh
export ATANOR_URL=https://admin.example.com ATANOR_TOKEN="$DEPLOY_TOKEN"
atanor deploy --activate
```

A token without the scope gets a clean error and nothing changes:

```text
atanor: forbidden: this token needs the scope worker:hello:deploy
```

Every upload, activation, rollback and token change is in the audit log
(`GET /audit`, [how-to-use-the-admin-api.md](how-to-use-the-admin-api.md)).

## Deploy through the bucket

If your CI or your laptop has write access to the bucket, `deploy` needs no
node and no token. This is the one-line deploy of a cluster started from the
[image](how-to-build-the-release.md): the nodes find the head in the bucket.
It works for WASM workers only ([why](#troubleshooting)). This section uses
[examples/scoreboard](../examples/scoreboard), which `mise run build:scoreboard`
builds into `scoreboard.wasm`.

1. Give the command the bucket and the credentials, as you give them to a node
   ([configuration.md](configuration.md#the-daemon-environment-and-file)): the
   endpoint, the region and the AWS chain (`AWS_ACCESS_KEY_ID` and
   `AWS_SECRET_ACCESS_KEY`, a profile, a web identity, container credentials
   or EC2 metadata). The bucket and the prefix must be the nodes' `ATANOR_STORE`.
   Here they are for a local SeaweedFS and a node started with
   `mix atanor.dev --port 4107 --store seaweedfs --bucket atanor-demo --prefix demo`:

   ```sh
   export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... ATANOR_S3_ENDPOINT=http://127.0.0.1:18343
   ```

2. Deploy and activate.

   ```sh
   cd examples/scoreboard
   atanor deploy --bucket s3://atanor-demo/demo --activate
   ```

   ```text
   package 55c8cdbc30d325d5628e54486c7ddb7bf3528f6355afe153817dafefb7f4061f (scoreboard, wasm, 117888 bytes)
   scoreboard: active 55c8cdbc30d325d5628e54486c7ddb7bf3528f6355afe153817dafefb7f4061f, revision 1, previous none
   stored in s3://atanor-demo/demo; the nodes apply it at their next poll
   ```

   Without `--activate` the package is stored and no head moves.

3. Wait for the nodes. Every node polls the heads (`:poll_interval_ms`, 5
   seconds by default), so after at most that long each one serves the worker:

   ```text
   $ curl -s -H 'Host: scoreboard.localhost' http://127.0.0.1:4107/rooms/demo
   {"room":"demo","writes":0,"last_seq":0,"ranked_through":0,"rankings":[]}
   ```

   `atanor versions`, `activate`, `rollback` and `status` go through a node:
   they need the admin API and a token (steps 2 and 3 above). A second
   `deploy --bucket --activate` of changed code moves the head again, and a
   rollback is `atanor rollback`. Nothing else tells the nodes: a node that is
   down applies the head when it starts.

`--bucket` cannot be combined with `--url`, `--profile` or `--timeout`
(`atanor: --bucket writes the store directly and --profile is for the admin API
of a node: give one or the other`). `ATANOR_URL`, `ATANOR_TOKEN` and
`ATANOR_PROFILE` are ignored with it.

### From the image

The release image holds the same command, so a machine with Docker and no
Erlang can deploy. The image starts the node with no argument and runs the
command for `deploy` (and `status`, `activate`, ...). Mount the project and
give the credentials by files:

```sh
docker run --rm -v "$PWD:/w:ro" -v "$HOME/.secrets/atanor:/run/secrets:ro" \
  -e ATANOR_S3_ENDPOINT=https://s3.example.com \
  -e AWS_ACCESS_KEY_ID_FILE=/run/secrets/access_key \
  -e AWS_SECRET_ACCESS_KEY_FILE=/run/secrets/secret_key \
  ghcr.io/this-is-npc/atanor deploy /w --bucket s3://my-bucket --activate
```

It needs no cookie and no advertise address, because it starts no node. The
command runs as the user `atanor` (uid 10001): the mounted directory must be
readable by it. `mise run image:smoke` runs exactly this against SeaweedFS and
checks that a node then serves the worker.

## Native code

A native package holds the MD5 of the module's compiled code, and a node
applies it only if its loaded module has the same MD5. To ship new native
code: build the release, roll the nodes to it, then deploy and activate. A
node that still runs the old code keeps the previous version serving and
reports the problem in `Atanor.Deployments.status/1`, for example
`{:code_mismatch, "<package md5>", "<loaded md5>"}`.

## Node releases

Atanor does not restart nodes. Give each build an immutable `release: [id:
...]` (an image digest or commit; the `"atanor-" <> version` default is for
development) and use `GET /deployments` to see which build
each node runs. A native deployment needs its module in the release, so roll
the nodes first and move worker heads afterwards. Restart the nodes one at a
time: a node joins the cluster only after it applied the active workers, and
`GET /health/ready` on its admin port answers 503 until it serves and 200 after
([how-to-use-the-admin-api.md](how-to-use-the-admin-api.md), step 2). Wait for
the 200 before you stop the next node. Crash reports name the
release that ran
([how-to-diagnose-a-crash.md](how-to-diagnose-a-crash.md)).

## Which routes become active

The manifest only declares routes. The operator decides, per node, in
`{Atanor, opts}`:

- `hosts: %{"hello" => ["localhost", "*.example.com"]}` lists the hosts each
  worker may claim; `*.example.com` covers subdomains, not `example.com`,
  and `"*"` allows every host, which a catch-all route (`"host": "*"`) needs.
  Without the option every host is allowed, which trusts the packages.
- `listeners: %{"smtp" => 2525}` maps the TCP listener names in manifests
  to ports. The long form adds `tls_mode:`/`tls:`, `protocol: :ranch` and `ip:`
  (the address to bind, the ingress `ip` by default); a
  manifest route and its listener must agree on the protocol
  ([how-to-serve-tcp.md](how-to-serve-tcp.md)).

## Troubleshooting

- **`not logged in (profile default)`** Run `atanor login --url URL`, or set
  `ATANOR_URL` and `ATANOR_TOKEN`.
- **`the server did not accept the token`** The token is wrong, expired or
  revoked. Ask the operator for a new one.
- **`forbidden: this token needs the scope ...`** The token lacks that scope;
  `--activate` needs the `activate` scope as well as `deploy`.
- **`cannot build the package: Elixir.Hello.Worker.beam not found`** The project
  is not compiled for the build the command reads (`MIX_ENV`, `dev` by
  default), or `module` is misspelled. Run `mix compile` in the worker's
  project, or pass `--ebin DIR`.
- **`invalid manifest at manifest_version: is required`** Add
  `"manifest_version": 1`.
- **`the package is for the worker X, not the one named`** The uploaded
  package belongs to another worker.
- **`the package is larger than the server accepts`** The node's `admin`
  option `max_package_bytes` (64 MiB by default) is lower than the package.
- **`no answer from URL in time`** Raise `--timeout` (or `ATANOR_TIMEOUT`,
  `ATANOR_UPLOAD_TIMEOUT` for uploads) on a slow link.
- **Nothing changes on the node after `activate`.** Wait one poll interval.
  Then look at `Atanor.Deployments.status(MyApp.Atanor)` on the node: `error`
  holds the reason (`:code_mismatch`, `{:host_not_allowed, host, worker}`,
  `{:listener_not_configured, name}`, `{:route_taken, ...}`). The previous
  version keeps serving until the head changes again.
- **`activate` or `upload --activate` is refused (409 or 422).** The node checks
  the package before it writes the head, so nothing changed. `namespace_owned`:
  another worker owns a namespace the package declares. `namespace_not_allowed`,
  `http_not_allowed`, `module_not_allowed`, `host_not_allowed`,
  `listener_not_allowed`: the operator's options do not allow it.
  `module_not_loaded`: the node's release has no such module; roll the nodes to
  the release first. `invalid_package` with a size: `atanor.json` or the WASM
  component is over `package: [max_manifest_bytes:, max_component_bytes:]`
  (262,144 and 8,388,608 bytes by default). The `subject` of the answer names
  what was refused. See [design §3.3](design.md#33-what-a-manifest-may-grant).
- **`--bucket deploys WASM workers only: ... is native`** A native package
  holds the MD5 of a module that has to be in the node's release. Through a node
  the node checks that (`module_not_loaded`); with the bucket nobody can, and a
  head could name a package no node can apply, so the command refuses. Roll the
  nodes to a release that has the module, then deploy through a node with
  `--url` or a profile.
- **`--bucket: must be s3://bucket or s3://bucket/prefix`** Give the URL of the
  store as the nodes' `ATANOR_STORE` reads it, with no port, query or user.
- **`no AWS credentials: ...`** or **`cannot get the AWS credentials`** The
  command found no source of the chain or the source failed; see the AWS
  variables in [configuration.md](configuration.md#the-daemon-environment-and-file).
- **The command succeeded but the nodes do not serve the worker.** The bucket
  or the prefix differs from the nodes' `ATANOR_STORE`. Compare them, then
  `atanor status WORKER` against a node.
- **`other changes moved the head at the same time`** Sixteen attempts lost the
  race against other changes of the same head. Run the command again.

## Next steps

- [how-to-run-a-migration-rehearsal.md](how-to-run-a-migration-rehearsal.md):
  apply the new migrations to copies of real cells between steps 4 and 5.
- [cli.md](cli.md): every command, option and environment variable.
- [design.md](design.md#5-deployments-and-the-store-layout): package format,
  heads, propagation and guarantee D1.
