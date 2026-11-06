# The `atanor` command

`atanor` is a client of the [admin API](how-to-use-the-admin-api.md). It logs in
to a node, builds and uploads worker packages, moves heads and manages scoped
tokens. It never holds bucket credentials: only nodes write the store. The API
it calls is described in [openapi/admin.json](openapi/admin.json). For a walk
through, see [how-to-deploy-a-worker.md](how-to-deploy-a-worker.md).

## Install

`atanor` is an escript: one file that needs the Erlang it was built with (the version pinned in `mise.toml`) to run.
Build it in a checkout and put it on your `PATH`:

```sh
mise run build:cli
install -m 755 _build/cli/atanor ~/.local/bin/atanor
atanor --version
```

```text
atanor 0.1.0
```

## Profiles and the config file

`atanor login` stores the admin URL and the token of a profile in
`$XDG_CONFIG_HOME/atanor/config.json` (`~/.config/atanor/config.json` when the
variable is unset). The file has mode 0600 in a directory with mode 0700, is
replaced atomically, and the command never prints the token back.

```json
{
  "profiles": {
    "default": {"token": "atn_...", "url": "http://127.0.0.1:5010"},
    "ops": {"token": "...", "url": "https://admin.example.com"}
  }
}
```

The profile is `--profile NAME`, else `ATANOR_PROFILE`, else `default`. For CI,
give `ATANOR_URL` and `ATANOR_TOKEN` and no file is read or written.

## Commands

Options go after the command; `--profile` and `--timeout` may also come before
it. Exit codes: 0 done, 1 failed (the message is on standard error), 2 wrong
usage. `atanor help COMMAND` prints the same options as this page.

### atanor login --url URL

Checks the token against the node (`GET /heads`) and stores it in the profile.
The token comes from `ATANOR_TOKEN` or, without it, one line on standard input
(typed input is not hidden; pipe it from a secret store instead). A token the
node refuses is not stored. A plain `http://` URL to a host other than
loopback is refused before the token is sent, because it would cross the
network in clear; `--insecure` allows it and prints a warning.

| Option | Meaning |
| --- | --- |
| `--url URL` | The admin API URL, for example `http://127.0.0.1:5010` (or `ATANOR_URL`). |
| `--insecure` | Send the token over plain http to a host that is not loopback. |

```text
$ echo "$TOKEN" | atanor login --url http://127.0.0.1:5010
logged in to http://127.0.0.1:5010 (profile default); the token is stored in ~/.config/atanor/config.json
```

### atanor logout

Removes the profile from this machine. It does not revoke the token; use
`atanor token revoke` for that.

### atanor deploy

Reads the manifest, builds the package in this machine, computes its SHA-256
and uploads it. Needs the `deploy` scope of the worker, and `activate` too with
`--activate`. A native package holds the MD5 of the compiled module, which
`deploy` reads from the project's `.beam` file, so compile the project first.

| Option | Meaning |
| --- | --- |
| `--manifest FILE` | The manifest (default `atanor.json`). A WASM component is read from the manifest's directory. |
| `--activate` | Also make the package the active one. |
| `--ebin DIR` | A directory with compiled modules; repeatable (default `_build/$MIX_ENV/lib/*/ebin`, with `MIX_ENV` `dev` when unset). |

```text
$ atanor deploy --activate
package fa48567b0c8764bf0121aa6a9f0d7b40626820cfcccc8d9e5033aaa41e605c8f (hello, native, 460 bytes)
hello: active fa48567b0c8764bf0121aa6a9f0d7b40626820cfcccc8d9e5033aaa41e605c8f, revision 1, previous none
```

### atanor activate WORKER PACKAGE_ID

Makes an uploaded package the active one. Needs `activate`. Nodes follow within
their poll interval.

```text
$ atanor activate hello d497f86a3e8810a9ac08e17caeff25d2f0397b950c3537fb77b8f438278197ef
hello: active d497f86a3e8810a9ac08e17caeff25d2f0397b950c3537fb77b8f438278197ef, revision 2, previous fa48567b0c8764bf0121aa6a9f0d7b40626820cfcccc8d9e5033aaa41e605c8f
```

### atanor rollback WORKER

Returns the worker to the package that was active before. Needs `rollback`.
Repeating it goes one package further back, until there is none:

```text
$ atanor rollback hello
hello: active fa48567b0c8764bf0121aa6a9f0d7b40626820cfcccc8d9e5033aaa41e605c8f, revision 3, previous none
$ atanor rollback hello
atanor: the worker has no previous package to return to
```

### atanor status [WORKER]

Without a worker: the head of every worker the token may read. With one: its
head, the package the answering node applied, and the error if it could not
apply it. Needs `read`.

```text
$ atanor status hello
hello: active d497f86a3e8810a9ac08e17caeff25d2f0397b950c3537fb77b8f438278197ef, revision 2, previous fa48567b0c8764bf0121aa6a9f0d7b40626820cfcccc8d9e5033aaa41e605c8f
applied by nonode@nohost: d497f86a3e8810a9ac08e17caeff25d2f0397b950c3537fb77b8f438278197ef
```

