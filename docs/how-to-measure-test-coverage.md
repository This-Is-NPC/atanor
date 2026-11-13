# How to measure test coverage

**The question:** how do I measure which production lines the tests run, in
Elixir and in Rust, and what is left out of the count?

This guide stands alone. You need the project tools (`mise install`), `epmd`
for the cluster tests, Docker for the SeaweedFS tests, and the `llvm-tools`
rustup component (`rustup component add llvm-tools`).

## Run it

1. Run `mise run test:coverage`. It takes about 30 minutes: the unit, cluster
   and SeaweedFS suites and the Rust tests, each with coverage on. It removes
   the SeaweedFS container when it ends.
2. Read the report at the end: one table per language, sorted by coverage
   (lines, uncovered lines, percent), then a `TOTAL` line per language.
3. The exit status is non-zero when a language is below the threshold.

To run part of it, name the stages (`native`, `unit`, `cluster`, `seaweedfs`),
add `--keep` to keep the data of earlier runs, and `--report-only` to print the
report again:

```sh
scripts/test-coverage unit                       # clears old data, runs one stage
scripts/test-coverage --keep cluster -- test/cluster/jobs_test.exs
scripts/test-coverage --report-only
```

Arguments after `--` go to `mix test`. Results are in `cover/` (git-ignored).

## Settings

| Variable | Default | Meaning |
| --- | --- | --- |
| `ATANOR_COVERAGE_THRESHOLD` | `90` | Minimum line coverage per language, in percent. |
| `ATANOR_COVERAGE_IGNORE` | `^Atanor\.Test\.,^AtanorTestkit\.,^Atanor\.Dev(\.\|$),^Mix\.Tasks\.Atanor\.Dev$` | Comma-separated regexes of Elixir module names left out (`mix.exs`). |
| `ATANOR_COVERAGE_RUST_IGNORE` | none | Regex of Rust file names left out; `cargo llvm-cov` already skips `tests/`. |

## What is counted

- Elixir: the modules of `lib/`, with Elixir's own `:cover`. `test/support`,
  `testkit/`, the development tooling (`Atanor.Dev`, `Atanor.Dev.SeaweedFS` and
  `mix atanor.dev`), `daemon`, `cluster/load`, `lab/`, `bench/`, `scripts/` and `examples/` are
  not counted.
- Code that runs on the peer nodes of `AtanorTestkit.Cluster` is counted: the
  testkit starts `:cover` on each peer and merges its counters when the cluster
  stops. A peer that a test kills or halts loses its counters.
- Rust: `native/atanor_wasm`, from the Rust tests and from every Elixir run,
  which loads a NIF built with `cargo-llvm-cov` instrumentation into its own
  build directories (`_build/coverage`, `native/atanor_wasm/target/llvm-cov-target`).
  The lines of the `#[cfg(test)]` modules are part of the files.

## Troubleshooting

- A test that hashes beam files fails under coverage: cover-compiled modules
  have a different MD5 from the file on disk. `test/test_helper.exs` reloads the
  packaged test worker from disk for that reason.
- A timing-sensitive test can fail because coverage slows the code. Run the
  stage again, and check that it passes with `mise run test`.
