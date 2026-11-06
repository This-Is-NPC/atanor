# How to let a hot cell move to a less loaded or a dedicated node

**The question:** How do I let a very busy cell move by itself to a less loaded
node, or to a node I keep for hot cells, see why it did or did not move, and
tune it so that it does not keep moving?

This guide stands alone for someone who already runs a cluster
([how-to-run-a-cluster.md](how-to-run-a-cluster.md)). The design, with the
reasons, is [design §8.15](design.md#815-placement-of-hot-cells).

## What you get

A cell has one writer, on one node, and that stays true: moving a cell does not
make it faster than one writer. What the loop changes is *which* node that is.
When a cell is hot and its node is under CPU pressure, the node moves the cell
to the least loaded node, which leaves the cell's neighbours their CPU back and
gives the cell a node with room. Or you tag a node as dedicated and the hot cells
of a namespace go there.

The same loop can also switch on Alambique's read replicas for a cell that is
read a lot (`replicas: true`), with or without moving cells (`move: false`). That
is a different remedy, for reads: see
[how-to-read-from-replicas.md](how-to-read-from-replicas.md).

It is off by default. A move interrupts the cell for the time of a hibernate
and a wake (the lab measured it, see below), and the thresholds depend on your
hardware, so you turn it on knowing that.

## Prerequisites

- Two or more nodes running the same instance, connected (see the cluster guide).
- The admin API enabled, to look at the state (`admin: [port: ..., token: ...]`).

## Steps

1. Turn the loop on, on every node. The defaults are in
   [design §8.15](design.md#815-placement-of-hot-cells); the three that matter
   first are when a cell is hot, when a node is under pressure, and how long both
   must last.

   ```elixir
   {Atanor,
    name: MyApp.Atanor,
    store: {Alambique.Store.S3, s3_config},
    hot_cells: [
      enabled: true,
      write_enter: 500,   # writes per second that make a cell hot
      cpu_enter: 70,      # percent of the node's schedulers
      sustain_ms: 10_000  # a cell must stay hot this long
    ]}
   ```

   A cell is hot when writes, reads or calls waiting on it (messages in its mailbox plus writes waiting for a commit) reach the `*_enter`
   value, and stays hot until all are under the `*_exit` value. A node gives cells
   away only between `cpu_enter` and `cpu_exit` percent, and only to a node whose
   CPU is at least `margin` points lower (20 by default).

2. Look at what a node sees. `GET /hot-cells` on its admin API shows its CPU,
   the hot cells it serves with their rates and the last decision, the load it
   last heard from its peers, the moves in progress and the last 20 it made.

   ```sh
   curl -s -H "authorization: Bearer $TOKEN" $NODE:4001/hot-cells
   ```

   ```json
   {
     "cpu": 66.2,
     "enabled": true,
     "node": "atanor@10.77.42.12",
     "recent": [],
     "peers": [
       {
         "cpu": 33.0,
         "node": "atanor@10.77.42.11",
         "age_ms": 507,
         "tags": [],
         "hot": 0
       },
       {
         "cpu": 28.8,
         "node": "atanor@10.77.42.13",
         "age_ms": 417,
         "tags": [],
         "hot": 0
       }
     ],
     "hot": [
       {
         "queue": 49,
         "cell": "log.hot-1793594188",
         "hot_ms": 18724,
         "reads": 935.0649350649351,
         "writes": 421.57842157842157,
         "last_decision": "not_pressured"
       }
     ],
     "moving": [],
     "pressured": false,
     "reads_per_s": 935.1,
     "writes_per_s": 421.6
   }
   ```
   
      This is node 2 of the lab, serving one hot cell with `cpu_enter` set to 95 so that
      it stays put. `cpu` is 66%, so the node is not pressured and the last decision
      for the cell is `not_pressured`; `peers` has the CPU of the other two as this
      node last heard it (`age_ms` ago).

3. Dedicate a node (optional). Tag it, and say which namespaces go to a node with
   that tag. Put the same `affinity` on every node: the owner of the cell decides.

   ```elixir
   # on the dedicated node
   hot_cells: [enabled: true, tags: ["dedicated"], affinity: [{"rooms", "dedicated"}]]
   # on the others
   hot_cells: [enabled: true, affinity: [{"rooms", "dedicated"}]]
   ```

   A hot cell in `rooms` moves to the least loaded node tagged `dedicated`,
   whatever the load, and stays there. Other namespaces are never moved to that
   node by the load rule. With no tagged node alive, the load rule decides.

4. Watch the decisions. Attach to the telemetry events
   ([telemetry.md](telemetry.md#placement-of-hot-cells)): `[:atanor, :hot_cell,
   :decision]` says why a hot cell stayed (`:not_pressured`, `:residence`,
   `:cap`, `:cooldown`, `:no_margin`, `:no_target`, `:on_dedicated`) or moved
   (`:load`, `:affinity`), and `[:atanor, :hot_cell, :move]` has the result and
   the duration of each move.

5. Move one by hand to try it, from a remote shell on any node. It uses the same
   path as the loop, so the other nodes see it, and the residence time and the
   cooldown apply to what follows:

   ```elixir
   # replace the instance, the cell and the node name with yours
   Atanor.HotCells.move(MyApp.Atanor, {"rooms", "room-1"}, :"atanor@10.0.0.13")
   ```

   ```text
   {:ok, :"atanor@10.0.0.13"}
   ```

## What stops it from moving all the time

Each of these is an option, and all are checked before a move:

| Mechanism | Option | Default |
| --- | --- | --- |
| A cell is hot for a while before anything happens | `sustain_ms` | 10 s |
| Different thresholds to become hot and to stop being hot | `*_enter`, `*_exit` | see the design |
| The target must be clearly less loaded | `margin` | 20 points of CPU |
| A cell that moved stays | `residence_ms` | 5 min |
| Source and target take part in no other move | `node_cooldown_ms` | 30 s |
| Moves in progress in the cluster | `max_moves` | 1 |

The decision belongs to the node that owns the cell, so two nodes never decide
for one cell. Whatever it decides, Alambique's lease and epoch fencing keep a
single writer.

## What to expect

- While a cell moves, calls for it wait (up to `move_timeout_ms`) and then go to
  the new owner. Sockets stay on their nodes and keep working.
- After a move, a cell that goes to sleep wakes on the node Alambique prefers
  for it (rendezvous hashing), not necessarily where you moved it. The loop moves
  it again if it is hot again after `residence_ms`. A tagged node is the way to
  make a cell stay: its hot cells are moved there every time.
- A node only gives away cells when its CPU is high. A hot cell on an idle node
  is left alone: there is nothing to gain.

## Troubleshooting

- *A hot cell never moves.* Look at `last_decision` in `GET /hot-cells`.
  `not_pressured` means the node's CPU is under `cpu_enter`: lower it, or the cell is
  not what loads the node. `no_margin` means every peer is within `margin` points of
  this node. `no_target` means no peer was heard from in `stale_ms`, or all are
  reserved by an affinity rule for other namespaces.
- *Moves fail with `{:owned, node}`.* A call woke the cell between its hibernate and
  its wake. Calls made through Atanor wait for the move, so this means a call
  that does not go through Atanor reached the cell; report it.
- *A cell moves and moves back.* Raise `residence_ms` or `margin`. Check that the
  nodes have the same options, and that `cpu_exit` is well under `cpu_enter`.
- *The CPU reads 0 or 100 on every node.* The VM may be starved by its host: the
  CPU of the node is the time its schedulers are busy, which includes the time
  they wait for a core.

## Next steps

- [design §8.15](design.md#815-placement-of-hot-cells) for the decision, its reasons and the limits.
- [telemetry.md](telemetry.md#placement-of-hot-cells) for the events.
