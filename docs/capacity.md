# Capacity: how much load can one node take in production?

**The question:** how many requests, hot cells and WebSockets can I plan per node when I go live, and when do I add
a node? This page stands alone. Read [known-limitations.md](known-limitations.md) for the conditions behind the
numbers.

## The go-live numbers

Plan each node at these values or below. Each one is 50% of the lowest value that passed in the load rounds
018f, 026r and 027 (`load/rounds/`), so it leaves room for the run-to-run noise of the lab and for a store slower than
the lab's.

| Load | Unit | A: 1 CPU, 512 MB | B: 2 CPUs, 2 GB |
| --- | --- | --- | --- |
| `http-native` | requests per second | 300 | 650 |
| `http-wasm` | requests per second | 190 | 550 |
| `cells` | hot cells | 175 | 970 |
| `http-wasm-jobs` | requests per second | 28 | 55 |
| `ws` | open WebSockets | 1650 | 11000 |

What each load is:

- **`http-native`:** reads and writes of one SQLite statement each, in a native Elixir worker, one cell per key.
- **`http-wasm`:** the same work in a WASM worker.
- **`cells`:** cells kept awake together, each written once every 10 s.
- **`http-wasm-jobs`:** an app whose every write enqueues a background job in the same cell (about 4.7 store uploads
  per request).
- **`ws`:** idle WebSockets with one message per socket every 30 s.

The workers and the pass criteria are in
[how-to-run-the-load-tests.md](how-to-run-the-load-tests.md#what-is-measured). A step passes with p99 at or under
250 ms, at most 1% of answers refused with 503, no other 5xx and no error. For `ws` and `cells`, the working set must
also stay under 90% of the memory limit.

Your workload is a mix. Take the row closest to your heaviest request: a WASM app that runs jobs plans with
`http-wasm-jobs`, not with `http-wasm`.

## Users per node

A user who is active at the peak sends `r` requests per second. A share `a` of your users is active at the peak.
Then one node holds:

```text
users per node = go-live rate / (r × a)
```

It must also hold the awake cells and the open WebSockets of those users:

```text
users per node <= cells go-live / (cells a user keeps awake at the peak × a)
users per node <= ws go-live / (WebSockets per connected user × share of users connected at the peak)
```

The smallest of the three is the number of users per node. **Example**, with assumed values (measure yours): a WASM
app with jobs on a B node, each active user sends one request every 5 s (`r` = 0.2), 10% of the users are active at
the peak, each keeps one cell awake, and nobody uses WebSockets:

- by requests: 55 / (0.2 × 0.1) = 2750 users;
- by cells: 970 / (1 × 0.1) = 9700 users.

The node holds 2750 users, and the requests are the limit.

## When to add a node

Alarm when a node reaches **70% of its go-live number** for 5 minutes, on any line of the table. In B with
`http-wasm`, that is 385 requests per second a node; with cells, 679 hot cells. Add a node at the alarm. Do not wait
for 503s.

- **Requests:** measure them per node at the balancer.
- **Hot cells, memory and refusals:** read them in the node's `/runtime` ([what to monitor](how-to-operate-atanor.md#what-to-monitor)).
- **Refusals:** any rise of `admission.refused` before 70% means the mix is heavier than the table: lower your numbers
  to what you observe.

Nodes do not add up one for one. In the lab, two A nodes behind the balancer served 1.66 times one node with
`http-native` and 1.87 times with cells, the second one not confirmed ([the scale measure](how-to-run-the-load-tests.md#measured-results)). Count
each node after the first as 0.8 of a node. Only one and two nodes were measured.

## Where the numbers come from

The numbers were measured on one lab host: one VM with 4 vCPUs and about 5 GB of RAM. It ran the node, the load
generator, and a SeaweedFS store with 25 ms added to every store trip. The rounds ran Atanor 0.4.x to 0.9.0 with
Alambique 0.11.0 to 0.15.0. A load round may lower a number of the table: the go-live value is 50% of the value that
passed. A round does not raise a number. The conditions and the open limits are in
[known-limitations.md](known-limitations.md).

To measure your own hardware, run a round ([how-to-run-the-load-tests.md](how-to-run-the-load-tests.md)) and plan
with 50% of what passes.
