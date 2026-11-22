# How to deploy a worker, switch versions and roll back

**The question:** How do I put a new version of a worker on my nodes, make
them serve it, and go back if it is wrong?

This guide stands alone for the deploy itself, and builds on
[how-to-run-a-node-locally.md](how-to-run-a-node-locally.md) for its node and
its example worker. You deploy with the `atanor` command ([reference](cli.md)),
in one of two ways:

- **through a node** (the steps below): the command sends the package to a
  node's admin API with a scoped token, and the node writes the store, so you
  never hold the bucket credentials;
- **through the bucket**, with `--bucket` ([below](#deploy-through-the-bucket)):
  the command writes the store itself, for a WASM worker, and needs no node.

Either way the nodes apply the new head on their own at their next poll.

## Prerequisites

- The `atanor` command on your `PATH`: [cli.md](cli.md#install).
- The node and the `atanor-hello` directory of the
  [local node guide](how-to-run-a-node-locally.md), steps 1 to 6. The node serves
  the worker `hello` on port 4000, and its admin API listens on
  `http://127.0.0.1:4001`. Its operator token is in `atanor-secrets/admin_token`.

## Concepts in two lines

A **package** is the manifest plus the compiled WASM component, or for a native
worker the MD5 of the compiled module. Its id is the SHA-256 of its bytes, so the same inputs give
the same id. A worker's **head** names the package that is active and the
previous ones. Nodes apply heads; they do not hold workers of their own.

## Steps

1. The operator logs in under the profile `ops` and creates a token that may
   deploy, activate, roll back and read the worker `hello` only. `login` reads
   the token from standard input; here it comes from a file. Run this in the
   `atanor-hello` directory of the local guide.

   ```sh
   cat ../atanor-secrets/admin_token | atanor login --url http://127.0.0.1:4001 --profile ops
   atanor token create ci-hello --profile ops --scope worker:hello:deploy \
     --scope worker:hello:activate --scope worker:hello:rollback --scope worker:hello:read
   ```

   ```text
   logged in to http://127.0.0.1:4001 (profile ops); the token is stored in ~/.config/atanor/config.json
   token atn_f1d739a58341175596fb32cb (ci-hello)
   scopes: worker:hello:deploy worker:hello:activate worker:hello:rollback worker:hello:read
   expires: never
   secret: atn_f1d739a58341175596fb32cb_<secret>
   Keep the secret now: it is not shown again.
   ```

   The deployer logs in with that secret, under the default profile:

   ```sh
   echo "atn_f1d739a58341175596fb32cb_<secret>" | atanor login --url http://127.0.0.1:4001
   ```

   ```text
   logged in to http://127.0.0.1:4001 (profile default); the token is stored in ~/.config/atanor/config.json
   ```

   Only the `ops` profile and `atanor token` need the operator token. Every
   command below runs under the default profile, with the deployer's token.

2. See what the node serves, as the deployer.

   ```sh
   atanor status
   ```

   ```text
   hello: active 6f30c05f11f17db48d1819431b7ff92087d4343f9f248c5ae35d04d5c62a3c77, revision 1, previous none
   ```

3. Change the worker. Here the new version also claims the path `/greet`. Copy
   the manifest and call the copy `atanor-v2.json`, in the same directory, so
   that it reads the same `hello.wasm`:

   ```sh
   cp atanor.json atanor-v2.json
   ```

   Then add `{"http": {"host": "localhost", "path": "/greet"}}` to its `routes`:

   ```json
   {
     "manifest_version": 1,
     "name": "hello",
     "kind": "wasm",
     "component": "hello.wasm",
     "routes": [{"http": {"host": "localhost", "path": "/hello"}}, {"http": {"host": "localhost", "path": "/greet"}}]
   }
   ```

   A code change works the same way: rebuild the component, then deploy it
   with the same manifest. A native worker is different: see [Native code](#native-code).

4. Build the package and upload it. This does not change what runs. The
   command builds the package here, sends it with its SHA-256, and the node
   checks both before it stores anything.

   ```sh
   atanor deploy --manifest atanor-v2.json
   ```

   ```text
   package <v2 package id> (hello, wasm, <bytes> bytes)
   ```

   The node still has no route for `/greet`:

   ```text
   $ curl -s -H 'Host: localhost' http://127.0.0.1:4000/greet/ann
   {"error":"not_found"}
   ```

   The command reads a WASM component from the manifest's directory. Uploading
   the package that is already stored changes nothing.

5. List the versions. Every package uploaded for the worker is there, and any
   can be activated.

   ```sh
   atanor versions hello
   ```

   ```text
   hello: active 6f30c05f11f17db48d1819431b7ff92087d4343f9f248c5ae35d04d5c62a3c77, revision 1, previous none
   versions, oldest first:
     6f30c05f11f17db48d1819431b7ff92087d4343f9f248c5ae35d04d5c62a3c77  active    wasm  181410 bytes  <upload time>  by token ci-hello (atn_f1d739a58341175596fb32cb)
     <v2 package id>  -         wasm  <bytes> bytes  <upload time>  by token ci-hello (atn_f1d739a58341175596fb32cb)
   ```

6. Activate the package. Use the id that step 4 printed. Add `--activate` to
   step 4 to do both at once.

   ```sh
   atanor activate hello <v2 package id>
   ```

   ```text
   hello: active <v2 package id>, revision 2, previous 6f30c05f11f17db48d1819431b7ff92087d4343f9f248c5ae35d04d5c62a3c77
   ```

   The command moves the head. Connected nodes switch at once; a node that
   missed the notice follows at its next poll (5 seconds by default). After at
   most that long, the node serves `/greet` from the new version. A request that started before the switch finishes on the version it
   started on. `atanor status hello` also shows whether the node you asked
   applied the head:

   ```text
   hello: active <v2 package id>, revision 2, previous 6f30c05f11f17db48d1819431b7ff92087d4343f9f248c5ae35d04d5c62a3c77
   applied by atanor@atanor-node.local: <v2 package id>
   ```

7. Roll back.

   ```sh
   atanor rollback hello
   ```

   ```text
   hello: active 6f30c05f11f17db48d1819431b7ff92087d4343f9f248c5ae35d04d5c62a3c77, revision 3, previous none
   ```

   After the nodes switch `/greet/ann` is `not_found` again and `/hello/ann` still
   works. Rolling back again goes one version further, until there is none:
   `atanor: the worker has no previous package to return to`. The head keeps
   the last 20 previous versions.

8. Remove the token. `atanor logout --profile ops` removes the operator's
   token from your machine; `atanor token revoke atn_f1d7...` ends a token for
   good ([cli.md](cli.md#atanor-token-revoke-token_id)). To stop the node, clean
   up as the local guide does, in its step 7.

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
[image](how-to-run-a-node-locally.md): the nodes find the head in the bucket.
It works for WASM workers only ([why](#troubleshooting)). This section uses the
`atanor-hello` directory of the local guide.

1. Give the command the bucket and the credentials, as you give them to a node
   ([configuration.md](configuration.md#the-daemon-environment-and-file)): the
   endpoint, the region and the AWS chain (`AWS_ACCESS_KEY_ID` and
   `AWS_SECRET_ACCESS_KEY`, a profile, a web identity, container credentials
   or EC2 metadata). The bucket and the prefix must be the nodes' `ATANOR_STORE`.
   Here they are for the local SeaweedFS of the local guide, whose bucket is
   `atanor` (`s3://atanor`, prefix `atanor`). Run them in the `atanor-hello`
   directory, where the secrets are one level up:

   ```sh
   export AWS_ACCESS_KEY_ID=$(cat ../atanor-secrets/access_key) \
     AWS_SECRET_ACCESS_KEY=$(cat ../atanor-secrets/secret_key) \
     ATANOR_S3_ENDPOINT=http://127.0.0.1:8333
   ```

2. Deploy and activate. The package is the same as in step 5 of the local guide,
   so the command stores the same bytes; the head moves to it again.

   ```sh
   atanor deploy --bucket s3://atanor --activate
   ```

   ```text
   package 6f30c05f11f17db48d1819431b7ff92087d4343f9f248c5ae35d04d5c62a3c77 (hello, wasm, 181410 bytes)
   hello: active 6f30c05f11f17db48d1819431b7ff92087d4343f9f248c5ae35d04d5c62a3c77, revision 1, previous none
   stored in s3://atanor; the nodes apply it at their next poll
   ```

   Without `--activate` the package is stored and no head moves.

3. Wait for the nodes. Every node polls the heads (every 5 seconds by default),
   so after at most that long each one serves the worker:

   ```text
   $ curl -s -H 'Host: localhost' http://127.0.0.1:4000/hello/world
   hello GET /hello/world? authority=localhost body=
   ```

   `atanor versions`, `activate`, `rollback` and `status` go through a node:
   they need the admin API and a token (step 1 above). A second
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
give the credentials by files. The published image pulls without a login. For your own build
([README](../README.md#install)), use `atanor:local` in place of `ghcr.io/this-is-npc/atanor`:

```sh
docker run --rm -v "$PWD:/w:ro" -v "$HOME/.secrets/atanor:/run/secrets:ro" \
  -e ATANOR_S3_ENDPOINT=https://s3.example.com \
  -e AWS_ACCESS_KEY_ID_FILE=/run/secrets/access_key \
  -e AWS_SECRET_ACCESS_KEY_FILE=/run/secrets/secret_key \
  ghcr.io/this-is-npc/atanor deploy /w --bucket s3://my-bucket --activate
```

It needs no cookie and no advertise address, because it starts no node. The
command runs as the user `atanor` (uid 10001): the mounted directory must be
readable by it.

## Native code

A native package holds the MD5 of the module's compiled code, and a node
applies it only if its loaded module has the same MD5. To ship new native
code: build a [derived image](how-to-build-a-derived-image.md) that holds the
new module, roll the nodes to it, then deploy and activate with `--url` or a
profile. A node that still runs the old code keeps the previous version serving and
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

The manifest only declares routes. The operator decides, per node. In the
release, the environment variables do it; in a derived image, the options of
`{Atanor, opts}` do:

- `ATANOR_HOSTS` (`hosts:`) lists the hosts each worker may claim, as
  `hello=localhost,*.example.com`. `*.example.com` covers subdomains, not
  `example.com`, and `*` allows every host, which a catch-all route
  (`"host": "*"`) needs. Without the variable every host is allowed, which
  trusts the packages.
- `listeners: %{"smtp" => 2525}` (derived image only) maps the TCP listener names in manifests
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
- **`cannot build the package: Elixir.Hello.Worker.beam not found`** (native
  workers) The module is not compiled for the build the command reads
  (`MIX_ENV`, `dev` by default), or `module` is misspelled. Compile the worker's
  project with `mix compile`, or pass `--ebin DIR`.
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
