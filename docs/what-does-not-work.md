# What does not work

Defects that are still open. Each entry says what happens, what to do about it,
and where the evidence is. Entries are removed when they are fixed. Limits that
are choices of the design are in the "Limits" paragraphs of
[design.md](design.md) and in the README's
[Limitations](../README.md#limitations).

## A waiting WASM guest still holds a call slot

**What happens.** A guest that waits (a sleep, `poll`, a host call, an outbound
response, a nested call) no longer holds the right to run, so it cannot starve
other workers of CPU (design §14.2). It still holds a pool thread, a store and
a call slot until its deadline. One worker whose guests all wait reaches
`worker_calls` and gets `:overloaded` for its own next calls; every worker
together can reach `max_calls` the same way. Nested calls are capped by
`max_nested_calls`, and one more is refused.

**Workaround.** Raise `max_calls`, `worker_calls` and `max_nested_calls` (each
adds address space to the pooling allocator, design §14.9), or lower
`limits.timeout_ms` and the node's `max_timeout_ms`. The cap is per deployment,
so two deployments of one worker during a rollout each get `worker_calls`.

**Evidence.** `test/atanor/wasm_wait_test.exs`.

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
