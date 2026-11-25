# Cell cost

**The question:** what does one request, and one awake cell, cost in CPU, memory, local disk and store trips?

These are the costs of the current code, with an S3-compatible store that adds 25 ms to every store trip.

## Cost of one request

Each request runs one SQLite statement in a cell.

| Workload                      | CPU per request           | Memory per request per second | Store trips per request | Bytes to the store per request |
| ----------------------------- | ------------------------- | ----------------------------- | ----------------------- | ------------------------------ |
| Native worker                 | about 1.6 ms              | 0.22 MB                       | 0.99                    | about 630 bytes                |
| WASM worker                   | 1.6 to 2.4 ms             | 0.29 to 0.43 MB               | 0.75 to 1.05            | 600 to 650 bytes               |
| WASM app with a job per write | about 11 ms (job included) | 2.8 MB                        | 6.6                     | about 11.8 KB                  |

The CPU range of the WASM worker depends on the node: about 2.4 ms on a node limited to 1 CPU, about 1.6 ms on a
node limited to 2 CPUs.

## Cost of one awake cell

These costs hold for cells that are all awake together, each written once every 10 s.

| Memory          | Local disk      | Store trips per write | Bytes to the store per write |
| --------------- | --------------- | --------------------- | ---------------------------- |
| 0.59 to 0.64 MB | 0.27 to 0.40 MB | about 6               | about 1.2 KB                 |

Local disk is the cell's SQLite file and its write-ahead log in `data_dir`.

A cell that has been written and then has no call for `feed: [cleanup_after_ms:]` (1 s by default) removes the
change-feed rows it has published in a transaction of its own (Alambique's default `feed: [cleanup:
:idle_or_write]`). That costs the cell, once per quiet period after a write:

| Store trips | Bytes to the store | TXIDs |
| ----------- | ------------------ | ----- |
| 1 put       | about 270 bytes    | 1     |

This was measured against `feed: [cleanup: :in_write]`, which moves the removal into the next write and adds
nothing while the cell is quiet (`mise run bench:idle-cleanup`, in-memory store).

A node also has a fixed memory of about 156 to 178 MB when it is idle. It does not depend on the number of cells.

## Not measured

- Memory per open WebSocket: not measured.
- Storage in the bucket per cell: not measured. It grows with the write history and compaction.
- Cost of a sleeping cell: not measured. Its bucket objects remain.

## Your arithmetic

Multiply the costs of the tables above by your own counts. `C` is the number of awake cells and `R` the number of
requests per second:

```text
memory of awake cells   = C x memory per awake cell
local disk              = C x local disk per awake cell
CPU per second          = R x CPU per request
store trips per second  = R x store trips per request
```

Worked example: 1000 awake cells and 100 requests per second, with the native worker row and the upper ends of the
cell ranges (0.64 MB of memory and 0.40 MB of local disk per awake cell):

```text
memory of awake cells   = 1000 x 0.64 MB  = about 640 MB
local disk              = 1000 x 0.40 MB  = about 400 MB
CPU per second          = 100 x 1.6 ms    = about 0.16 s of CPU per second
store trips per second  = 100 x 0.99      = about 99
```

Add the fixed memory of the node (see above) to the memory of the awake cells.

The other way round, divide the resources of your node by the cost of a cell or of a request:

```text
awake cells by memory      = (node memory - fixed memory) / memory per awake cell
awake cells by local disk  = data_dir size / local disk per awake cell
requests per second by CPU = node CPU seconds per second / CPU per request
```

## Measure your own

To check these costs with your own traffic, watch the callback time and the native counters on the dashboard Metrics
page ([screens.md](screens.md#7-metrics)) while your load runs, and the memory of the node in your process supervisor.
