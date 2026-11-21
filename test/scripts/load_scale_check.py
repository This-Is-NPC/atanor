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
import shutil
import stat
import subprocess
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

lab = {"nodes": 1, "running": False, "busy_at": None, "force_busy": False, "cells_mode": "rebalance", "runtime": {"versions": {"atanor": "0.7.0", "alambique": "0.14.0"}}, "req": {}, "last": None, "seen": {}, "errors": 0,
       "resets": [], "silent": set()}
lock = threading.Lock()


def running(ident, **state):
    body = {"Running": True, "OOMKilled": False, "ExitCode": 0, "StartedAt": "2026-01-01T00:00:00Z", **state}
    with open(os.path.join(fake, f"inspect-{ident}.json"), "w") as file:
        json.dump([{"Id": ident, "State": body, "RestartCount": 0}], file)


def current_nodes():
    path = os.path.join(fake, "nodes")
    return int(open(path).read()) if os.path.exists(path) else lab["nodes"]


def info_of(count):
    nodes = [{"id": f"n{i}", "name": f"node-{i}", "ip": f"127.0.0.{i}", "pid": os.getpid()} for i in range(1, count + 1)]
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
        for name in names:  # a fixed share per reading, not per elapsed time: a step of the stub is instant on a fast runner
            lab["req"][name] = lab["req"].get(name, 0) + RATE // 20 // count
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
def runtime_now():
    """lab["runtime"], or what it returns when it is a function (a /runtime that changes between readings)."""
    return lab["runtime"]() if callable(lab["runtime"]) else lab["runtime"]


def runtime_for(info, reader):
    """/runtime of the node at info["admin"]: lab["by_ip"](ip, reader) when set (nodes that differ), else runtime_now()."""
    ip = info["admin"].split("//")[1].split(":")[0]
    return lab["by_ip"](ip, reader) if lab.get("by_ip") else runtime_now()


def admin_get(info, path, timeout):
    """/runtime of the stub lab; a node whose address is in lab["silent"] times out."""
    if path != "/runtime":
        return None, "not found"
    return (None, "TimeoutError: timed out") if info["admin"].split("//")[1].split(":")[0] in lab["silent"] else (runtime_for(info, "get"), None)


m.admin_json = lambda info, path, timeout: runtime_for(info, "json") if path == "/runtime" else None
m.admin_get = admin_get
lab["silent"] = set()


def make_args(out, **over):
    values = dict(out=out, measure="scale", step_s=1.0, timeout=1.0, gen_grace=1.0, open_rate=100.0, host_load_max=1.0, min_available_gb=0.0, sample_s=0.05, quiet_window=0.0,
                  quiet_max_wait=2.0, delivery=0.95, memory_pct=1e9, fd_pct=1e9, p99_ms=250.0, max_generator_swap_mb=1e9, max_host_swap_growth_mb=1e12, max_refused_pct=1.0,
                  max_lag_ms=50.0, max_throttle_jump_ms=5000.0, max_store_stall_ms=1000.0, store_stall_requests=10, max_busy_share=0.85, command="test", steps=None, start=None, max=None, factor=2, refine=0, no_confirm=False, descents=0,
                  max_store_tmpfs_pct=90.0, max_store_disk_pct=90.0, no_warmup=False, rate_per_proc=600.0, conns_per_rate=0.5, write_ratio=0.5, cells=64, worker="native", cell_period=10.0,
                  cells_conns=64, ws_interval=30.0, max_nodes=3, loads="http-native", scale_factor=1.25, ceilings="", factors="0.75,1,1.25,1.5", no_join=True, join_rate=None,
                  join_factor=1.5, join_warmup_s=0.3, join_observe_s=1.2, join_node_wait_s=0.2, join_node_timeout_s=10.0, join_sample_s=0.05, spread_tol_pct=25.0,
                  spread_hold=3, spread_min_cells=10, scenario="A")
    values.update(over)
    os.makedirs(out, exist_ok=True)
    return argparse.Namespace(**values)


def files_of(out):
    """The JSON files under `out` (OUT/SCENARIO/MEASURE[/VARIANT]/step-VALUE.json ...), relative, in the order of the steps."""
    found = [os.path.relpath(os.path.join(d, f), out) for d, _, names in os.walk(out) for f in names if f.endswith(".json")]

    def order(path):
        with open(os.path.join(out, path)) as handle:
            return (json.load(handle).get("step") or 0, path)

    return sorted(found, key=order)


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
def versions_by_ip(ip, reader):
    """Node 2 runs another Alambique than the rest, so the report must list every node."""
    return {"versions": {"atanor": "0.7.0", "alambique": "0.14.1" if ip.endswith(".2") else "0.14.0"}}


