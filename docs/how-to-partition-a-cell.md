# How to spread a very busy cell over several partitions

**The question:** My cell is so busy that one writer is not enough, even on its
own node. How do I split it into partitions that have a writer each, route
requests to the right one, and read across them?

This guide stands alone for someone who has a worker with a cell namespace
([how-to-write-a-native-worker.md](how-to-write-a-native-worker.md) or
[how-to-write-a-wasm-worker.md](how-to-write-a-wasm-worker.md)). The design,
with the reasons, is [design §4.2](design.md#42-partitioned-cells).

## What you get, and what you give up

A cell has one writer. Moving it to a better node
([how-to-place-hot-cells.md](how-to-place-hot-cells.md)) changes which node that
is, not how many writers there are. A partitioned namespace has `n` cells for
each logical cell, each with its own writer on the node Alambique placed it on,
so the writes of one logical cell can use up to `n` writers and `n` nodes.

The limits stay what they are for a cell, per partition:

- One writer per partition. A single partition key is as busy as a cell was.
  Choose a partition key that spreads: a user, a document or a session, not
  a constant.
- A transaction is within one partition. What must commit together shares a
  partition key.
- A query is within one partition. Reading across them is a scatter-gather
  or the change feed (step 5). A unique constraint holds inside a partition.
- `n` is fixed for the life of the data. There is no resharding. Pick `n` for
  the growth you expect, a few times the number of nodes you will have.

A namespace without `partitions` behaves as before. You decide per namespace.

Partitions spread the writers; they do not by themselves raise the throughput of
your cluster. In the cluster lab,
on a host whose load was five to ten times the usual, six partitions spread the writes
and the CPU over the three nodes but did not write faster than one cell, and the
shared store reached 150 to 180% of its two vCPU, against 56 to 71% with one cell:
each partition replicates its own batches, so many small writers cost the store more
than one that groups. Measure with your store and your nodes before you rely on it.

## Prerequisites

- A native or WASM worker with a cell namespace, running locally
  (`mise run dev`) or on a cluster.

## Steps

1. Declare the number of partitions in the cell binding, 2 to 1024:

   ```json
   "bindings": {
     "cells": {
       "events": {
         "migrations": [[1, "CREATE TABLE log (id INTEGER PRIMARY KEY, who TEXT NOT NULL, n INTEGER NOT NULL)"]],
         "partitions": 6
       }
     }
   }
   ```

   The migrations apply to each of the six cells. A manifest that declares
   another number, or none, for a namespace that already has partitions or
   cells is refused when you activate it (see Troubleshooting).

2. Get the cell of a partition key and use it like any cell. A native worker:

   ```elixir
   def handle_request(%Atanor.Request{method: "POST", path: "/events/" <> who, body: body}, env) do
     {:ok, cell} = Atanor.Env.partition(env, {"events", "stream"}, who)
     {:ok, _} = Atanor.Env.execute(env, cell, "INSERT INTO log (who, n) VALUES (?, ?)", [who, String.to_integer(body)])
     %Atanor.Response{body: "ok"}
   end
   ```

   `{"events", "stream"}` is the logical cell; `cell` is `{"events", "3.stream"}`,
   the physical one that holds `who`. The same partition key always gives the
   same cell, on every node. A WASM worker calls `partition` of
   `atanor:cell/sql@0.1.0` and uses the address it returns:

   ```rust
   use bindings::atanor::cell::sql::{self, Address, Value};

   let logical = Address { namespace: "events".into(), key: "stream".into() };
   let cell = sql::partition(&logical, &who)?;
   sql::execute(&cell, "INSERT INTO log (who, n) VALUES (?, ?)", &[Value::Text(who), Value::Integer(n)])?;
   ```

   In a partitioned namespace a cell can be addressed only by its physical key.
   Using the logical one returns `{:error, {:partition_required, "events"}}`
   (native) or a `failed` error naming it (WASM), so a call that forgets the
   partition fails instead of writing to a cell no partition owns.

3. Route the request to the owner of the partition. A native worker returns the
   partition key in its routing key, and the request runs where the partition's
   writer is, on any node it entered through:

   ```elixir
   def route_key(%Atanor.Request{path: "/events/" <> who}, _env), do: {:cell, "events", "stream", who}
   def route_key(_request, _env), do: :none
   ```

   A WASM worker has no routing key; its cell calls are forwarded to the owner
   of the partition ([design §8.14](design.md#814-ingress-and-owner-what-runs-where)).

4. Keep a transaction within one partition, and put what belongs with the write
   in the same transaction, including its job:

   ```elixir
   Atanor.Env.transaction(env, cell, fn tx ->
     {:ok, _} = Alambique.Tx.execute(tx, "INSERT INTO log (who, n) VALUES (?, ?)", [who, n])
     {:ok, _} = Atanor.Jobs.enqueue(tx, env, cell, %{kind: "audit", payload: who})
     :ok
   end)
   ```

   A job, an alarm, a socket and a channel attach to the physical cell you give
   them. The job runs on the owner of that partition. One logical cell has up to
   `n` alarms (one per worker per cell) and `n` ephemeral channels; to message
   everyone, publish to each partition's channel (`Atanor.Env.partitions/2`
   lists the cells) or have every viewer join the one partition you choose for
   the room.

5. Read across partitions. Two ways:

   - Scatter-gather, for small `n` and not-hot reads. The result is not a
     snapshot: each partition is read at its own moment.

     ```elixir
     {:ok, cells} = Atanor.Env.partitions(env, {"events", "stream"})

     total =
       Enum.sum(for cell <- cells do
         {:ok, %{rows: [[n]]}} = Atanor.Env.query(env, cell, "SELECT count(*) FROM log")
         n
       end)
     ```

   - The change feed, for a view that stays up to date. A native worker follows
     the namespace ([how-to-follow-cell-changes.md](how-to-follow-cell-changes.md))
     and gets the changes of all the partitions, each tagged with its physical
     key. `Atanor.Partition.split/1` gives the logical key and the partition:

     ```elixir
     {:ok, changes, next} = Atanor.Env.changes(env, "events", position, 100)

     for %Atanor.Change{cell: physical, op: :insert, row: row} <- changes,
         {:ok, {logical, partition}} <- [Atanor.Partition.split(physical)] do
       update_view(logical, partition, row)
     end
     ```

     Order holds within a partition, not between partitions; delivery is at
     least once (`change.id` is the idempotency key). Write the view into
     a namespace that is not partitioned, or partitioned by what the view is
     read by.

6. Check where the partitions are. The admin API (`GET /cells`) and the telemetry
   events show physical cells (`events.0.stream` to `events.5.stream`); the
   partitions of one logical cell are on the nodes Alambique chose for them. If
   one partition is hot, [hot cell placement](how-to-place-hot-cells.md) moves
   that partition alone.

## Naming and the hash

The index is `rem(first 8 bytes of SHA-256(partition_key) as an unsigned
big-endian integer, n)`. SHA-256 is standard, so a guest or a script can
compute the partition, and it does not change with the Erlang release:

```sh
printf %s alice | sha256sum | cut -c1-16 | python3 -c 'print(int(input(), 16) % 6)'
```

```text
5
```

The physical key is `<index>.<key>` with the index in decimal and no leading
zeros. The Alambique cell id is `<namespace>.<index>.<key>`, for example
`events.5.stream`.

## Troubleshooting

- **`{:partition_required, "events"}`**: a call used the logical key, or a key
  that is not `<index>.<key>` with an index below `n`. Get the cell with
  `Env.partition/3` (or `partition` in WASM).
- **`{:not_partitioned, "ns"}`** from `Env.partition/3`: the namespace has no
  `partitions` in the manifest.
- **`{:partitions_changed, "events", 6, 12}`** (HTTP 409 `partitions_changed`
  from the admin API; `atanor` prints the same in words): the namespace was
  activated with 6 partitions and the package declares 12, or none. Changing it
  would send every key to another cell. Keep `partitions: 6`, or use a new
  namespace and copy the data through the change feed.
- **`{:namespace_has_data, "events"}`** (409): the namespace already has cells
  and was not partitioned. Its existing cells have keys that are not physical
  keys, so they could not be reached. Use a new namespace.
- **`{:namespace_conflict, "events", worker}`**: two workers grant the namespace
  with different migrations or different `partitions`. Make them identical.
- **A worker returned a routing key it may not use**: `route_key/2` returned
  the three-element form for a partitioned namespace, or a partition key that is
  not a string. Return `{:cell, ns, key, partition_key}`.

## Next steps

- [design §4.2](design.md#42-partitioned-cells): the mapping, naming, the
  refusals and the semantics of jobs, alarms and channels.
- [how-to-place-hot-cells.md](how-to-place-hot-cells.md) to move a hot partition.
