# What does not work

Defects that are still open. Each entry says what happens, what to do about it,
and where the evidence is. Entries are removed when they are fixed. Limits that
are choices of the design are in the "Limits" paragraphs of
[design.md](design.md) and in the README's
[Limitations](../README.md#limitations).

## WASM throughput is about 5% below 0.2.0 after the admission change

**What happens.** The hello guest over HTTP serves about 24,100 to 24,400
requests/s with 32 clients on 12 threads, where 0.2.0 served 25,940. One
worker is also refused with 503 `overloaded` above `worker_calls` where 0.2.0
queued, about 0.1% of the requests of a 64-client burst (design §14.2).

**Workaround.** None is needed for correctness. For the most throughput keep
`threads` at the core count and raise `worker_calls` and `max_calls` for
bursts of one worker; a smaller `max_calls` refuses more and was not faster.

**Evidence.** Fuel mode, 32 clients, ABBA order, load below 3: master 25,940,
25,741 and 26,051 requests/s; this branch 24,143 and 24,706 (a third run of
12,888 is noise). The thread count explained part of it and is fixed; the
suspect for the rest is the 60 instance slots of the pooling allocator
against 12. `mise run bench:wasm` reproduces it.
