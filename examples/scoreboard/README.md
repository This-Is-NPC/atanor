# Scoreboard

A WASM worker that keeps a scoreboard per room. It exercises HTTP, a WebSocket,
a per-cell job and cell state. Use it to try a worker end to end, and to check that
acknowledged writes are neither lost nor duplicated.

## Why WASM

A native worker's module must already be in the node's release
([how-to-deploy-a-worker.md](../../docs/how-to-deploy-a-worker.md#native-code)),
so an external native app means rebuilding and rolling the image. A WASM
component travels inside the package, so `atanor deploy` is the whole
deployment, with a scoped token and no node restart. WASM workers support
cells, jobs and WebSockets.

## Model

One cell per room: namespace `rooms`, key = the room name.

| Table | Content |
| --- | --- |
| `writes` | One row per accepted `POST`: `seq` (assigned by the cell), client `id`, `player`, `points`. |
| `rankings` | Recomputed by the job `rank`. |
| `meta` | `ranked_through`: the highest `seq` the rankings include. |

## Interface

All requests use the host `scoreboard.localhost`.

| Request | Answer |
| --- | --- |
| `POST /rooms/ROOM/scores?id=ID&player=NAME&points=N` | 201 `{"id","room"}` once the row and its `rank` job are committed in one transaction. `id`, `player`: 1 to 100 characters of `A-Za-z0-9._:-`. Add `once=1` and a repeated `id` is stored once; without it every request appends a row, so a duplicate shows. |
| `GET /rooms/ROOM/writes?after=SEQ&limit=N` | The stored writes in `seq` order, at most 1000 per page. Page with `after`. |
| `GET /rooms/ROOM` | `writes`, `last_seq`, `ranked_through` and `rankings`. Rankings catch up when `ranked_through` equals `last_seq`. |
| Every answer | The header `x-scoreboard-version`: `1`, or the `SCOREBOARD_VERSION` the component was built with, to tell two deployments apart in the answers. |
| WebSocket `/rooms/ROOM/live` | Send the text `join ROOM`. You get `joined`, then a `score` event per write and a `rankings` event per finished job. |

## Check one write by hand

Every acknowledged write (HTTP 201) carries a client-chosen unique `id`. Replace
`<node-url>` with the address of your node or load balancer:

```sh
curl -i -X POST -H "Host: scoreboard.localhost" "<node-url>/rooms/r1/scores?id=check-1&player=ana&points=10&once=1"
curl -H "Host: scoreboard.localhost" "<node-url>/rooms/r1/writes?limit=1000"
```

The first answer is `201`, and the list of writes of `r1` contains `check-1`. Send the same
`POST` again: with `once=1` the id is still stored once. Without `once=1` a repeated request
adds a second row with the same id.

## Deploy

The repository keeps the compiled component next to its manifest:
`examples/scoreboard/scoreboard.wasm` and `examples/scoreboard/atanor.json`.

1. Log in to the node with a profile that can create tokens (`atanor login --url <node-url>`,
   see [cli.md](../../docs/cli.md)).
2. Create a token that can deploy and activate this worker and read it:

   ```sh
   atanor token create scoreboard-ci --scope worker:scoreboard:deploy --scope worker:scoreboard:activate --scope worker:scoreboard:read
   ```

   The secret is shown once. Keep it, and use it for the profile that deploys the worker.
3. Deploy from the example directory:

   ```sh
   cd examples/scoreboard
   atanor deploy --activate
   ```

   The output names the package and the active version of `scoreboard`.

To change the `x-scoreboard-version` header, the component must be built again with
`SCOREBOARD_VERSION` set. Building the guest needs the repository's WIT packages, which are a
contributor step: see [how-to-build-and-test.md](../../docs/how-to-build-and-test.md).