### atanor versions WORKER

Lists the packages uploaded for the worker, oldest first, with the state
(`active`, `previous` or `-`), kind, size, upload time and who uploaded it. Any
of them can be activated. Needs `read`.

| Option | Meaning |
| --- | --- |
| `--limit N` | Versions per page (the node's `default_limit` when omitted). |
| `--after CURSOR` | Continue after the cursor the previous page printed as `more:`. |

```text
$ atanor versions hello
hello: active fa48567b0c8764bf0121aa6a9f0d7b40626820cfcccc8d9e5033aaa41e605c8f, revision 1, previous none
versions, oldest first:
  fa48567b0c8764bf0121aa6a9f0d7b40626820cfcccc8d9e5033aaa41e605c8f  active    native  460 bytes  2026-11-01T20:59:01.810542Z  by token ci-hello (atn_9d07e7f2c249e1dc21a5435d)
  d497f86a3e8810a9ac08e17caeff25d2f0397b950c3537fb77b8f438278197ef  -         native  506 bytes  2026-11-01T20:59:08.731543Z  by token ci-hello (atn_9d07e7f2c249e1dc21a5435d)
```

### atanor token create NAME --scope SCOPE

Creates a scoped token and prints its secret once. Needs `cluster:admin`. A
scope is `cluster:admin` or `worker:<name|*>:<deploy|activate|rollback|read>`.

| Option | Meaning |
| --- | --- |
| `--scope SCOPE` | A scope of the token; repeatable, at least one. |
| `--description TEXT` | What the token is for. |
| `--expires-at TIME` | When the token stops working, ISO 8601 with an offset, in the future. |

```text
$ atanor token create ci-hello --profile ops --scope worker:hello:deploy --scope worker:hello:read
token atn_9d07e7f2c249e1dc21a5435d (ci-hello)
scopes: worker:hello:deploy worker:hello:read
expires: never
secret: atn_9d07e7f2c249e1dc21a5435d_<secret>
Keep the secret now: it is not shown again.
```

### atanor token list

Lists the tokens (never their secrets). Needs `cluster:admin`. Takes `--limit N`
and `--after CURSOR` like `versions`.

### atanor token revoke TOKEN_ID

Revokes a token; every node refuses it from its next request. Needs
`cluster:admin`.

### atanor help [COMMAND] and atanor version

`help` lists the commands, or the options of one. `version` (or `--version`)
prints the version.

## Options of every command

| Option | Meaning |
| --- | --- |
| `--profile NAME` | The profile to use (default `default`, or `ATANOR_PROFILE`). |
| `--timeout SECONDS` | Seconds to wait for an answer; replaces `ATANOR_TIMEOUT` and `ATANOR_UPLOAD_TIMEOUT`. |
| `--help` | Show the help of the command. |

## Environment variables

| Variable | Meaning | Default |
| --- | --- | --- |
| `ATANOR_PROFILE` | The profile when `--profile` is not given. | `default` |
| `ATANOR_URL` | The admin API URL; replaces the profile's. A URL other than the profile's needs `ATANOR_TOKEN` too, so a stored token is not sent to it. | the profile's |
| `ATANOR_TOKEN` | The token; replaces the profile's, and is what `login` stores when set. | the profile's |
| `ATANOR_CONNECT_TIMEOUT` | Seconds to open the connection. | 10 |
| `ATANOR_TIMEOUT` | Seconds to wait for an answer. | 30 |
| `ATANOR_UPLOAD_TIMEOUT` | Seconds to wait for the answer to an upload (`deploy`). | 300 |
| `XDG_CONFIG_HOME` | Where `atanor/config.json` lives. | `~/.config` |
| `MIX_ENV` | The build `deploy` reads native modules from. | `dev` |

The timeouts take positive numbers, fractions included. The size a node accepts
is its own `admin` option `max_package_bytes` (default 67,108,864).

## Errors

The message comes from the HTTP status and the JSON body of the answer.

| Status | Message (shortened) | What to do |
| --- | --- | --- |
| 401 | the server did not accept the token | The token is wrong, expired or revoked: `atanor login` with a new one. |
| 403 | forbidden: this token needs the scope `worker:hello:deploy` | Ask for a token with that scope. A deploy with `--activate` needs `activate` too. |
| 404 | not found, or the package is not stored | Check the worker name; deploy the package before activating it. |
| 409 | the worker has no previous package, or other changes moved the head | Nothing to roll back to; or run the command again. |
| 413 | the package is larger than the server accepts | Raise the node's `max_package_bytes` or shrink the package. |
| 422 | the server refused the package (invalid manifest, hash mismatch, other worker) | Fix the manifest named in the message; run again for a hash mismatch. |
| 503 | the server cannot do that now | The node is starting or cannot reach the bucket; try again shortly. |
| none | cannot reach URL, or no answer in time | Check the URL and the network; raise `--timeout` for slow links. |
