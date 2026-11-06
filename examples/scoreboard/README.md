# Scoreboard

A WASM worker that keeps a scoreboard per room. It exercises HTTP, a WebSocket,
a per-cell job and cell state, and it makes lost or duplicated acknowledged
writes measurable. It is built for the container cluster
([how-to-run-a-cluster-in-containers.md](../../docs/how-to-run-a-cluster-in-containers.md)).

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

## Check for lost and duplicated writes

Every acknowledged write (HTTP 201) carries a client-chosen unique `id`.
[scripts/scoreboard-check](../../scripts/scoreboard-check) writes scores with
unique ids over several rooms, logs the answers, and compares the log with
`GET .../writes`:

```sh
mise run cluster:scoreboard-check write --url http://scoreboard.localhost:18080 --rooms r1,r2,r3 --count 300 --log /tmp/r1.log
mise run cluster:scoreboard-check verify --url http://scoreboard.localhost:18080 --log /tmp/r1.log
```

It puts each request in one of three groups: acknowledged (201), refused (the
call provably did not run: 503 `unavailable`, `overloaded`, a balancer 503, a
refused connection) and unknown (a timeout or reset, 503 `unknown_outcome`, any
other 5xx). `verify` prints the acknowledged ids missing from the rooms (LOST),
those stored more than once (DUPLICATED), and how many unknown and refused
writes are stored. A refused write that is stored is a bug and is printed.
It exits 1 when LOST, DUPLICATED or such a write is not empty.
`mise run cluster:chaos-run SCENARIO` runs it under a fault
([how-to-run-a-cluster-in-containers.md](../../docs/how-to-run-a-cluster-in-containers.md)).
`scripts/scoreboard-watch URL ROOM [SECONDS] [--log FILE]` prints the
WebSocket events, or with `--log` records them and reconnects (Node.js 22 or
later).

## Build and deploy

```sh
mise run build:scoreboard          # examples/scoreboard/scoreboard.wasm
mise run cluster:deploy-example    # token scoped to worker:scoreboard:{deploy,activate,read}
SCOREBOARD_VERSION=2 scripts/build-scoreboard   # another version header, to deploy again
```

The token is created with the operator token the first time and kept in
`cluster/secrets/deploy-token`.
