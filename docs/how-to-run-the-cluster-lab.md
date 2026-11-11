# How to run the cluster lab

**The question:** How do I run Atanor on three real machines that share one
SeaweedFS, break them on purpose, and measure what clients see?

This guide stands alone for someone with the repository and a Linux machine
with KVM. How the cluster behaves in general is in [how-to-run-a-cluster.md](how-to-run-a-cluster.md).

## What the lab is

Four virtual machines on a private libvirt network, all named `atanor-lab*`:

| Object | What it is |
| --- | --- |
| `atanor-lab` | Isolated libvirt network (`qemu:///system`), bridge `virbr-alab`, `10.77.42.0/24`, no forwarding, no DHCP. The host is `10.77.42.1`. |
| `atanor-lab-1..3` | The Atanor nodes (2 vCPU, 4 GB), `10.77.42.11` to `.13`. They run a release of [lab/app](../lab/app) under systemd. |
| `atanor-lab-store` | SeaweedFS (`weed mini`, 2 GB), `10.77.42.20`, S3 on port 8333, bucket `atanor-lab`. |

The VMs boot the official Arch Linux cloud image, copy-on-write. The release
is built on the host and copied in; the VMs have no internet.

The lab application has one worker, `AtanorLab.Counter`. `POST /c/CELL` with a
number appends it to the log of the cell `CELL`, with the node that ran the
handler, and answers with the row id; `GET /c/CELL` lists the rows and
`GET /c/CELL?count=1` only counts them. A WebSocket on `/c/CELL` takes the frames
`join` (attach to the cell), `w N` (append) and `r` (count). A client
that keeps what it was acknowledged can tell afterwards whether a write was
lost (acknowledged, not in the log) or applied twice (same number twice).

Faults are made inside the VMs (`tc netem`, `date`) or with `virsh` on lab
VMs. Nothing else on the host is touched: not the `default` network, not other
VMs, not the firewall.

## Prerequisites

- Linux with KVM, libvirt running, and your user in the `libvirt` group
  (`virsh -c qemu:///system list` works without `sudo`).
- `virt-install`, `qemu-img`, `xorriso`, `ssh`, `scp`, `curl` (7.75 or later,
  for `--aws-sigv4`) and `tar` on the host. Docker only once, to take the
  `weed` binary out of the image `chrislusf/seaweedfs:4.48`.