def run_scale(name, busy_at=None, **over):
    out = os.path.join(work, name)
    lab.update(busy_at=busy_at, cells_mode="rebalance", runtime={}, resets=[], by_ip=versions_by_ip)
    args = make_args(out, **over)
    summary = m.scale(args)
    lab["by_ip"] = None
    m.write_json(m.result_file(args, "A", "scale", "summary"), {**summary, "scenario": "A", "measure": "scale", "command": "test"})  # what main() writes
    return summary, out


summary, out = run_scale("ramp", steps="50,100,200")
results["ramp"] = {"ceilings": {k: {str(n): v for n, v in c.items()} for k, c in summary["ceilings"].items()},
                   "gain": {str(n): g for n, g in summary["gain"]["http-native"].items()}, "largest_fit": summary["largest_fit"], "invalid": summary["invalid"],
                   "advice": summary["advice"], "join_note": summary["join_note"], "approved": [c["approved"] for c in summary["configs"]],
                   "confirmed": [c["confirmed"] for c in summary["configs"]], "stopped_by": [c["stopped_by"] for c in summary["configs"]],
                   "distribution": summary["configs"][1]["distribution"], "files": [f for f in files_of(out) if "http-native-n3" in f][:2],
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
step3 = [json.load(open(os.path.join(out, f))) for f in files_of(out) if "http-native-n3" in f and "summary" not in f]
results["invalid"] = {"invalid": summary["invalid"], "invalids": summary["invalids"], "largest_fit": summary["largest_fit"], "advice": summary["advice"],
                      "statuses": [s["status"] for s in step3], "valid": [s["valid"] for s in step3], "ceilings": sorted(summary["ceilings"]["http-native"]),
                      "exit": m.exit_status("scale", summary), "join_note": summary["join_note"]}

# The host's cores run out at 2 nodes (2.5 busy cores of 8 against a share of 0.2): INVALID, whatever the foreign load.
summary, out = run_scale("saturated", steps="50,100,200", busy_at=2, host_load_max=100.0, max_busy_share=0.2)
results["saturated"] = {"invalid": summary["invalid"], "largest_fit": summary["largest_fit"], "ceilings": sorted(summary["ceilings"]["http-native"])}

# Nothing fits: the first configuration is INVALID, no second one starts.
summary, out = run_scale("invalid_one", steps="50,100,200", busy_at=1)
results["invalid_one"] = {"largest_fit": summary["largest_fit"], "configs": [c["nodes"] for c in summary["configs"]], "resets": sorted(set(lab["resets"])), "advice": summary["advice"]}

# The exploration round: the steps are fractions of the ceilings of an earlier round, a configuration without a ceiling is skipped, no confirmation.
summary, out = run_scale("explore", ceilings="http-native:1=100,http-native:2=200", factors="0.5,1,1.5", refine=0, no_confirm=True, max_nodes=3)
results["explore"] = {"configs": [[c["nodes"], c.get("good"), c.get("approved"), c.get("skipped")] for c in summary["configs"]],
                      "gain": {str(n): g["gain"] for n, g in summary["gain"]["http-native"].items()},
                      "steps": [os.path.basename(f) for f in files_of(out) if "http-native-n2" in f]}

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
                        "diagnostics": len(record["diagnostics"]), "files": [f for f in os.listdir(dying_round.case_dir()) if f.endswith(".node.log")]}


# The join: the load runs at a fixed rate on one node, node 2 starts, and the time until the requests and the cells are spread is measured.
def run_join(name, mode="rebalance", runtime=None, busy_at=None, force_busy=False, nodes=2, silent=(), **over):
    out = os.path.join(work, name)
    lab.update(busy_at=busy_at, force_busy=force_busy, cells_mode=mode, runtime=runtime if runtime is not None else {}, silent=set(silent))
    try:
        return m.join(make_args(out, **over), RATE, nodes), out
    finally:
        lab.update(force_busy=False, silent=set())


record, out = run_join("join", runtime={"rebalance": {"moves": 3, "total": {"moved": 7}}})
window = record["windows"][1]
results["join_series"] = {"lone": [(e["new_5xx"], e["moved"]) for e in record["windows"][0]["samples"]][:2], "joined": [(e["new_5xx"], e["moved"], e["moved_new"]) for e in window["samples"]][-1],
                          "in_band_s": window["cells_in_band_s"], "first_window_in_band": record["windows"][0]["cells_in_band_s"]}
