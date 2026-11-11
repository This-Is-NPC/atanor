# How to follow changes in a cell

**The question:** How does a native worker read the change feed of a granted
namespace, or subscribe to changes without waking the cells?

This guide stands alone. It assumes a native worker with a cell namespace;
[how-to-write-a-native-worker.md](how-to-write-a-native-worker.md) creates one.
WASM workers cannot follow the feed (see [design §16.5](design.md#165-limits-and-options)).

## Prerequisites

- A running Atanor instance and a native deployment that grants the namespace
  under `bindings.cells`.
- The Alambique change feed, which is on by default. Atanor does not need a
  manifest key for it: the `cells` grant is the permission.

## Steps

1. Grant the namespace in `atanor.json`. No other binding is needed.

   ```json
   "bindings": {"cells": {"domains": {"migrations": ["..."]}}}
   ```

2. Read a page of changes with `Atanor.Env.changes/4`. `nil` starts at the
   oldest retained change; `100` is the page size in feed objects (one object
   can carry several row changes).

   ```elixir
   {:ok, changes, next} = Atanor.Env.changes(env, "domains", nil, 100)

   for %Atanor.Change{} = change <- changes do
     IO.inspect({change.cell, change.op, change.row, change.id})
   end
   ```

   Each change names the `namespace`, the cell `cell` key, the `table`, the
   `op` (`:insert`, `:update` or `:delete`), the primary `key`, the new `row`
   (or `nil` for a delete), the `txid`, the record time `at` and the idempotency
   id. Only cells of the granted namespace are returned. The `row` lacks the
   columns the instance leaves out of the feed (see "Leave columns out of the
   feed"). Atanor's own
   `_atanor_*` tables (jobs, alarms, cron, undo positions) are internal to the
   feed and never appear.

3. Store `next` and pass it back to continue. The position is opaque and
   covers every namespace, location and feed shard of the instance.

   ```elixir
   # After processing `changes`
   {:ok, newer, next} = Atanor.Env.changes(env, "domains", next, 100)
   ```

   One read can return fewer changes than the requested number after other
   namespaces are filtered out (or more when a batch carries several rows), and
   `next` can be the same as the position you passed when nothing new has
   settled. Do not construct positions yourself. A position is instance-wide:
   keep one per namespace you read independently.

4. Start at the current end of the feed with `feed_position/2`. The time is
   moved back by the instance's Alambique `skew_margin_ms` (2 000 ms by
   default), so a publisher whose clock is behind cannot slip a change behind
   the position; this can repeat up to that margin of earlier changes.

   ```elixir
   position = Atanor.Env.feed_position(env, :now)
   {:ok, changes, next} = Atanor.Env.changes(env, "domains", position, 100)
   ```

5. Subscribe when a worker must react instead of polling. Do this from a
   long-lived process, not inside `handle_request/2`; the messages arrive in
   the caller's mailbox.

   ```elixir
   def init(env) do
     {:ok, ref} = Atanor.Env.subscribe(env, "domains", from: :now)
     {:ok, %{env: env, ref: ref, position: nil}}
   end

   def handle_info({:atanor_changes, ref, changes, position}, %{ref: ref} = state) do
     for %Atanor.Change{cell: domain} <- changes, do: evict(domain)
     {:noreply, %{state | position: position}}
   end

   def handle_info({:atanor_feed_dropped, ref, position}, %{ref: ref} = state) do
     # The subscriber was too slow. Resume after the last delivered change.
     {:ok, ref} = Atanor.Env.subscribe(state.env, "domains", from: position)
     {:noreply, %{state | ref: ref}}
   end
   ```

   `from:` is `:now` (the default) or a position from a previous
   `{:atanor_changes, ...}` message, `changes/4` or `feed_position/2`. `:now`
   uses the clock minus `skew_margin_ms`, so it can repeat up to that margin of
   earlier changes but does not skip a publisher whose clock is behind. A
   subscriber that starts behind the tailer catches up first, so it also
   receives the older changes. The message position is the place to continue
   from; store it.

6. Remove the subscription when the process no longer needs it.

   ```elixir
   :ok = Atanor.Env.unsubscribe(env, ref)
   ```

   The tailer also removes a subscriber that exits; with the last subscriber
   the tailer stops until someone subscribes again.

## A cache invalidated by changes

The address cache keeps `domain => address` and evicts a domain when the
`domains` cell of that domain changes. Duplicates are harmless because the
operation is a delete.

```elixir
def init(env) do
  {:ok, ref} = Atanor.Env.subscribe(env, "domains", from: :now)
  {:ok, %{env: env, ref: ref, entries: %{}}}
end

def handle_info({:atanor_changes, ref, changes, _position}, %{ref: ref} = state) do
  # A rewind marker (`%Atanor.Change.Rewind{}`) also names a cell whose state went back.
  entries = Enum.reduce(changes, state.entries, fn %{cell: domain}, acc ->
    Map.delete(acc, domain)
  end)

  {:noreply, %{state | entries: entries}}
end

def handle_info({:atanor_feed_dropped, ref, position}, %{ref: ref} = state) do
  {:ok, ref} = Atanor.Env.subscribe(state.env, "domains", from: position)
  {:noreply, %{state | ref: ref}}
end
```

The same pattern serves a reverse proxy, a cache of cell indexes or any
per-domain state that another cell owns. Here `evict/1` removes one domain
from the cache's storage.

## Leave columns out of the feed

By default every column of every table is in `Atanor.Change.row`. A column that
subscribers never read but that is large (the body of a message) makes every
change of the row expensive in the store. The app that owns the instance
declares what the feed carries under `alambique: [feed: ...]`; for a mail store
that follows the headers of `messages` and nothing of `attachments`:

```elixir
{Atanor,
 name: MyApp.Atanor,
 # ...
 alambique: [
   feed: [
     tables: %{
       "messages" => [omit: ["body"]],
       "attachments" => false
     }
   ]
 ]}
```

Each entry is `true` (the whole table, the default), `false` (nothing),
`[omit: columns]` (all but these) or `[only: columns]` (the key and these).
`other_tables: :skip` leaves out the tables the map does not name; the default
`:capture` keeps them. Names are non-empty strings. A wrong shape stops the
instance at start with a message that names the key.

What changes for a subscriber:

- The omitted column is **absent** from `change.row`. It is not `nil`: a NULL
  column is present with the value `nil`. Use `Map.fetch/2` or `Map.get/2`
  knowing which of the two you mean.
- The key columns are always in `row` and in `key`.
- An `UPDATE` that changes only omitted columns produces no change.
- Read the omitted value from the cell, in a call that owns it
  (`Atanor.Env.query/5`); the feed does not have it.
- `_atanor_*` tables are internal and never in the feed, so an entry naming one
  has no effect.

## When a cell is rewound

An operator can put a cell back to an earlier state, for example to undo a bulk
operation ([how-to-run-a-bulk-operation.md](how-to-run-a-bulk-operation.md#undo-and-the-undo-report)).
The list of changes then holds an `Atanor.Change.Rewind` after the changes it
undoes, in `changes/4` and in `{:atanor_changes, ...}` messages:

```elixir
%Atanor.Change.Rewind{
  namespace: "domains", cell: "example.com",
  from_txid: 416, to_txid: 411, txid: 417,
  target: {:txid, 411}, kept: ["_atanor_alarms", "_atanor_jobs", "_atanor_undo"],
  at: 1790000000000, id: "domains.example.com:417:rewind"
}
```

After it, the cell holds the state it had at `to_txid`. The changes of that cell
with a `txid` above `to_txid` and up to `from_txid` were undone; they are still
in the feed, before the marker. A worker has to react:

- **Match the marker.** Code that matches only `%Atanor.Change{}` in a
  function head fails with a function clause error when a marker arrives, which
  is visible. A comprehension such as `for %Atanor.Change{} = c <- changes`
  skips the marker silently and leaves your copy of the cell as it was before
  the rewind. Handle `%Atanor.Change.Rewind{}` explicitly.
- **Put your copy back.** A cache of a cell evicts the entry, as the example
  above does. A copy that applies the changes keeps them by `txid`, drops those
  above `to_txid` and goes on with the changes after the marker; or it reads
  the cell again.
- **Ignore repeats.** Changes at or below `to_txid` can arrive again after the
  marker, with the `id` they had. A rewind to a state from before an earlier
  rewind brings the changes that one undid back.
- **It is not instant.** The marker is published when the cell wakes next and
  after the feed window, like any change. A worker that reads the cell before
  then already sees the rewound state.

## Options

Atanor's tailer options, with their defaults:

| Option | Default | Meaning |
| --- | --- | --- |
| `feed.poll_ms` | 1 000 | time between feed reads |
| `feed.page_size` | 100 | feed objects per read |
| `feed.retry_ms` | 1 000 | first wait after a read error |
| `feed.max_backoff_ms` | 30 000 | longest wait after repeated read errors |
| `feed.max_backlog` | 1 000 | messages in a subscriber's mailbox before it is dropped |

```elixir
{Atanor,
 name: MyApp.Atanor,
 # ...
 feed: [poll_ms: 250, page_size: 500, max_backlog: 10_000]}
```

By default `alambique: [feed: [object_batches: 16, linger_ms: 250]]` (fewer
store requests; `object_batches: 1` is one commit per object) applies. One
object carries up to 16 commits of a cell, a cell that stops publishes what it
holds first, a lone change is delivered up to 250 ms later, and
`page_size` still counts objects, so a page can hold more changes than
`page_size`. Order per cell, the position and `Atanor.Change.id`
are unchanged. The order per cell is the order of the `txid`; a batch published late
can be read behind a later one ([a known limit](what-does-not-work.md#a-late-feed-batch-can-be-read-behind-a-later-one)), so a consumer
that needs the commit order sorts a cell's changes by `txid`. A consumer outside Atanor must use the same Alambique as the nodes.

Alambique's feed options stay under `:alambique`: `window_ms`, `retention_ms`,
`prune_interval_ms`, `publish_retry_ms` and `shards`. `skew_margin_ms` is an
Alambique instance option (not under `feed:`) and is the margin `:now` uses.
The read delay is
`window_ms + op_timeout_ms + 2 * skew_margin_ms`; with Alambique's defaults
that is about 24 seconds. Lower `alambique: [feed: [window_ms: ...]]`,
`op_timeout_ms` and `skew_margin_ms` when changes must be visible sooner, within
what late publication and clock skew allow.

## What to expect

- **At least once.** The same change can be read or delivered more than once,
  also after a cell moves. Use `Atanor.Change.id` to ignore repeats.
- **One tailer per node and instance.** It starts with the first subscriber
  and stops with the last. Each node has its own tailer; the feed is in the
  store, so a write on any node reaches the others.
- **Catch-up and repeats.** A subscriber that starts from an older position
  reads its own pages until it reaches the end of the feed, then joins the
  shared stream. While the shared stream is behind, it can see changes it
  already caught up with; this is the at-least-once trade-off. Catch-up reads
  one `feed.page_size` page after another until it reaches the end of the feed,
  and so does the shared stream while it finds new objects; only a read that
  finds nothing new waits `feed.poll_ms`.
- **Backpressure.** A subscriber that leaves more than `feed.max_backlog`
  messages unread is removed and gets `{:atanor_feed_dropped, ref, position}`.
  Resubscribe from `position`; other subscribers keep receiving.
- **Store errors are retried.** A failed read is retried with exponential
  backoff and does not drop subscribers.
- **`_atanor_*` is not in the feed.** Atanor lists the prefix as internal
  (`feed: [internal_prefixes: ["_atanor_"]]`, fixed by Atanor, not an option),
  so those tables get no capture triggers and publish nothing. A cell that
  changed since the prefix was adopted regenerates its triggers when it wakes;
  records published before that stay in the store until retention removes
  them and can still be read.
- **`:now` has a skew margin.** A `:now` position or subscription starts and
  filters at now minus `skew_margin_ms` (2 000 ms by default, from Atanor's
  `:alambique` options). It can repeat changes from up to that margin before
  the subscription; it does not skip a publisher whose clock is behind.
- **Retention.** Feed objects are deleted after seven days
  (`alambique: [feed: [retention_ms: 604_800_000]]`, Alambique's default).
  Reading an expired position starts at the oldest object left, so a worker
  that stores its position and is away longer than that misses the pruned
  changes; raise `retention_ms` for it. `retention_ms: nil` keeps the feed for
  ever and it grows. `feed: false` is refused: Atanor reads the feed.

## Troubleshooting

- **`{:error, {:not_granted, {:cell, "domains"}}}`** Add the namespace under
  `bindings.cells`.
- **No changes arrive** Check that the write happened and that the namespace is
  the cell's namespace. Allow for Alambique's settle delay (about 24 s with
  defaults) plus `feed.poll_ms`. `[:atanor, :feed, :read]` shows how many
  records were read and kept.
- **`{:atanor_feed_dropped, ref, position}`** The process was slower than
  `feed.max_backlog` messages. Process messages sooner, raise the limit, or
  resubscribe from `position` and catch up with `changes/4`.
- **Repeated changes** Expected. Ignore `Atanor.Change.id` values already
  applied.
- **A function clause error on `Atanor.Change.Rewind`** The worker met a rewind
  marker. See "When a cell is rewound".
- **`rejected` in `[:atanor, :feed, :read]`, or a warning "change feed skipped
  N object(s)"** Alambique could not decode a feed object. The tailer skips it;
  `[:atanor, :feed, :rejected]` has the `reason` and the object `key`. With
  `{:unsupported_format, version}` a newer writer wrote it: upgrade this node.
- **Read errors in the log** The tailer retries; watch
  `[:atanor, :feed, :error]` for `reason` and `retry_ms`. Subscribers stay.
- **A WASM worker needs the feed** It has no import for it. Keep the
  subscription in a native worker and call the WASM worker, or poll a cell.

## Next steps

- [design.md §16](design.md#16-the-change-feed-for-workers): the tailer,
  positions and delivery model.
- [telemetry.md](telemetry.md): the feed events.
- [how-to-write-a-native-worker.md](how-to-write-a-native-worker.md): grants,
  cells and env.
