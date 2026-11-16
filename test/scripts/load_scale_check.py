#!/usr/bin/env python3
"""Drives the scale measure of scripts/load-run with a stub `docker`, `load-env`, balancer and generator: no container is started.

Usage: load_scale_check.py WORKDIR. Prints one JSON object (test/scripts/load_scale_test.exs asserts it).
The stub lab holds CAP req/s per node: a step above CAP x nodes has a p99 of 900 ms and fails.
"""
import argparse
import importlib.machinery
import importlib.util
import json
import os
import stat
import sys
import threading
import time

sys.dont_write_bytecode = True
work = sys.argv[1]
repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
fake = os.path.join(work, "fake")
os.makedirs(fake, exist_ok=True)

DOCKER = """#!/bin/sh
case "$1" in
  inspect)
    if [ -e "$FAKE_DIR/inspect-$2.json" ]; then cat "$FAKE_DIR/inspect-$2.json"; else echo "Error: No such object: $2" >&2; echo "[]"; exit 1; fi ;;
  logs) echo "node log" ;;
  *) exit 1 ;;
esac
"""
LOAD_ENV = """#!/bin/sh
[ "$1" = add-node ] || exit 1
sleep 0.2
echo "$2" > "$FAKE_DIR/nodes"
echo "node-$2 ready"
"""
for name, body in (("docker", DOCKER), ("load-env", LOAD_ENV)):
    path = os.path.join(fake, name)
    with open(path, "w") as file:
        file.write(body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
os.environ["PATH"] = fake + os.pathsep + os.environ["PATH"]
os.environ["FAKE_DIR"] = fake

MB, CAP, RATE = 1048576, 100, 2000
spec = importlib.util.spec_from_loader("load_run", importlib.machinery.SourceFileLoader("load_run", f"{repo}/scripts/load-run"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.HERE, m.ROOT, m.CORES = fake, work, 8

lab = {"nodes": 1, "running": False, "busy_at": None, "force_busy": False, "cells_mode": "rebalance", "runtime": {}, "req": {}, "last": None, "seen": {}, "errors": 0,
       "resets": []}
lock = threading.Lock()


def running(ident, **state):
    body = {"Running": True, "OOMKilled": False, "ExitCode": 0, "StartedAt": "2026-01-01T00:00:00Z", **state}
    with open(os.path.join(fake, f"inspect-{ident}.json"), "w") as file:
        json.dump([{"Id": ident, "State": body, "RestartCount": 0}], file)


def current_nodes():
    path = os.path.join(fake, "nodes")
    return int(open(path).read()) if os.path.exists(path) else lab["nodes"]


def info_of(count):
    nodes = [{"id": f"n{i}", "name": f"node-{i}", "ip": "127.0.0.1", "pid": os.getpid()} for i in range(1, count + 1)]
    for node in nodes:
        running(node["id"])
    return {"scenario": "A", "memory_limit_bytes": 512 * MB, "store_latency_ms": 25, "store_backing": "tmpfs", "node": nodes[0], "nodes": nodes,
            "store": {"id": "store-id", "ip": "127.0.0.1", "pid": os.getpid()}, "lb": {"id": "lb", "pid": os.getpid()},
            "http": "http://127.0.0.1:8080", "stats": "http://127.0.0.1:1/stats;csv", "admin": "http://127.0.0.1:1"}


def fresh_cluster(nodes):
    lab.update(nodes=nodes, running=False, req={}, last=None, seen={}, errors=0)
    lab["resets"].append(nodes)
    path = os.path.join(fake, "nodes")
    if os.path.exists(path):
        os.remove(path)
    return info_of(nodes)


def spread_sample(info):
    """The balancer's counters and the cells of the stub lab: requests split over the nodes in rotation, cells moving to an equal split after a join."""
    with lock:
        now, count = time.time(), current_nodes()
        names = [f"node-{i}" for i in range(1, count + 1)]
        dt, lab["last"] = now - (lab["last"] or now), now
        for name in names:
            lab["req"][name] = lab["req"].get(name, 0) + int(dt * RATE / count)
            lab["seen"].setdefault(name, now)
        if count == 1:
            lab["errors"] += 1  # the lone node refuses: 5xx until another one is in rotation
        f = 0.0 if lab["cells_mode"] == "none" or count == 1 else min(1.0, (now - lab["seen"][names[-1]]) / 0.6)
        if lab["cells_mode"] == "missing":
            cells = None
        elif count == 1:
            cells = {"node-1": 40}
        else:
            before, after = 40 / (count - 1), 40 / count
            cells = {n: round(before + f * (after - before)) for n in names[:-1]} | {names[-1]: round(f * after)}
        return {"requests": dict(lab["req"]), "cells": cells, "backend": {"stot": sum(lab["req"].values()), "hrsp_5xx": lab["errors"], "econ": 0, "eresp": 0, "wretr": 0, "wredis": 0}}


ticks = {"total": 0, "idle": 0}


def host_sample():  # cumulative ticks, one second of the host per call
    busy = 2.5 if lab["force_busy"] or (lab["running"] and lab["busy_at"] == lab["nodes"]) else 0.2
    ticks["total"] += 100 * m.CORES
    ticks["idle"] += round(100 * (m.CORES - busy))
    return {"cpu_total": ticks["total"], "cpu_idle": ticks["idle"], "loadavg1": 0.0, "available_gb": 8.0, "swap_used_mb": 0}


def load_env(*args):
    if args[0] == "info":
        return json.dumps(info_of(current_nodes()))
    if args[0] == "reset":
        fresh_cluster(lab["nodes"])
    return ""


DOCUMENT = {"statuses": {"200": 10}, "hist": {"5": 10}, "max_ms": 1.0, "planned": 10, "sent": 10, "completed": 10, "cpu_s": 0.1, "lag_ms": {"p99": 1}, "opened": 10}


def run_generators(self, value, sampler):
    lab["running"] = True
    if self.stem == "scale-join":
        time.sleep(self.args.step_s)
        return [dict(DOCUMENT, statuses={"200": 90, "503 retry-after": 10})]
    return [dict(DOCUMENT, hist={"9000" if value > CAP * len(self.info["nodes"]) else "5": 10})]


m.fresh_cluster, m.load_env, m.spread_sample, m.host_sample = fresh_cluster, load_env, spread_sample, host_sample
m.Round.run_generators = run_generators
m.cgroup_dir = lambda pid: work + "/no-cgroup"
m.cgroup_sample = lambda d: {"memory_current": 300 * MB, "shmem": 1, "inactive_file": 0, "peak": 300 * MB, "limit": 1280 * MB, "cpu_s": 0.0, "throttled_s": 0.0, "cpu_limit": 1.0,
                             "swap_current": 0}
m.process_cpu, m.fds, m.s3_counters = lambda pid: 0.0, lambda node: None, lambda ip: None
m.admin_json = lambda info, path, timeout: lab["runtime"] if path == "/runtime" else None


def make_args(out, **over):
    values = dict(out=out, measure="scale", step_s=1.0, timeout=1.0, gen_grace=1.0, open_rate=100.0, host_load_max=1.0, min_available_gb=0.0, sample_s=0.05, quiet_window=0.0,
                  quiet_max_wait=2.0, delivery=0.95, memory_pct=1e9, fd_pct=1e9, p99_ms=250.0, max_generator_swap_mb=1e9, max_host_swap_growth_mb=1e12, max_refused_pct=1.0,
                  max_lag_ms=50.0, max_throttle_jump_ms=5000.0, command="test", steps=None, start=None, max=None, factor=2, refine=0, no_confirm=False,
                  max_store_tmpfs_pct=90.0, max_store_disk_pct=90.0, rate_per_proc=600.0, conns_per_rate=0.5, write_ratio=0.5, cells=64, worker="native", cell_period=10.0,
                  cells_conns=64, ws_interval=30.0, max_nodes=3, loads="http-native", scale_factor=1.25, ceilings="", factors="0.75,1,1.25,1.5", no_join=True, join_rate=None,
                  join_factor=1.5, join_warmup_s=0.3, join_observe_s=1.2, join_node_wait_s=0.2, join_node_timeout_s=10.0, join_sample_s=0.05, spread_tol_pct=25.0,
                  spread_hold=3, spread_min_cells=10)
    values.update(over)
    os.makedirs(out, exist_ok=True)
    return argparse.Namespace(**values)


def files_of(out):
    return sorted(f for f in os.listdir(out) if f.endswith(".json"))


results = {}

# The pure parts: the gain over one node, the steps of a ceiling, the ceilings of an earlier round.
results["gain"] = {str(k): v for k, v in m.gain({1: 400, 2: 760, 3: 1100}).items()}
results["gain_no_base"] = m.gain({2: 760})
results["steps_of"] = [m.steps_of(400, [0.75, 1, 1.25, 1.5]), m.steps_of(1, [0.75, 1, 1.25]), m.steps_of(300, [1, 1])]
results["parse_ceilings"] = {f"{k[0]}:{k[1]}": v for k, v in m.parse_ceilings("http-native:1=400,cells:2=9000").items()}

# The spread: an equal split is 0; each node within the tolerance for `hold` consecutive readings starts the spread; a short good run does not.
names = ["node-1", "node-2"]
results["deviation"] = [m.deviation({"node-1": 50, "node-2": 50}, names), m.deviation({"node-1": 75, "node-2": 25}, names), m.deviation({"node-1": 100}, names), m.deviation({}, names)]
lone, even, skew = {"node-1": 100, "node-2": 0}, {"node-1": 52, "node-2": 48}, {"node-1": 80, "node-2": 20}
results["spread_time"] = {
    "held": m.spread_time([(0, lone), (1, skew), (2, even), (3, even), (4, even), (5, even)], names, 0.25, 3, 10),
    "short": m.spread_time([(0, lone), (1, even), (2, even), (3, skew), (4, even), (5, even)], names, 0.25, 3, 10),
    "never": m.spread_time([(0, lone), (1, skew), (2, skew)], names, 0.25, 3, 10),
    "too_few": m.spread_time([(0, {"node-1": 3, "node-2": 3})] * 5, names, 0.25, 3, 10),
}
series = [(0, {"node-1": 0, "node-2": 0}), (1, {"node-1": 10, "node-2": 0}), (2, {"node-1": 20, "node-2": 10}), (3, None), (4, {"node-1": 5})]
results["interval_points"] = m.interval_points(series, names)
samples = [{"spread": {"requests": {"node-1": 100, "node-2": 0, "node-3": 0}, "cells": {"node-1": 5}}},
           {"spread": {"requests": {"node-1": 300, "node-2": 100, "node-3": 0}, "cells": {"node-1": 30, "node-2": 10}}}, {"spread": None}]
results["distribution"] = m.distribution(samples, ["node-1", "node-2"])
results["distribution_none"] = [m.distribution([{"t": 1}], ["node-1"]), m.distribution(samples, [])]

# The balancer's CSV and the admin API's /cells are read by name; what is missing is None.
real_urlopen = m.urllib.request.urlopen


class Reply:
    def __init__(self, text):
        self.text = text

    def read(self):
        return self.text.encode()


CSV = ("# pxname,svname,qcur,qmax,scur,smax,slim,stot,bin,bout,dreq,dresp,ereq,econ,eresp,wretr,wredis,hrsp_5xx\n"
       "atanor_http,node1,0,0,0,0,,120,0,0,,0,,0,0,0,0,0\natanor_http,node2,0,0,0,0,,80,0,0,,0,,0,0,0,0,0\natanor_http,node3,0,0,0,0,,x,0,0,,0,,0,0,0,0,0\n"
       "atanor_http,BACKEND,0,0,0,0,,200,0,0,0,0,,1,2,3,4,5\nhttp,FRONTEND,0,0,0,0,,999,0,0,0,0,,0,0,0,0,0\n")
m.urllib.request.urlopen = lambda url, timeout=None: Reply(CSV)
stats = m.haproxy_stats("http://x")
m.urllib.request.urlopen = lambda url, timeout=None: (_ for _ in ()).throw(OSError("down"))
results["haproxy"] = {"requests": m.requests_by_node(stats), "backend": m.backend_counters(stats), "down": m.haproxy_stats("http://x"), "none": m.requests_by_node(None)}
m.urllib.request.urlopen = real_urlopen
real_admin = m.admin_json
m.admin_json = lambda info, path, timeout: {"nodes": {"atanor@node-1.cluster": {"count": 7, "status": "ok"}, "atanor@node-2.cluster": {"status": "error"}}, "total": 7}
results["cells_by_node"] = [m.cells_by_node({}), None]
m.admin_json = lambda info, path, timeout: ["unexpected"]
results["cells_by_node"][1] = m.cells_by_node({})
m.admin_json = real_admin

# The generators go to the balancer in a scale step, to the node otherwise.
probe_args = make_args(os.path.join(work, "target"), measure="http-native")
probe = m.Round(probe_args, info_of(1), stem="scale-http-native-n1")
plain = m.Round(probe_args, info_of(1))
results["target"] = [list(probe.target()), list(plain.target()), probe.gen_commands(100)[0][2:6]]


# A cluster ramp: the ceiling of N nodes is CAP x N; a larger configuration starts at the ceiling of one node fewer; the gain follows.
def run_scale(name, busy_at=None, **over):
    out = os.path.join(work, name)
    lab.update(busy_at=busy_at, cells_mode="rebalance", runtime={}, resets=[])
    args = make_args(out, **over)
    summary = m.scale(args)
    m.write_json(os.path.join(out, "A_scale.summary.json"), {**summary, "scenario": "A", "measure": "scale", "command": "test"})  # what main() writes
    return summary, out


summary, out = run_scale("ramp", steps="50,100,200")
results["ramp"] = {"ceilings": {k: {str(n): v for n, v in c.items()} for k, c in summary["ceilings"].items()},
                   "gain": {str(n): g for n, g in summary["gain"]["http-native"].items()}, "largest_fit": summary["largest_fit"], "invalid": summary["invalid"],
                   "advice": summary["advice"], "join_note": summary["join_note"], "approved": [c["approved"] for c in summary["configs"]],
                   "confirmed": [c["confirmed"] for c in summary["configs"]], "stopped_by": [c["stopped_by"] for c in summary["configs"]],
                   "distribution": summary["configs"][1]["distribution"], "files": [f for f in files_of(out) if "scale-http-native-n3" in f][:2],
                   "records": []}
for file in files_of(out):
    with open(os.path.join(out, file)) as handle:
        record = json.load(handle)
    if record.get("schema") == m.SCHEMA:
        results["ramp"]["records"].append([record["measure"], record["load"], record["nodes"], record["phase"], record["status"]])
results["ramp"]["exit"] = m.exit_status("scale", summary)
results["ramp"]["dir"] = out

# --max-nodes: no configuration above it is started, and the join has one node fewer.
summary, out = run_scale("max_nodes", steps="50,100,200", max_nodes=2, no_join=False)
results["max_nodes"] = {"resets": sorted(set(lab["resets"])), "configs": [[c["load"], c["nodes"]] for c in summary["configs"]], "join_nodes": summary["join"]["windows"][-1]["nodes"],
                        "largest_fit": summary["largest_fit"], "advice": summary["advice"]}

# The host over its limit at 3 nodes: that step is INVALID, the larger ones are not run and the largest that fit is recorded.
summary, out = run_scale("invalid", steps="50,100,200", busy_at=3, no_join=True)
step3 = [json.load(open(os.path.join(out, f))) for f in files_of(out) if "scale-http-native-n3" in f and "summary" not in f]
results["invalid"] = {"invalid": summary["invalid"], "invalids": summary["invalids"], "largest_fit": summary["largest_fit"], "advice": summary["advice"],
                      "statuses": [s["status"] for s in step3], "valid": [s["valid"] for s in step3], "ceilings": sorted(summary["ceilings"]["http-native"]),
                      "exit": m.exit_status("scale", summary), "join_note": summary["join_note"]}

# Nothing fits: the first configuration is INVALID, no second one starts.
summary, out = run_scale("invalid_one", steps="50,100,200", busy_at=1)
results["invalid_one"] = {"largest_fit": summary["largest_fit"], "configs": [c["nodes"] for c in summary["configs"]], "resets": sorted(set(lab["resets"])), "advice": summary["advice"]}

# The exploration round: the steps are fractions of the ceilings of an earlier round, a configuration without a ceiling is skipped, no confirmation.
summary, out = run_scale("explore", ceilings="http-native:1=100,http-native:2=200", factors="0.5,1,1.5", refine=0, no_confirm=True, max_nodes=3)
results["explore"] = {"configs": [[c["nodes"], c.get("good"), c.get("approved"), c.get("skipped")] for c in summary["configs"]],
                      "gain": {str(n): g["gain"] for n, g in summary["gain"]["http-native"].items()},
                      "steps": sorted(f.split("_", 2)[2] for f in files_of(out) if "scale-http-native-n2" in f)}

# The cells load runs through the same machinery.
summary, out = run_scale("cells", loads="cells", steps="50,100,200", max_nodes=2)
results["cells"] = {"loads": sorted({c["load"] for c in summary["configs"]}), "approved": [c["approved"] for c in summary["configs"]], "join_note": summary["join_note"]}

# A node of three dies during a step: the step fails and says which node; the others are not blamed.
container_info = info_of(3)
lab.update(nodes=3, running=False)
dying = make_args(os.path.join(work, "dies"), measure="http-native", steps="10")
dying_round = m.Round(dying, container_info, stem="scale-http-native-n3")
real_run = m.Round.run_generators
m.Round.run_generators = lambda self, value, sampler: (running("n2", Running=False, OOMKilled=True, ExitCode=137), [dict(DOCUMENT)])[1]
record = dying_round.step(10, "ramp")
m.Round.run_generators = real_run
results["node_dies"] = {"status": record["status"], "reason": record["stop_reason"], "node_stopped": record["node_stopped"], "nodes": record["nodes"], "measure": record["measure"],
                        "diagnostics": len(record["diagnostics"]), "files": [f for f in os.listdir(dying.out) if f.endswith(".node.log")]}


# The join: the load runs at a fixed rate on one node, node 2 starts, and the time until the requests and the cells are spread is measured.
def run_join(name, mode="rebalance", runtime=None, busy_at=None, force_busy=False, nodes=2, **over):
    out = os.path.join(work, name)
    lab.update(busy_at=busy_at, force_busy=force_busy, cells_mode=mode, runtime=runtime if runtime is not None else {})
    try:
        return m.join(make_args(out, **over), RATE, nodes), out
    finally:
        lab["force_busy"] = False


record, out = run_join("join", runtime={"rebalance": {"moves": 3}})
window = record["windows"][1]
results["join"] = {"status": record["status"], "windows": [w["nodes"] for w in record["windows"]], "requests_spread_s": window["requests_spread_s"], "cells_spread_s": window["cells_spread_s"],
                   "ready_s": window["ready_s"], "requests_share_end": window["request_share_end"], "cells_share_end": window["cells_share_end"],
                   "rebalance": window["rebalance"], "errors_before": record["windows"][0]["backend"]["hrsp_5xx"], "generator": record["generator"]["status_503"],
                   "file": [f for f in files_of(out) if "scale-join" in f], "notes": record["notes"], "since_ready": window["requests_spread_since_ready_s"]}
record, _ = run_join("join_none", mode="none")
window = record["windows"][1]
results["join_no_rebalance"] = {"status": record["status"], "requests_spread": window["requests_spread_s"] is not None, "cells_spread_s": window["cells_spread_s"],
                                "cells_share_end": window["cells_share_end"], "rebalance": window["rebalance"], "notes": record["notes"]}
record, _ = run_join("join_missing", mode="missing")
window = record["windows"][1]
results["join_missing_fields"] = {"status": record["status"], "cells_spread_s": window["cells_spread_s"], "cells_share_end": window["cells_share_end"],
                                  "requests_spread": window["requests_spread_s"] is not None}
record, _ = run_join("join_busy", force_busy=True, quiet_max_wait=0.3)
results["join_busy"] = {"status": record["status"], "valid": record["valid"], "reason": record["stop_reason"]}
record, _ = run_join("join_contaminated", busy_at=1, host_load_max=1.0, quiet_max_wait=2.0)
results["join_contaminated"] = {"status": record["status"], "reason": record["stop_reason"]}
real_cluster = m.fresh_cluster
m.fresh_cluster = lambda nodes: (_ for _ in ()).throw(m.LabError("the lab did not start with 1 nodes"))
record, _ = run_join("join_lab")
m.fresh_cluster = real_cluster
results["join_lab"] = {"status": record["status"], "reason": record["stop_reason"]}
print(json.dumps(results))
