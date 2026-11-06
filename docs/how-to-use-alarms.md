# How to run code in a cell at a later time

**The question:** How do I make a worker run `handle_alarm/3` for a cell at a
given time, even when the cell is asleep?

This guide stands alone. It uses [examples/hello-native](../examples/hello-native).
WASM workers are covered in the last section.

## Prerequisites

- The tools of the [README](../README.md#requirements).

## Steps

1. Grant alarms in `atanor.json`, next to the cell namespace the alarm uses.

   ```json
   "bindings": {"cells": {"hits": {"migrations": ["..."]}}, "alarms": true}
   ```

2. Set the alarm with a time in milliseconds since the epoch and a binary
   payload. A worker has one alarm per cell, so setting it again replaces the
   previous one; `cancel_alarm(env, cell)` removes it.

   ```elixir
   at = System.os_time(:millisecond) + 3_000
   :ok = Atanor.Env.set_alarm(env, {"hits", name}, at, "")
   ```

3. Implement the handler. It runs on the active deployment of the worker when
   the time comes, with the cell's address and the payload.

   ```elixir
   @impl true
   def handle_alarm({"hits", name}, _payload, env) do
     with {:ok, _n} <- greet(env, name), do: :ok
   end
   ```

   Return `:ok`, or `{:error, reason}` (or raise) to be retried. The handler
   can set the next alarm itself, which makes a periodic job.

4. Run it. `/hello/<name>/later` of the example sets the alarm.

   ```sh
   cd examples/hello-native
   mise exec -- mix atanor.dev --port 4123
   ```

   ```text
   $ curl -s http://localhost:4123/hello/ada
   {"hello":"ada","greetings":1}
   $ curl -s http://localhost:4123/hello/ada/later
   {"hello":"ada","again_at":1793063776602}
   $ sleep 4; curl -s http://localhost:4123/hello/ada
   {"hello":"ada","greetings":3}
   ```

   The alarm greeted once (count 2), then the last request made 3.

## WASM workers

A WASM worker uses the same alarms with the same grants. It sets and cancels
its alarm through the `atanor:cell/alarms@0.1.0` import
(`set-alarm(namespace, key, at-ms, payload)`, `cancel-alarm(namespace, key)`)
and handles it by exporting `atanor:worker/alarm-handler@0.1.0`
(`handle-alarm(namespace, key, payload) -> result<_, string>`). Return `ok` to
finish; an error, a trap or a limit is retried like a native failure. Each
firing runs in a fresh instance under the worker's `limits`. A manifest with
`"alarms": true` whose component lacks the export is refused with
`{:missing_export, "atanor:worker/alarm-handler@0.1.0"}`. A Rust example is in
[how-to-write-a-wasm-worker.md](how-to-write-a-wasm-worker.md#run-code-at-a-later-time-and-serve-websockets).

## What to expect

- **At least once.** If the node dies or the handler takes longer than
  `timeout_ms`, the alarm fires again. Write handlers that are safe to repeat.
- **Retries.** A failure is retried after 1 s, then 2 s, 4 s and so on up to
  60 s, and dropped after `max_attempts` (5) with a `final: true` event.
- **Sleeping cells wake.** The alarm is found through the store's index, not
  by waking cells.
- **Timing.** An alarm fires within about `tick_ms` (1 s) of its time. A time
  in the past fires at the next tick.
- **Undeployed workers.** Their alarms wait and fire after the worker is
  deployed again.

Operator options: `alarms: [tick_ms: 1_000, timeout_ms: 30_000, max_attempts: 5]`.

## Troubleshooting

- **`{:error, {:not_granted, :alarms}}`** Add `"alarms": true`.
- **`{:error, {:not_granted, {:cell, ns}}}`** Grant the namespace.
- **`{:missing_callback, Mod, {:handle_alarm, 3}}`** A manifest with
  `"alarms": true` needs `handle_alarm/3`.
- **Nothing fires** Check that the worker is deployed on a node and that the
  time is in milliseconds since the epoch, not seconds.

## Next steps

- [design.md](design.md#74-alarms): storage, ownership and delivery.
- [telemetry.md](telemetry.md): `fired` and `failed` events.
