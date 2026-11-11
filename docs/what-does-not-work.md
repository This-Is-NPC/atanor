# What does not work

Defects that are still open. Each entry says what happens, what to do about it,
and where the evidence is. Entries are removed when they are fixed. Limits that
are choices of the design are in the "Limits" paragraphs of
[design.md](design.md) and in the README's
[Limitations](../README.md#limitations).

## A WASM guest can hold pool threads while it waits

**What happens.** A guest keeps its pool thread for the whole call, also while
it sleeps (`wasi:clocks` and `poll`), waits for a slow host call or waits for a
nested worker call. CPU limits do not fire during a wait, so guests that wait
for `timeout_ms` (30 s by default) can occupy all `threads` and every other WASM
worker then gets `:overloaded` after `queue_wait_ms`. Nested calls hold the
caller's thread while the callee needs another one. Outbound HTTP now ends with
the call's deadline, but the wait is still a held thread.

**Workaround.** Lower `limits.timeout_ms` and the node's `max_timeout_ms`, and
raise `threads`. Deploy only packages you trust: the manifest author is
trusted code (design §3.2).

**Evidence.** Review finding WASM-5 (read from the sources, not measured).
Not fixed because a per-worker cap and running a callee on its caller's slot
change how the queue admits calls and need their own design and measurement.

## A late feed batch can be read behind a later one

**What happens.** Alambique orders the first occurrence of each idempotency key
of a cell by commit order. After a late publication, a batch that was stamped
before it but arrives after it can get a key that sorts before the late one.
Observed with `window_ms: 1`, where every batch is late: in 3 of 10 runs of 40
cells with 16 inserts each, a cell read TXIDs 3, 5, 6, 7, 4, 8.

**Workaround.** A consumer that needs the commit order sorts the changes of a
cell by `txid` ([how-to-follow-cell-changes.md](how-to-follow-cell-changes.md)).
The feed tests of Atanor keep their window above the publication time.

**Evidence.** `test/atanor/feed_test.exs`. Not fixed in Atanor: the key time is
chosen by Alambique's feed sender.
