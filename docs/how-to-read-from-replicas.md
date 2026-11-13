# How to read a hot cell from the nodes that do not own it

**The question:** how do I let the reads of a very busy cell run on every node,
accepting data that is a little old, so that the owner has only the writer's
work left?

This guide stands alone. It builds on [how-to-write-a-native-worker.md](how-to-write-a-native-worker.md)
and, for several nodes, [how-to-run-a-cluster.md](how-to-run-a-cluster.md). The
design is in [design.md §19](design.md#19-reading-a-hot-cell-from-other-nodes).
Alambique's own guide to the replicas is `how-to-read-replicas.md` in its
repository.

## What you get, and what you give up

A read with a bound, `{:bounded, 500}`, returns the cell as it was at most 500
ms ago: every write acknowledged more than 500 ms before the read started is in
the answer, newer ones may not be. A node that does not own the cell answers it
from a local copy of the cell that polls the store; if there is no fresh copy
the owner answers, so the read is always correct. The copy costs disk (the whole
database) and a few store requests per second on every node that reads the cell.
A request that reads a bounded state **cannot write**.

## A plain read can be old after a change of owner

This is separate from replicas, and it applies to every read, including a
strong one. When another node takes a cell over (the owner was declared down,
or in a partition), the old owner can keep answering a plain `query` from its
own copy until it learns of the new epoch. If it is alive, for example a node
that was frozen and thawed, the answer can miss writes the new owner has
already acknowledged. A test shows it: the old owner answers `[0, 1]` for a
cell whose new owner acknowledged `2` and `3`
(`test/cluster/takeover_test.exs`, design [§8.12](design.md#812-reads-that-must-not-be-stale)).

How long (read from Alambique's design §5, "Stale reads", not measured here),
counted from the moment the takeover returns:

- the old owner is told at once if its node still runs the instance: the time of
  one message and one renewal request;
- otherwise it learns at its next lease renewal, at most `ttl / 3` plus two
  requests later;
- in the worst case, when it cannot reach the store, it stops answering at the
  end of its lease: `lease_ttl_ms` minus `skew_margin_ms` after its last
  renewal (30 s by default for `lease_ttl_ms`).

To read what you have just written, ask for the lease to be checked:

```elixir
Atanor.Env.query(env, {"notes", "room-1"}, "SELECT body FROM notes", [], verify_lease: true)
```

The cell runs the statement, reads its lease object from the store, and answers
only if the lease is still its own. If it is not, the router sends the read to
the new owner. The cost, read from the code (`lib/atanor/env.ex`, design §8.12):
one store `GET` per read, or per batch of reads that wait behind a write. It is
off by default, so a plain read costs no store request. It is not measured here.

`verify_lease: true` cannot be combined with `{:bounded, _}`: it answers
`{:error, {:invalid_option, :consistency}}`. `Atanor.Cell.query/5` takes the
same option.

A WASM guest has no equivalent: the `sql` import has no lease flag, and
`query-bounded` is the opposite (it accepts old data). A guest that must read
its own writes right after a takeover cannot ask for it. The decision is in
design §8.12.

## Prerequisites

- A cluster of at least two nodes on one store.
- A worker with a `route_key/2` for the cell. A `Plug` or WASM worker has no
  routing key and already runs on the node that received the request.
- Disk under `data_dir` for the copies (`<data_dir>/read-replicas`, at most 1
  GiB per node by default).

## Steps

1. Turn the replicas on in the instance of every node. They are off by default.

   ```elixir
   {Atanor,
    name: MyApp.Atanor,
    store: {Alambique.Store.S3, s3_config},
    data_dir: "/var/lib/myapp/cells",
    alambique: [replicas: []]}
   ```

   `replicas: []` takes Alambique's limits (32 cells and 1 GiB per node, a poll
   every 250 ms); the options are in `Alambique` under `:replicas`. A wrong value
   raises `ArgumentError` at start.

2. Declare the requests that only read, in `route_key/2`:

   ```elixir
   def route_key(%Request{method: "GET", path: "/notes/" <> room}, _env),
     do: {:cell, "notes", room, consistency: {:bounded, 500}}

   def route_key(%Request{path: "/notes/" <> room}, _env), do: {:cell, "notes", room}
   ```

   The `GET` now runs on the node that received it, not on the owner. Its
   `Atanor.Env.query/5` reads with the bound by default:

   ```elixir
   def handle_request(%Request{method: "GET", path: "/notes/" <> room}, env) do
     {:ok, %{rows: rows}} = Atanor.Env.query(env, {"notes", room}, "SELECT body FROM notes")
     %Atanor.Response{body: Jason.encode!(rows)}
   end
   ```

   A write in that request is refused:

   ```text
   iex> Atanor.Env.execute(env, {"notes", "room-1"}, "INSERT INTO notes (body) VALUES ('x')")
   {:error, :read_only}
   ```

   `execute/5`, `transaction/4`, `set_alarm/4`, `cancel_alarm/2`, `enqueue/3` and
   `cron/3` all answer `{:error, :read_only}`. Requests that write keep their
   old key and go to the owner.

3. Choose how the cell gets its replicas.

   *By hand*, from a remote shell on any node (it does not wake the cell, and
   the nodes see it within `marker_ttl_ms`, 5 seconds):

   ```elixir
   Atanor.Cell.replicas(MyApp.Atanor, {"notes", "room-1"}, true)   # :ok
   Atanor.Cell.replicas(MyApp.Atanor, {"notes", "room-1"})         # {:ok, true}
   ```

   *By itself*, for the cells that are busy: add the placement loop with its
   replicas (see [how-to-place-hot-cells.md](how-to-place-hot-cells.md)). With
   `move: false` it moves no cell.

   ```elixir
   hot_cells: [enabled: true, move: false, replicas: true,
               replica_enter: 1_000, replica_exit: 500, replica_hold_ms: 60_000]
   ```

   The owner switches the replicas on when the cell is read 1,000 times a second
   in the cluster for `sustain_ms` (10 s), and off when it has been under 500 a
   second for `replica_hold_ms`. The rate it uses includes the reads on the other
   nodes: they tell it. `hot_cells: [replicas: true]` without the `alambique:
   [replicas:]` option of step 1 is refused at start.

4. Read from a single call, without a declared request, when a handler needs it:

   ```elixir
   Atanor.Env.query(env, {"notes", "room-1"}, "SELECT count(*) FROM notes", [], consistency: {:bounded, 2_000})
   ```

   A WASM guest calls `query-bounded(cell, sql, params, max-lag-ms)` of
   `atanor:cell/sql`. Both are strong when the bound is left out
   (`consistency: :strong`, the default; `query` in WASM).

5. Check that it works. Alambique emits who answered each bounded read:

   ```text
   [:alambique, :replica, :read] %{lag_ms: 82} %{source: :replica, cell: "notes.room-1", txid: 3}
   [:alambique, :replica, :read] %{} %{source: :owner, reason: :no_replica, cell: "notes.room-1"}
   ```

   With the placement loop, each switch is an event:

   ```text
   lab-event hot_cell.replicas %{result: :ok, action: :on, cell: {"log", "hot-1793603605"}} %{reads: 651.3486513486514}
   ```

   `GET /hot-cells` on the admin API lists the cells whose replicas this node
   switched on under `replicas`.

## Errors

| You get | Because |
| --- | --- |
| `{:error, {:invalid_option, :consistency}}` | the bound is not a positive integer, the value is not `:strong` or `{:bounded, ms}`, or `{:bounded, _}` is combined with `verify_lease: true` |
| `{:error, {:invalid_option, key}}` | `query/5` got an option it does not have |
| `{:error, :read_only}` | a write in a bounded request |
| 500 `internal_error` and a log line "returned a routing key it may not use" | `route_key/2` returned options other than `consistency: :strong \| {:bounded, ms}`, or options on a TCP key |
| `failed: invalid option: consistency` in a WASM guest | `max-lag-ms` of 0 |

## Troubleshooting

- **Every read is answered by the owner.** Look at `reason` in
  `[:alambique, :replica, :read]`: `:off` is a missing `alambique: [replicas:]`;
  `:no_replica` for long means the switch of the cell is off (step 3), the node is
  at `max_cells` or `max_bytes`, or the first copy is still being built (a large
  cell takes a while: it is a full restore).
- **The switch never turns on by itself.** The cell must be read at
  `replica_enter` times a second in the whole cluster for `sustain_ms`, and only
  the reads that go through `Atanor.Cell` (`Atanor.Env.query/5`) are counted: a
  read that calls Alambique directly is not seen. The event
  `[:atanor, :hot_cell, :replicas]` reports the rate (`reads`) when it switches.
- **The switch turns on and off.** Widen the gap between `replica_enter` and
  `replica_exit`, or raise `replica_hold_ms`.
- **A read is older than the bound.** It is not, for the writes acknowledged
  more than the bound before it started. A caller that alternates between a
  bounded and a strong read can see time go back by up to the bound.

## Next steps

- [design.md §19](design.md#19-reading-a-hot-cell-from-other-nodes): the
  guarantee, why a bounded request cannot write, and the tests.
- [how-to-partition-a-cell.md](how-to-partition-a-cell.md): when the writes are
  the limit.