reads = [{"t": 10.0, "backend": {"hrsp_5xx": 2}, "rebalance": {"node-1": {"total": {"moved": 1}}, "node-2": None}},
         {"t": 12.0, "backend": {"hrsp_5xx": 5}, "rebalance": {"node-1": {"total": {"moved": 4}}, "node-2": {"moved": 2}}}, {"t": 14.0}]
results["window_series"] = m.window_series(reads, 10.0)
results["join"] = {"status": record["status"], "windows": [w["nodes"] for w in record["windows"]], "requests_spread_s": window["requests_spread_s"], "cells_spread_s": window["cells_spread_s"],
                   "ready_s": window["ready_s"], "requests_share_end": window["request_share_end"], "cells_share_end": window["cells_share_end"],
                   "rebalance": window["rebalance"], "errors_before": record["windows"][0]["backend"]["hrsp_5xx"], "generator": record["generator"]["status_503"],
                   "file": [f for f in files_of(out) if "join" in f and not f.endswith(".runtime.json")], "notes": record["notes"], "since_ready": window["requests_spread_since_ready_s"]}
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
record, _ = run_join("join_saturated", busy_at=1, host_load_max=100.0, max_busy_share=0.2)
results["join_saturated"] = {"status": record["status"], "valid": record["valid"], "reason": record["stop_reason"], "busy": record["host"]["busy_cores_mean"]}
# A step on two nodes records every node's CPU throttling, in-flight maximum and refusals (not only node-1's), and attributes the 503 answers
# to the refusals counted by both nodes: 10 answers, 3 + 4 counted, 3 unattributed. Cells awake at the start are read too.
counts, tick = {}, {"n": 0}


def by_ip(ip, reader):
    counts[ip, reader] = counts.get((ip, reader), 0) + 1
    first = counts[ip, reader] == 1
    node_two = ip.endswith(".2")
    return {"admission": {"in_flight": 0 if first else (9 if node_two else 4), "refused": {"wake_gate": 0 if first else (4 if node_two else 3), "busy": 0},
                          "disk_used_bytes": 10 * MB, "disk_budget_bytes": 100 * MB}}


def two_node_cgroup(directory):
    tick["n"] += 1
    return {"memory_current": 300 * MB, "shmem": 1, "inactive_file": 0, "peak": 300 * MB, "limit": 1280 * MB, "cpu_s": 0.0,
            "throttled_s": 0.0 if directory == "d1" else tick["n"] * 0.01, "cpu_limit": 1.0, "swap_current": 0}


def two_node_step(name, reader, reasons=None):
    """One step on two stub nodes whose /runtime is `reader(ip, kind)`; the generator saw `reasons` of its 503 answers (by body reason)."""
    real_cgroup, real_dirs, real_get = m.cgroup_sample, m.lab_dirs, m.Round.run_generators
    m.cgroup_sample, m.lab_dirs = two_node_cgroup, lambda info: {"node": "d1", "store": "s", "lb": "l", "extra1": "d2"}
    m.Round.run_generators = lambda self, value, sampler: (time.sleep(0.3), [dict(DOCUMENT, statuses={"200": 90, "503 retry-after": 10}, reasons_503=reasons or {})])[1]
    lab.update(by_ip=reader, runtime={}, silent=set(), busy_at=None, force_busy=False, nodes=2)
    two_args = make_args(os.path.join(work, name), measure="http-native", steps="10")
    real_awake, m.cells_awake = m.cells_awake, lambda info: 7
    try:
        return m.Round(two_args, info_of(2), stem="scale-http-native-n2").step(10, "ramp")
    finally:
        m.cgroup_sample, m.lab_dirs, m.Round.run_generators, m.cells_awake = real_cgroup, real_dirs, real_get, real_awake
        lab["by_ip"] = None


two_record = two_node_step("two", by_ip)
results["two_nodes"] = {"per_node": two_record["per_node"], "refusals": two_record["refusals"], "notes": two_record["notes"], "evictions": two_record["evictions"],
                        "series_nodes": sorted(two_record["series"][-1]["nodes"]), "disk": two_record["admission"]["disk_used_max_pct_of_budget"]}

# The counters a newer node adds: `refused.unavailable` (a refusal cause, so those 503 answers are attributed), `unavailable_by_reason` and the
# top-level `wakes`, each as growth over the step. Node 2 reports none of them (null, not 0) and has another disk budget (a note).
counts_new = {}


