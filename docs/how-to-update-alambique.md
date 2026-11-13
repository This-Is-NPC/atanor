# How to move Atanor to a new Alambique

**The question:** How do I change the Alambique release that Atanor is built and
tested against?

This guide stands alone. It is for contributors; Atanor's users get Alambique
through Atanor.

## Why a pinned release

Alambique is a public git dependency,
<https://github.com/This-Is-NPC/alambique>. Atanor depends on one release of it,
identified by a git tag, so builds and test runs are reproducible, and the tests, the benchmarks, the
examples and the lab release all use that release.

The tag (for example `v0.1.0`) is written in one file, `alambique.ref`, at the root of this
repository. `mix.exs`, `testkit/mix.exs` and `examples/*/mix.exs` read it.
`lab/app` and `daemon` depend on Atanor by path and get Alambique through
Atanor's `mix.exs`. Each `mix.lock` records the tag and the commit it resolves to.

Each project declares `:alambique` with `override: true`, because
`alambique_testkit` (the `testkit` subdirectory of the same repository) depends
on `:alambique` too. With the override both resolve to the pinned release.
`mix deps.tree` shows one Alambique.

## Prerequisites

- The release you want is published as a tag in the public repository. The
  owner announces new releases; do not move the pin on your own.
- Network access to GitHub.
- The tools of the [README](../README.md#requirements) and Docker for the
  SeaweedFS tests.

## Steps

1. Write the new tag in `alambique.ref`:

   ```sh
   echo <tag> > alambique.ref
   ```

2. Update the dependencies of every project that uses it, so that each `mix.lock`
   names the new tag.

   ```sh
   mix deps.update alambique alambique_testkit
   for d in examples/hello-native examples/hello-wasm examples/echo-tcp; do
     (cd $d && mise exec -- mix deps.update alambique alambique_testkit)
   done
   (cd lab/app && mise exec -- mix deps.update alambique)
   ```

3. Check that one Alambique is used and that it is the pinned release:

   ```sh
   mix deps.tree | grep alambique
   git -C deps/alambique describe --tags     # equals alambique.ref
   git diff --stat -- '*mix.lock'           # only the alambique lines changed
   ```

4. Read what changed in Alambique's changelog and documentation, including
   the telemetry: Atanor's checks in `test/support/c1.ex` read
   `[:alambique, :cell, :commit]`, and the cluster testkit forwards the events
   listed in `testkit/lib/atanor_testkit/cluster.ex`. Fix the callers; compile
   with warnings as errors: `mix compile --warnings-as-errors`. A function
   Atanor calls that Alambique removed shows up there as "is undefined or
   private" (0.3.0 dropped the prepared-statement API of `Alambique.Sqlite`).
   Add the new keys of the checked option groups to `@alambique_limits` in
   `lib/atanor/config.ex`: Atanor refuses a key it does not list.

5. Run the suites, in this order. All must pass:

   ```sh
   mise run test            # default, three times
   mise run test:cluster    # peer nodes, three times
   mise run test:native     # Rust tests of the WASM crate
   mise run test:seaweedfs  # against a disposable SeaweedFS
   mise run seaweedfs:down
   ```

   Run `mise run lab:build` when the lab is used; it builds `lab/app` with the
   pinned release. The daemon image takes the same tag: its
   build runs `mix deps.get` against the public repository, with the root `mix.lock`
   ([how to build it](how-to-build-the-release.md)), so a new tag must be published
   before the image can be built.

## Options a new pin leaves alone

The `registry` option (0.6) is off and Atanor does not use `Alambique.peers/1`
yet; it only checks the keys.

The memory (`awake: [cache_kib:, max_bytes:,
max_pending:]`), snapshot, restore and feed options keep Alambique's
defaults, and Atanor checks their keys at start
([design §4.3](design.md#43-limits-on-cell-calls-and-their-errors)). They are
local to each node.

## Troubleshooting

- **`unable to read tree`, `Command "git ... checkout" failed` or a fetch
  error.** The tag is not in the public repository (not published yet), or
  `deps/alambique` is a half-made clone. Remove `deps/alambique` and
  `deps/alambique_testkit` and run `mix deps.get`.
- **Two Alambiques in `mix deps.tree`, or a "dependency conflict" for
  `alambique`.** A project that depends on `alambique_testkit` lacks
  `override: true` on its own `:alambique`.
- **The lock file names an old tag after the edit.** `mix deps.get` keeps
  the lock; use `mix deps.update alambique alambique_testkit` (step 2).
- **`{:error, {:data_dir_in_use, path}}` when a test starts a node.** Since
  Alambique 0.3.0 an instance holds an exclusive lock on `<data_dir>/lock`
  until it stops. Give each instance its own `data_dir`, or stop the first
  one before the second starts.
- **Tests fail with `Alambique.Replication.Native ... is not available`.** The
  native library of Alambique was not built for this release. Run `mix
  deps.compile alambique --force`.

## Next steps

- [design.md §8](design.md#8-cluster) for how Atanor uses the takeover, the drain
  and the migrations.