- The tools of the [README](../README.md#requirements) (`mise install`), and
  `git` access to the public Alambique repository: `scripts/cluster-context`
  fetches the tag in `alambique.ref` (`ALAMBIQUE_SOURCE` selects another
  URL or a local checkout).
- About 14 GB of free RAM, 4 GB of disk under `/var/tmp`, and a free subnet
  `10.77.42.0/24` (check with `ip -br addr`).
- Internet access for the first run: the image (570 MB) and the Hex packages.
- `mise run docs:lab-dashboard-screenshots` also needs Playwright, as
  [screens.md](screens.md) says.

Disks, seeds, the SSH key, the secret and the cookie live in `/var/tmp/atanor-lab`
(`ATANOR_LAB_DIR` changes it, but it must stay below `/var/tmp/atanor-lab*`),
not under your home, which the `qemu` user cannot read. The downloaded image
is kept in `/var/tmp/atanor-lab/cache`, checked against the publisher's SHA256
file, and used only as the backing file of the VM disks: nothing from it runs
on the host.

## Steps

1. Bring the lab up. It builds the release, downloads and verifies the image,
   creates the network and the VMs, installs SeaweedFS, installs the release
   in the three VMs and waits until every node serves a write through every
   other node.

   ```sh
   mise run lab:up
   ```

   ```text
   [lab:image] $ scripts/lab-image
   image ok: /var/tmp/atanor-lab/cache/Arch-Linux-x86_64-cloudimg-20261101.620452.qcow2
   [lab:network] $ scripts/lab-network
   network atanor-lab up on virbr-alab (10.77.42.1/24)
   [lab:vms] $ scripts/lab-vms
   created atanor-lab-1
   created atanor-lab-2
   created atanor-lab-3
   created atanor-lab-store
   atanor-lab-1 ready at 10.77.42.11
   atanor-lab-2 ready at 10.77.42.12
   atanor-lab-3 ready at 10.77.42.13
   atanor-lab-store ready at 10.77.42.20
   [lab:store] $ scripts/lab-store
   SeaweedFS ready on http://10.77.42.20:8333, bucket atanor-lab
   [lab:nodes] $ scripts/lab-nodes
   {:ok, "0bfb9a6dc8349bf043f2333f81f8bb88169c75442c6a8c49d1a275580756b4bd"}
   {"node":"atanor@10.77.42.11","status":"ok","nodes":["atanor@10.77.42.11","atanor@10.77.42.12","atanor@10.77.42.13"],"workers":1}
   cluster ready: dashboard http://10.77.42.11:4002/workers?token=SECRET
   ```

   The first run takes a few minutes more (image download, first build). The
   `SECRET` is the token of the admin API and the dashboard; it is in
   `/var/tmp/atanor-lab/secret`. The Erlang cookie is another random value, in
   `/var/tmp/atanor-lab/cookie`. A `secret` made by an older version is shorter
   than the 32 bytes that a token on a VM address needs: run `lab:down` first.

2. Look at the cluster. The nodes listen on `10.77.42.11` to `.13`: HTTP on
   4000, the admin API on 4001, the dashboard on 4002.

   ```sh
   secret=$(cat /var/tmp/atanor-lab/secret)
   curl -s -H "authorization: Bearer $secret" 10.77.42.12:4001/cells
   curl -s -H 'host: lab' -X POST --data 7 10.77.42.13:4000/c/hello
   ```

   ```json
   {"total":3,"nodes":{"atanor@10.77.42.11":{"count":1,"status":"ok"},"atanor@10.77.42.12":{"count":0,"status":"ok"},"atanor@10.77.42.13":{"count":2,"status":"ok"}},"partial":false}
   {"node":"atanor@10.77.42.11","id":1}
   ```

   The write went in through node 3 and ran on node 1, which owns the cell
   `hello`. Open the dashboard URL printed by `lab:up` in a browser on the
   host to see the three nodes (see [how-to-open-the-dashboard.md](how-to-open-the-dashboard.md)).

3. Send load by hand. `lab/tools/load.exs` sends writes through the three
   nodes, logs every request, then checks the cells against what was
   acknowledged:

   ```sh
   N=10.77.42.11,10.77.42.12,10.77.42.13
   mise exec -- elixir lab/tools/load.exs run --nodes $N --log /tmp/lab.log --seconds 10
   mise exec -- elixir lab/tools/load.exs report --log /tmp/lab.log
   mise exec -- elixir lab/tools/load.exs verify --nodes $N --log /tmp/lab.log
   ```

   `report` prints outcomes, throughput, p50/p95/p99 of local-owner requests
   (the node that received the request ran the handler) against forwarded
   ones, and the windows in which errors happened. `verify` prints the
   acknowledged writes that are missing (`LOST`) and the rows applied twice
   (`DUPLICATED`). Both should be zero.

4. Run one scenario, or all of them. Without arguments `lab:scenario` lists
   the names.

   ```sh
   mise run lab:scenario                  # the names
   mise run lab:scenario crash graceful_stop
   mise run lab:scenario hot_cell         # one very busy cell, below
   mise run lab:test                      # every scenario, about 70 minutes
   mise run lab:scenario detect           # detection and takeover (below), about 90 minutes
   ```

   The `detect` group measures the failure detector and the takeover
   ([design §12.8](design.md#128-detection-and-takeover-in-the-lab)):
   `detect_destroy`, `detect_kill`, `detect_partition` (node 2 lost three ways,
   with how long node 1 took to see it down and how long its cells took to
   serve again), `detect_destroy_no_takeover` (the same with takeover off),
   `detect_stall` (the beam of node 2 paused for less and more than the
   detection time), `freeze_rejoin` (node 2 frozen past detection and takeover,
   by SIGSTOP of its beam and by suspending its VM, then thawed: time until the
   three nodes see each other `alive`, owner changes after the thaw, lost and
   duplicated writes), `detect_cpu_hog` (processes that compete with the beam
   for the CPU), `detect_clock` (clock skew within and beyond the skew margin),
   `heartbeat_cost` (packets and bytes of the heartbeats on an idle cluster) and
   the two graceful stops. They read these environment variables:

   | Variable | Default | Meaning |
   | --- | --- | --- |
   | `LAB_REPEAT` | 3 | runs of the destroy, kill, partition and freeze faults |
   | `LAB_STALL_SECONDS` | `2 3.5 8` | pauses of the beam of node 2 |
   | `LAB_HOG_SECONDS`, `LAB_HOG_PROCS` | 30, 4 | length and number of CPU hogs |
   | `LAB_SKEWS` | `+1 +5 -5 +20` | seconds of clock skew of node 2 |
   | `LAB_COST_SECONDS` | 60 | idle time measured for the heartbeat cost |
   | `LAB_FREEZE_KINDS` | `stop suspend` | how `freeze_rejoin` freezes node 2: `stop` (SIGSTOP of the beam), `suspend` (`virsh suspend` of the VM) |
   | `LAB_FREEZE_SECONDS` | 20 | length of the freeze (`LAB_REPEAT` runs of each kind) |
   | `LAB_STAMP` | the date | name of the results directory |
   | `LAB_HOT_HTTP`, `LAB_HOT_WS` | 48, 300 | keep-alive HTTP clients and WebSockets of `hot_cell`, spread over the three nodes |
   | `LAB_HOT_WS_THINK` | 500 | milliseconds between the frames of a WebSocket in `hot_cell` |
   | `LAB_HOT_SECONDS` | 60 | length of the load of `hot_cell`, after a 15 s warm-up |
   | `LAB_HOT_CURSORS` | 0 | WebSockets of `hot_cell` that also send a cursor frame, which every WebSocket of the cell receives |
   | `LAB_HOT_CURSOR_MS` | 1000 | milliseconds between the cursor frames of one WebSocket |
   | `LAB_HOT_PLACEMENT` | `off` | `on`: `hot_cell` restarts the nodes with the automatic placement of hot cells on, reports the move and restores the nodes afterwards |
   | `LAB_HOT_HOG`, `LAB_HOT_HOG_AT` | 0, 22 | `1`: two busy loops in the VM of the owner from `LAB_HOT_HOG_AT` s after the baseline window starts, so that only the owner is under CPU pressure |
   | `LAB_HOT_DEDICATED` | none | a node number: that VM is tagged `dedicated` and the hot cells of the namespace go there |
   | `LAB_HOT_BASE_S`, `LAB_HOT_SETTLE_S`, `LAB_HOT_AFTER_S` | 15, 8, 20 | the baseline window, the wait after the move and the window after it |
   | `ATANOR_LAB_HOT_<OPTION>` | | any option of `hot_cells:` as an integer (`ATANOR_LAB_HOT_CPU_ENTER=40`), passed to the nodes with the placement on |
   | `LAB_HOT_PARTITIONS`, `LAB_HOT_KEYS` | 0, 1000 | `3`, `6` or `12`: `hot_cell` splits the cell into that many partitions ([design §4.2](design.md#42-partitioned-cells)); the HTTP clients send a partition key among `LAB_HOT_KEYS` and each WebSocket has its own. Not combined with the placement or the hog |
   | `LAB_HOT_WRITE_RATIO`, `LAB_HOT_WS_WRITE_RATIO` | 0.5, 0.1 | the share of writes among the requests of an HTTP client and of a WebSocket; 0.05 and 0.02 make the load read-heavy |
   | `LAB_HOT_READ_BOUND_MS` | 0 | above 0 the reads of `hot_cell` are bounded requests of that many ms ([design §19.3](design.md#193-bounded-requests-the-reads-that-leave-the-owner)), run by the node they reach; the WebSockets read through HTTP on their own node, because a frame is served by the owner |
   | `LAB_HOT_REPLICAS` | `off` | `on`: the nodes restart with Alambique's read replicas on and the placement loop switching them on for the hot cell (moves off); use `ATANOR_LAB_HOT_REPLICA_ENTER`, `_EXIT` and `ATANOR_LAB_HOT_SUSTAIN_MS` so that it happens within the warm-up. The report counts the bounded reads each node answered from a replica and from the owner |
   | `LAB_HOT_PIPELINE_DEPTH` | Alambique's (8) | the nodes restart with `pipeline_depth` set to this |
   | `LAB_HOT_CURSOR_MODE` | `cell` | how the cursor reaches the sockets: `cell` (a callback on the owner, then `send_to_cell`) or `channel` (the [ephemeral channel](how-to-share-ephemeral-messages.md), no callback on the owner) |

   <a id="hot_cell"></a>`hot_cell` (not part of `lab:test`; about 3 minutes) measures
   what one very busy cell does to its owner. It opens the connections, sends
   writes and reads to a single cell through the three nodes, and writes to
   `hot_cell.txt`: writes and reads per second with p50, p95 and p99 (separately),
   the CPU of each node's service and VM over the load (read from the cgroup and
   `/proc/stat` inside the VM; the owner is the node that ran most handlers), the
   connections each node holds, the check that every acknowledged write is in the
   cell, and a line for the automatic move time (`n/a` with the placement off).
   With `LAB_HOT_PLACEMENT=on` it also takes a baseline window, optionally starts
   a CPU hog on the owner, waits for the move the loop makes by itself (the
   `lab-event hot_cell.move` line in the journals), and reports throughput,
   latency and CPU before the hog, while it is hogged and after the move, and the
   time from the first write to the move. With `LAB_HOT_CURSORS` above 0 it also reports the cursor frames
   sent and delivered and their delivery latency. `lab/tools/load.exs hot` runs
   the load by hand. With `LAB_HOT_PARTITIONS` it sends the same load to the
   partitioned namespaces `p3`, `p6` and `p12` of the lab worker, and the report
   adds the writes by handler node.

   The nodes write the detector events to the journal (`lab-event ...` lines of
   `lab/app`), which the scenarios count; `lab/results/<stamp>/<scenario>.state`
   has what node 1 thought of node 2 every 100 ms.

   Each scenario resets the lab first (VMs running, faults cleared, clocks set
   from the host, three nodes joined), starts the load in the background,
   injects the fault at a known moment, heals it, and writes
   `lab/results/<stamp>/<scenario>.txt` (the report and the verification) next to the
   raw request log `<scenario>.log`. `LAB_STAMP=<name>` chooses `<stamp>`.
   The scenarios and the variables that tune them are listed above.

5. Take the dashboard screenshots (this loses node 3 on purpose and restarts
   it):

   ```sh
   mise run docs:lab-dashboard-screenshots
   ```

   ```text
   docs/img/lab-deployments-three-nodes.png
   docs/img/lab-cells-node-1.png
   ...
   docs/img/lab-cells-node-lost.png
   ```

6. Tear it down. `lab:down` stops and removes the four VMs, their disks and
   seeds, the SSH key, the secret and the cookie, and the network. It refuses any name that
   does not start with `atanor-lab`, and it is safe to run again. The image
   cache stays; `rm -r /var/tmp/atanor-lab` removes it too.

   ```sh
   mise run lab:down
   virsh -c qemu:///system list --all
   virsh -c qemu:///system net-list --all
   ```

   ```text
    Id   Name               State
   -----------------------------------
    -    omakure-r3-linux   shut off

    Name      State    Autostart   Persistent
   --------------------------------------------
    default   active   yes         yes
   ```

   (Your other VMs and networks are listed too; only `atanor-lab*` objects
   are gone.)

## Troubleshooting

- **`lab:vms` says a VM does not answer SSH.** The image waits at boot for
  time synchronization, which an isolated network cannot give. `lab-vms`
  prevents it with a systemd credential that makes `systemd-time-wait-sync`
  return at once. Check that the VM has the console with
  `virsh -c qemu:///system console atanor-lab-1` (Ctrl-] leaves it).
- **Nothing in the VMs can open a TCP connection to the host.** This host
  drops TCP from the lab bridge to itself (ICMP works), and the lab does not
  change the host firewall. That is why SeaweedFS runs in a VM and not in a
  container on the host.
- **`virt-install` cannot read the disk.** Disks must be where the `qemu` user
  can traverse: `/var/tmp/atanor-lab`, not a home directory.
- **The release does not start in a VM (`GLIBC_2.xx not found`).** The release
  is built on the host and needs a glibc no newer than the image's. The
  Arch image of 2026-10-15 and the host had glibc 2.44. Pin an image whose
  glibc is at least the host's (`LAB_IMAGE` in `scripts/lab-common`), or build
  the release in a container of the image's distribution.
- **`lab:nodes` waits forever for the health check.** Look at the service in a
  VM: `ssh -i /var/tmp/atanor-lab/ssh/id_ed25519 lab@10.77.42.11 sudo journalctl -u atanor-lab`.
- **A scenario stopped half way.** Faults live in the VMs; the next scenario
  (or `lab:scenario` with any name) clears them first. `mise run lab:down`
  removes everything.

## Next steps

- [how-to-run-a-cluster.md](how-to-run-a-cluster.md) and
  [design.md §8](design.md#8-cluster) for how routing and failover work.
- [design §8.10](design.md#810-acting-on-a-confirmed-failure) and [§8.13](design.md#813-a-handler-that-outlives-its-cell) for the limits the lab found.