def by_ip_new(ip, reader):
    counts_new[ip, reader] = counts_new.get((ip, reader), 0) + 1
    first = counts_new[ip, reader] == 1
    if ip.endswith(".2"):
        return {"admission": {"in_flight": 0, "refused": {"busy": 0}, "disk_used_bytes": 10 * MB, "disk_budget_bytes": 200 * MB}}
    return {"versions": {"atanor": "0.7.0", "alambique": "0.14.0"},
            "admission": {"in_flight": 0, "refused": {"unavailable": 0 if first else 3}, "unavailable_by_reason": {"store_unavailable": 0 if first else 2, "breaker_open": 0 if first else 1},
                          "disk_used_bytes": 10 * MB, "disk_budget_bytes": 100 * MB}, "wakes": 5 if first else 12}


new_record = two_node_step("two_new", by_ip_new, reasons={"unavailable/store_unavailable": 7, "overloaded/busy": 3})
results["two_nodes_new"] = {"per_node": new_record["per_node"], "refusals": new_record["refusals"], "notes": new_record["notes"], "wakes": new_record["evictions"]["wakes"],
                            "unavailable_by_reason": new_record["admission"]["unavailable_by_reason"], "by_reason": new_record["statuses_503_by_reason"],
                            "unreported": new_record["admission"]["refused_unreported"]}
same_record = two_node_step("two_same", lambda ip, reader: {"admission": {"in_flight": 0, "refused": {}, "disk_budget_bytes": 100 * MB}})
results["two_nodes_same_budget"] = {"notes": same_record["notes"], "wakes": same_record["evictions"]["wakes"], "by_reason": same_record["statuses_503_by_reason"],
                                    "unavailable_by_reason": same_record["admission"]["unavailable_by_reason"],
                                    "per_node": {n: (p["wakes"], p["unavailable_by_reason"]) for n, p in same_record["per_node"].items()}}

# The rebalance of a window is read mid-plan (`rebalance_observed`) and at the window's end (`rebalance`): the end sees later moves. A node whose
# /runtime did not answer is named with the error. An ok join keeps every node's state and log, the store's, and the /runtime of each window.
moved = iter(range(1, 100_000))
record, out = run_join("join_end", runtime=lambda: {"rebalance": {"total": {"moved": next(moved)}}}, silent={"127.0.0.2"})
window, first = record["windows"][1], record["windows"][0]
results["join_end"] = {"status": record["status"], "observed": window["rebalance_observed"], "end": window["rebalance"], "first": [first["rebalance"], first["rebalance_observed"]],
                       "failures": [first["runtime_failures"], window["runtime_failures"]],
                       "silent_samples": sorted({tuple(s["runtime_errors"]) for s in window["samples"]}), "diagnostics": sorted(record["diagnostics"]),
                       "files": sorted(f for f in os.listdir(os.path.join(out, "A", "scale", "join")) if f != "step-2000.json"),
                       "runtime_window_2": json.load(open(os.path.join(out, "A", "scale", "join", "step-2000.window-2.runtime.json")))}
# A join whose nodes report another disk budget says so, and keeps the budgets of the last window.
lab["by_ip"] = lambda ip, reader: {"admission": {"disk_budget_bytes": (100 if ip.endswith(".1") else 200) * MB}}
record, _ = run_join("join_budgets")
lab["by_ip"] = None
results["join_budgets"] = {"status": record["status"], "budgets": record["disk_budget_bytes"], "notes": record["notes"]}
record, _ = run_join("join_no_budgets")
results["join_no_budgets"] = {"budgets": record["disk_budget_bytes"], "notes": record["notes"]}
real_cluster = m.fresh_cluster
m.fresh_cluster = lambda nodes: (_ for _ in ()).throw(m.LabError("the lab did not start with 1 nodes"))
record, _ = run_join("join_lab")
m.fresh_cluster = real_cluster
results["join_lab"] = {"status": record["status"], "reason": record["stop_reason"]}

# The wake refusals split into the cold start and the steady state: a node's cold start lasts while its `wakes` grows. Node-1 wakes in the first
# two intervals (refusing 700 then 200 wakes) and then only refuses 5 more; node-2 is warm (wakes never grow): all steady; node-3 does not report.
def node_read(wakes, refused):
    return ({"wakes": wakes, "admission": {"awake_limit_by": {"queue_full": refused - 10, "wait_expired": 10}}}, None)


