# How to diagnose a crash

**The question:** A node died — a NIF segfault, a BEAM abort, or a cell that
crashed the VM — and I need the core dump and the work that was running.

This guide stands alone. It is written for the operator's release; Atanor does
not build that release, so the build settings below are recommendations, not
something Atanor changes for you.

## What Atanor already gives you

On the next start, with `:diagnostics` enabled, Atanor reads the **breadcrumb**
files left by the previous VM and writes a crash report:

```sh
curl -s -H "authorization: Bearer $TOKEN" localhost:5001/crashes
```

```json
{"crashes":[{"id":"c-...","node":"a@host","detected_at_ms":1790000000000,
  "release":{"id":"image-sha",...},
  "units":[{"kind":"job","worker":"notes","deployment":"<sha>",
            "cell":"notes.alice","job_id":"...","operation_id":"...",
            "release":"image-sha",
            "alambique":{"crashes":{"total":1,"recent":[{"kinds":["cell"]}]},
                         "frozen":false}}],
  "truncated":0}],"next":null}
```

`GET /crashes/:node/:id` returns one report. The unit names the job, alarm,
sweep operation, undo report, migration, migration rehearsal, deployment or WebSocket that was running; the
`alambique` field is `Alambique.crashes/2` and `Alambique.frozen?/2` for its
cell. A cell whose crash was recorded by Alambique's quarantine may be frozen.

The default `diagnostics.breadcrumbs: :durable` covers jobs, alarms, sweep
driver pages, migrations, deployment activation and WebSocket connections. It
does **not** cover every HTTP request, native or WASM; use
`diagnostics: [breadcrumbs: :all]` while reproducing an HTTP crash. `:all`
writes one file per request and costs throughput (design §12).

A clean stop and a process killed with an Elixir `:kill` leave no busy file.
Only a VM crash produces a report. A whole-machine crash can lose the
breadcrumb files (they are not fsynced) and Alambique's markers; then only the
store's own records remain.

## Enable core dumps

A NIF segfault or an abort writes an **OS core**, not `erl_crash.dump`. The
BEAM writes `erl_crash.dump` for its own fatal errors. Enable both.

For a systemd service:

```ini
[Service]
LimitCORE=infinity
Environment=ERL_CRASH_DUMP=/var/lib/atanor/erl_crash.dump
Environment=ERL_CRASH_DUMP_SECONDS=30
```

`ERL_CRASH_DUMP_SECONDS` matters when `heart` supervises the VM: `0` suppresses
the dump, a positive value waits that many seconds, and `-1` waits until the
dump is complete. Without `heart`, set `ERL_CRASH_DUMP` so the file has a known
path.

For a shell or container, set the limit before starting the VM:

```sh
ulimit -c unlimited
```

Docker needs `--ulimit core=<size>` (or the equivalent Compose `ulimits`) and a
host path for the core.

Check where the kernel writes cores:

```sh
sysctl kernel.core_pattern
```

If the value starts with `|`, a handler such as `systemd-coredump` owns the
core; use its tools. Otherwise the pattern names a file path:

```sh
sysctl -w kernel.core_pattern=/var/lib/atanor/cores/core.%e.%p.%t
```

List and inspect systemd-coredump records:

```sh
coredumpctl list
coredumpctl info <PID>
coredumpctl gdb <PID>
```

In `gdb`, `thread apply all bt full` shows every BEAM and NIF thread. For a
plain core file:

```sh
gdb /path/to/erts/bin/beam.smp /var/lib/atanor/cores/core.beam.1234
```

The release must include ERTS (`include_erts: true`) for `beam.smp` to have
symbols; a distro-provided ERTS may be stripped.

## Keep NIF symbols

Both NIFs are Rust: `atanor_wasm.so` and `alambique_nif.so`. Keep debug
information in the release profile (or use split debug files):

```toml
[profile.release]
debug = 2
strip = "none"
panic = "unwind"
split-debuginfo = "unpacked"   # Linux; packed on macOS
```

Do not strip `priv/native/*.so` when packaging. Keep BEAM debug information in
the release:

```elixir
releases: [
  myapp: [
    include_erts: true,
    strip_beams: false
  ]
]
```

If the package must stay small, ship the symbols separately:

```sh
objcopy --only-keep-debug libatanor_wasm.so libatanor_wasm.so.debug
objcopy --strip-debug --add-gnu-debuglink=libatanor_wasm.so.debug libatanor_wasm.so
```

Keep the `.debug` file and point `gdb` at it:

```sh
gdb -ex "set debug-file-directory /opt/myapp-debug" \
    -ex "file beam.smp" -ex "core-file core.beam" \
    -ex "thread apply all bt full"
```

`file libatanor_wasm.so` should say `with debug_info, not stripped`; if it
says `stripped`, the build or a packaging step removed the symbols.

## Read the quarantine

Alambique records a cell crash at the next start, in
`<prefix>/cells/<cell>/crashes`; its counter has `total` and `recent` crashes,
where each has a time, node and `kinds` (what was in flight). The counter is
also in every relevant crash report.

A cell is frozen when `recent` reaches `quarantine.threshold` inside
`quarantine.window_ms`; a frozen cell refuses to wake with `:frozen`. Look at
it with `mix alambique.inspect` (from a checkout of Alambique or its release) or
`/crashes`. To let it wake again and forget the counter:

```sh
curl -s -X POST -H "authorization: Bearer $TOKEN" \
  localhost:5001/cells/notes/alice/unfreeze
```

This is the operator's decision: `Alambique.unfreeze/2` deletes the crash
counter, so the cell starts at zero.

## Troubleshooting

- **No `/crashes` report after a restart.** The VM may have stopped cleanly,
  or the breadcrumb files were lost with the machine. Check `data_dir/
  diagnostics/pending/`; a report that could not be written to the store stays
  there and is retried every `diagnostics.pending_retry_ms`. The files there
  stay under `diagnostics.max_bytes` (32 MiB): when the store is down for long,
  the oldest reports are removed first.
- **The report names a cell but `alambique` is `null`.** The crash was outside
  Alambique's native callbacks (for example a worker sleeping or its own NIF),
  so the cell marker was idle. The unit still identifies the job or request.
- **No core file.** Check `LimitCORE`/`ulimit -c`, `kernel.core_pattern`, and
  whether the kernel or a container runtime redirected the core. A NIF panic
  converted to an Erlang exception does not produce a core; it fails the call
  and appears in telemetry as `:crashed`.
- **`erl_crash.dump` is missing under `heart`.** Set
  `ERL_CRASH_DUMP_SECONDS` to a positive value or `-1`; `0` suppresses it.
- **The NIF looks stripped.** Rebuild without `strip`, or ship the `.debug`
  file and use `set debug-file-directory`.

## Next steps

- [design.md §17](design.md#17-release-identity-and-crash-diagnostics) for the
  breadcrumb and report model.
- [design.md §10.2](design.md#102-admin-api) for the admin endpoints.
- [how-to-use-the-admin-api.md](how-to-use-the-admin-api.md) for the token and
  request examples.