series_1 = [(0, 0, 0), (2, 30, 700), (4, 64, 900), (6, 64, 903), (8, 64, 905)]
steps = [{"t": 100.0 + t, "node_keys": {"node-1": "node", "node-2": "extra1", "node-3": "extra2"},
          "node_runtimes": {"node-1": node_read(w, r), "node-2": node_read(7, 40 + i), "node-3": ({}, None)}} for i, (t, w, r) in enumerate(series_1)]
split = m.step_wake_refusals(steps)
results["cold_split"] = {"summed": [split["cold_start"], split["steady"], split["cold_start_end_s"], split["cold_start_ended"]], "nodes": split["nodes"],
                         "single": m.step_wake_refusals([{"t": 5.0 + t, "runtime": node_read(w, r)[0]} for t, w, r in series_1])["nodes"],
                         "never_stops": m.cold_start([(0, 0, 0), (2, 5, 10), (4, 9, 12)]), "one_reading": m.cold_start([(0, 0, 0)]),
                         # round 026 (scale, 0.2 s sampling): three readings before the first wake, then wakes and refusals grow, then flat
                         "dense_opening": m.cold_start([(0.0, 0, 0), (0.2, 0, 0), (0.4, 0, 0), (0.6, 40, 60), (0.8, 90, 156), (1.0, 452, 156), (1.2, 452, 156), (1.4, 452, 158)]),
                         # a warm node (cells woken before the step) that wakes nothing in its first interval and then churns: all steady
                         "warm_churn": m.cold_start([(0, 64, 0), (2, 64, 1), (4, 80, 5), (6, 95, 9), (8, 95, 9)]),
                         "unreported": m.step_wake_refusals([{"t": 1.0, "runtime": {}}, {"t": 2.0, "runtime": {}}])}

# The same for a join: node-2 appears in the third reading (its cold start is its own); window 1 has the cold start of node-1, window 2 only steady
# refusals of node-1 and the cold start of node-2. The 5xx of the readings up to the latest end are cold start.
def poll(t, w1, r1, w2=None, r2=None):
    return {"t": 200.0 + t, "backend": {"hrsp_5xx": 0}, "rebalance": {}, "runtime_errors": {}, "requests": {"node-1": 0, "node-2": 0}, "cells": None,
            "wakes": {"node-1": w1, "node-2": w2}, "wake_refused": {"node-1": r1, "node-2": r2}}


readings = [poll(0, 0, 0), poll(2, 40, 700), poll(4, 64, 911), poll(6, 64, 911), poll(8, 64, 913, 0, 0), poll(10, 64, 915, 10, 30), poll(12, 64, 916, 10, 31)]
for reading, five in zip(readings, (0, 698, 911, 911, 915, 920, 921)):
    reading["backend"]["hrsp_5xx"] = five
joined_args = make_args(os.path.join(work, "cold_join"))
join_poller = type("Poller", (), {"samples": readings})()
windows = m.join_windows(join_poller, [{"nodes": 2, "join_t": 200.0 + 7.0, "ready_s": 1.0, "ready_t": 208.0}], joined_args, RATE)
results["cold_join"] = {"summary": m.cold_start_summary(m.join_cold_starts(readings), 200.0),
                        "windows": [[w["wake_refusals"], w["backend_5xx"]] for w in windows]}

# The report shows both numbers: next to a step, in the join windows and for the whole join.
report_dir = os.path.join(work, "report")
shutil.copytree(os.path.join(work, "ramp"), report_dir)
step_file = os.path.join(report_dir, "A", "scale", "http-native-n1", "step-50.json")
with open(step_file) as file:
    step_record = json.load(file)
step_record["wake_refusals"] = split
os.makedirs(os.path.join(report_dir, "A", "scale", "join"), exist_ok=True)
m.write_json(step_file, step_record)
m.write_json(os.path.join(report_dir, "A", "scale", "join", "step-2000.json"),
             {"schema": "atanor-load-join-1", "scenario": "A", "measure": "scale", "phase": "join", "status": "ok", "stop_reason": None, "rate": 2000.0, "tolerance_pct": 25.0, "hold_samples": 3, "sample_s": 2.0,
              "windows": [{**w, "backend": None} for w in windows], "wake_refusals": results["cold_join"]["summary"], "generator": {}, "notes": []})
report = subprocess.run([sys.executable, "-I", f"{repo}/scripts/load-report", report_dir], capture_output=True, text=True)
results["report"] = {"status": report.returncode, "lines": [l for l in report.stdout.splitlines() if "wake refusals" in l.lower()], "stderr": report.stderr[-300:]}
print(json.dumps(results))
