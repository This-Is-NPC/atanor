#!/usr/bin/env python3
"""Drives scripts/load-run's Round with a stub `docker` and `load-env` on PATH, no container started.

Usage: load_run_check.py WORKDIR. Prints one JSON object: the step records of each scenario (test/scripts/load_run_test.exs asserts them).
"""
import argparse
import importlib.machinery
import importlib.util
import json
import math
import os
import stat
import sys
import time

sys.dont_write_bytecode = True  # do not leave scripts/__pycache__
work = sys.argv[1]
repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
fake = os.path.join(work, "fake")
os.makedirs(fake, exist_ok=True)

DOCKER = """#!/bin/sh
case "$1" in
  inspect)
    if [ -e "$FAKE_DIR/gone" ]; then echo "Error: No such object: $2" >&2; echo "[]"; exit 1; fi
    cat "$FAKE_DIR/inspect.json" ;;
  logs)
    if [ "$2" = "--timestamps" ]; then
      echo "2026-01-01T00:00:01Z volume growth: no free volume"
      echo "2026-01-01T00:00:02Z s3 auth with secret_access_key=abc123"
      echo "2026-01-01T00:00:03Z request Authorization TOKEN seen"
    else echo "beam: eheap_alloc: cannot allocate memory"; fi ;;
  *) exit 1 ;;
esac
"""
for name, body in (("docker", DOCKER), ("load-env", "#!/bin/sh\necho 'cannot exec in a dead container' >&2\nexit 1\n")):
    path = os.path.join(fake, name)
    with open(path, "w") as file:
        file.write(body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
os.environ["PATH"] = fake + os.pathsep + os.environ["PATH"]
os.environ["FAKE_DIR"] = fake


MB = 1048576


def container(running=True, oom=False, exit_code=0, started="2026-01-01T00:00:00Z", restarts=0, ident="abc"):
    gone = os.path.join(fake, "gone")
    if os.path.exists(gone):
        os.remove(gone)
    state = {"Running": running, "OOMKilled": oom, "ExitCode": exit_code, "StartedAt": started}
    with open(os.path.join(fake, "inspect.json"), "w") as file:
        json.dump([{"Id": ident, "State": state, "RestartCount": restarts}], file)


spec = importlib.util.spec_from_loader("load_run", importlib.machinery.SourceFileLoader("load_run", f"{repo}/scripts/load-run"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.HERE = fake  # load-env is the failing stub
m.ROOT = work  # no admin token to read: cells_awake is unknown
m.cgroup_dir = lambda pid: work + "/no-cgroup"  # the samples of the cgroups are empty, as for a gone node
real_quiet_sample = m.quiet_sample
m.quiet_sample = lambda dirs: real_quiet_sample(dirs) | {n: {"cpu_s": 0.0} for n in ("node", "store", "lb")}  # the wait reads no cgroup here

DOCUMENT = {"statuses": {"message answered": 10}, "hist": {"5": 10}, "max_ms": 1.0, "planned": 10, "sent": 10, "completed": 10,
            "cpu_s": 0.1, "lag_ms": {"p99": 1}, "opened": 10}
measure = ["ws"]
hook = {"during": lambda: None, "error": None}


def run_generators(self, value, sampler):
    hook["during"]()
    if hook["error"]:
        raise RuntimeError(hook["error"])
    return [dict(DOCUMENT)]


real_run_generators = m.Round.run_generators
m.Round.run_generators = run_generators
real_take = m.Sampler.take


def new_round(name):
    out = os.path.join(work, name)
    os.makedirs(out)
    args = argparse.Namespace(out=out, measure=measure[0], step_s=1.0, timeout=1.0, gen_grace=1.0, open_rate=100.0, host_load_max=1e9, min_available_gb=0.0,
                              sample_s=0.05, quiet_window=0.0, quiet_max_wait=5.0, delivery=0.95, memory_pct=1e9, fd_pct=1e9, p99_ms=250.0,
                              max_generator_swap_mb=1e9, max_host_swap_growth_mb=1e12, max_refused_pct=1.0, max_lag_ms=50.0, max_throttle_jump_ms=5000.0, max_store_stall_ms=1000.0, store_stall_requests=10, max_busy_share=1e9, command="test", steps="10,20", start=10, max=20, factor=2, refine=0, no_confirm=False, max_store_tmpfs_pct=90.0, max_store_disk_pct=90.0, no_warmup=False, rate_per_proc=600.0, conns_per_rate=0.5, write_ratio=0.5, cells=64, worker="native", cell_period=10.0, cells_conns=64)
    pid = os.getpid()
    info = {"scenario": "A", "memory_limit_bytes": 512 * MB, "store_latency_ms": 25, "node": {"id": "abc", "ip": "127.0.0.1", "pid": pid}, "store": {"id": "store-id", "ip": "127.0.0.1", "pid": pid},
            "lb": {"pid": pid}, "admin": "http://127.0.0.1:1"}
    return m.Round(args, info), args


def case_dir(args):
    """Where the steps of the measure of `args` are written: OUT/SCENARIO/MEASURE."""
    return os.path.join(args.out, "A", args.measure)


def step_files(args):
    return sorted(f for f in os.listdir(case_dir(args)) if f.endswith(".json") and "summary" not in f)


def scenario(name, during=lambda: None, error=None, before=None, info=None):
    container(**(before or {}))
    hook.update(during=during, error=error)
    round_, _ = new_round(name)
    round_.info.update(info or {})
    record = round_.step(10, "ramp")
    return {"record": record, "files": sorted(os.listdir(case_dir(round_.args)))}


results = {}
# The node is fine; only the store rtt measurement fails (load-env exits 1).
results["rtt_fails"] = scenario("rtt_fails")
# cells: 10 opening writes (half of them refused, 300 ms) and 10 hold writes (all answered, 0.5 ms). The hold is judged: the step passes,
# and the opening's p99 and refusals are reported apart; the whole-step statuses stay.
real_document, real_measure = DOCUMENT, measure[0]
DOCUMENT = {"statuses": {"200": 15, "503 retry-after": 5}, "hist": {"3000": 10, "5": 10}, "max_ms": 300.0, "planned": 20, "sent": 20, "completed": 20, "cpu_s": 0.1,
            "lag_ms": {"p99": 1}, "opening": {"planned": 10, "statuses": {"200": 5, "503 retry-after": 5}, "hist": {"3000": 10}, "max_ms": 300.0}}
measure[0] = "cells"
results["cells_hold"] = scenario("cells_hold")
DOCUMENT["opening"]["hist"] = {"3000": 5, "5": 5}  # the opening is clean and the hold has the 503s: the step fails on them
DOCUMENT["opening"]["statuses"] = {"200": 10}
DOCUMENT["hist"], DOCUMENT["statuses"] = {"3000": 5, "5": 15}, {"200": 15, "503 retry-after": 5}
results["cells_hold_refused"] = scenario("cells_hold_refused")
# http: the warm-up (every cell written once, 300 ms, 10 of 20 refused) is the opening; the steady part is fast and clean, so the step passes.
DOCUMENT = {"statuses": {"200": 15, "503 retry-after": 5}, "hist": {"3000": 10, "5": 10}, "max_ms": 300.0, "planned": 20, "sent": 20, "completed": 20, "cpu_s": 0.1,
            "lag_ms": {"p99": 1}, "opening": {"planned": 10, "statuses": {"200": 5, "503 retry-after": 5}, "hist": {"3000": 10}, "max_ms": 300.0}}
measure[0] = "http-native"
results["http_warmup"] = scenario("http_warmup")
DOCUMENT, measure[0] = real_document, real_measure
# The generators of an http step warm up (with --open-rate) unless --no-warmup; a cells step has its own opening.
cmd_round, cmd_args = new_round("commands")
cmd_args.measure = "http-native"
warm = cmd_round.gen_commands(450)[0]
cmd_args.no_warmup = True
cold = cmd_round.gen_commands(450)[0]
cmd_args.measure = "cells"
results["warmup_commands"] = {"on": "--warmup" in warm, "open_rate": warm[warm.index("--open-rate") + 1] if "--open-rate" in warm else None,
                              "off": "--warmup" in cold, "cells": "--warmup" in cmd_round.gen_commands(100)[0]}
# The node is OOM-killed during the step.
results["oom"] = scenario("oom", during=lambda: container(running=False, oom=True, exit_code=137))
# The node exits 137 and the generator fails because of it.
results["exit_generator"] = scenario("exit_generator", during=lambda: container(running=False, exit_code=137), error="load-gen failed")
# The node restarted (same container, new start).
results["restarted"] = scenario("restarted", during=lambda: container(started="2026-01-01T00:05:00Z", restarts=1))
# The node's container is gone.
results["gone"] = scenario("gone", during=lambda: open(os.path.join(fake, "gone"), "w").close())
# A failing generator with a healthy node is still invalid, as before.
results["generator_only"] = scenario("generator_only", error="load-gen failed")
# The admin API answers /runtime: the step keeps the maxima and the top lists of the biggest sample.
calls = []


def fake_runtime(info, path, timeout):
    if path != "/runtime":
        return None
    calls.append(1)
    n = len(calls)
    top = [{"pid": f"#PID<0.{n}.0>", "name": None, "initial_call": "erlang.apply/2", "current_function": "gen_server.loop/7", "message_queue_len": n, "memory": 1000 * n}]
    return {"memory": {"total": 100 * n, "binary": 10 * (3 - n % 3)}, "process_count": 50 + n, "port_count": 1, "run_queues": [0], "ets": [{"name": "t", "bytes": n}],
            "top_memory": top, "top_message_queue": top, "wasm": None,
            "cgroup": {"memory_current": 1, "memory_max": 2, "stat": {"anon": 7 * n, "shmem": 1, "file": None, "sock": 2 * n, "inactive_file": 3 * n}, "events": {"oom": 0, "oom_kill": n}},
            "admission": {"in_flight": n, "max_in_flight": 64, "refused": {"memory": 10 * n, "in_flight": n, "disk": 0}, "working_set_bytes": 1000 * n, "limit_bytes": 512 * MB,
                          "refuse_at_bytes": 400 * MB, "refusing": n > 1, "disk_used_bytes": None, "disk_budget_bytes": None, "disk_refusing": False},
            "store": {"s3://bucket": {"state": "open" if n > 1 else "closed", "since_ms": 1, "failures": 5}}}


real_admin_json = m.admin_json
m.admin_json = fake_runtime
real_cgroup_sample, real_s3 = m.cgroup_sample, m.s3_counters
m.cgroup_sample = lambda d: {"memory_current": 300 * MB, "shmem": 256 * MB if "store" in d else 1, "peak": 300 * MB, "limit": 1280 * MB, "cpu_s": time.time(), "cpu_limit": 1.0, "throttled_s": 1.5}
m.cgroup_dir = lambda pid: work + ("/store" if pid == "store" else "/no-cgroup")
m.s3_counters = lambda ip: (1.0, 1.0, float(len(calls)))
results["runtime_ok"] = scenario("runtime_ok", info={"store_tmpfs_bytes": 512 * MB, "store": {"ip": "127.0.0.1", "pid": "store"}})
m.cgroup_sample, m.s3_counters = real_cgroup_sample, real_s3
m.cgroup_dir = lambda pid: work + "/no-cgroup"
results["runtime_ok"]["calls"] = len(calls)
# A /runtime that answers something else than an object is not a sample either.
m.admin_json = lambda info, path, timeout: ["unexpected"] if path == "/runtime" else None
results["runtime_garbage"] = scenario("runtime_garbage")
m.admin_json = real_admin_json
# The lists kept are those of the sample where the node's cgroup used most.
low, high = fake_runtime(None, "/runtime", 1), fake_runtime(None, "/runtime", 1)
low["ets"], high["ets"] = [{"name": "low", "bytes": 1}], [{"name": "high", "bytes": 2}]
results["peak"] = m.runtime_summary([{"node": {"memory_current": 5}, "runtime": low}, {"node": {"memory_current": 9}, "runtime": high},
                                     {"node": {"memory_current": 7}, "runtime": None}])
# The store's tmpfs: over 90% of its size the step is INVALID, before a failing p99; under it the step is judged as usual.
def store_scenario(name, tmpfs_mb, die=False, disk=None):
    real = (m.cgroup_sample, m.cgroup_dir, m.Round.run_generators, m.store_disk)
    m.store_disk = lambda store: disk  # (used, available) bytes of the store's disk, when the store is on disk
    m.cgroup_sample = lambda d: {"memory_current": 300 * MB, "shmem": 256 * MB if "store" in d else 1, "peak": 300 * MB, "limit": 1280 * MB, "cpu_s": time.time(), "cpu_limit": 1.0}
    m.cgroup_dir = lambda pid: work + ("/store" if pid == "store" else "/no-cgroup")
    m.Round.run_generators = lambda self, value, sampler: hook["during"]() or [{**DOCUMENT, "statuses": {"200": 10}, "hist": {"9000": 10}}]
    measure[0] = "http-native"
    try:
        result = scenario(name, during=(lambda: container(running=False, oom=True, exit_code=137)) if die else (lambda: None),
                          info={"store_tmpfs_bytes": tmpfs_mb * MB, "store_backing": "disk" if disk else "tmpfs",
                                "store": {"id": "store-id", "ip": "127.0.0.1", "pid": "store"}})
    finally:
        measure[0] = "ws"
        m.cgroup_sample, m.cgroup_dir, m.Round.run_generators, m.store_disk = real
    result["record"].pop("series", None)
    return result["record"]


for name, args in (("store_full", (275,)), ("store_half", (512,)), ("store_full_dead", (275, True))):
    results[name] = store_scenario(name, *args)

# The store on disk: no tmpfs to judge (its shmem is not a store file system), the disk use is recorded, and over 90% the step is INVALID.
results["disk_full"] = store_scenario("disk_full", 0, disk=(950 * MB, 50 * MB))
results["disk_half"] = store_scenario("disk_half", 0, disk=(500 * MB, 500 * MB))

# A ramp whose second step breaks the node ends there: a summary, no bisection, no confirmation.
def ramp_scenario(name, dies_at, before=None):
    container(**(before or {}))
    calls = []

    def during():
        calls.append(1)
        if len(calls) == dies_at:
            container(running=False, oom=True, exit_code=137)

    hook.update(during=during, error=None)
    round_, args = new_round(name)
    args.steps, args.refine = "10,20,40", 2
    summary = m.ramp(round_, args)
    return {"summary": summary, "generator_runs": len(calls), "files": step_files(args)}


results["ramp"] = ramp_scenario("ramp", dies_at=2)
# After a failing step the refine and confirm steps run on a fresh node (a stubbed reset); ramp steps and a clean confirmation do not.
def fresh_scenario(name, slow_call, no_confirm=False, refine=2):
    container()
    resets, runs = [], []

    def generators(self, value, sampler):
        runs.append(value)
        slow = len(runs) == slow_call
        return [{**DOCUMENT, "statuses": {"200": 10}, "hist": {"9000" if slow else "5": 10}}]

    real_load_env, real_generators = m.load_env, m.Round.run_generators
    round_, args = new_round(name)
    info = json.dumps(round_.info)
    m.load_env = lambda *a: resets.append(a[0]) or (info if a[0] == "info" else "")
    m.Round.run_generators = generators
    try:
        args.measure, args.steps, args.refine, args.no_confirm = "http-native", "10,20", refine, no_confirm
        summary = m.ramp(round_, args)
    finally:
        m.load_env, m.Round.run_generators = real_load_env, real_generators
    records = []
    for file in step_files(args):
        with open(os.path.join(case_dir(args), file)) as handle:
            records.append(json.load(handle))
    steps = [[r["phase"], r["status"], r["fresh_node"], r["reset_s"] is not None] for r in sorted(records, key=lambda r: r["step"])]  # in the order they ran
    return {"steps": steps, "resets": resets, "approved": summary["approved"]}


results["fresh_after_fail"] = fresh_scenario("fresh_after_fail", slow_call=2)
results["fresh_never_failed"] = fresh_scenario("fresh_never_failed", slow_call=0)
results["no_confirm"] = fresh_scenario("no_confirm", slow_call=2, no_confirm=True, refine=0)

# A stall of the lab is judged on the generator's lag and on one jump of the node's CPU throttling against its usual growth.
def throttled(*values):
    return [{"node_throttled_ms": v} for v in values]


results["judge_stall"] = {
    "lag": m.judge_stall(242, throttled(0, 500), 50, 5000),
    "lag_at_limit": m.judge_stall(50, throttled(0, 500), 50, 5000),
    "jump": m.judge_stall(1.3, throttled(0, 500, 1000, 7200, 7700), 50, 5000),
    "saturated": m.judge_stall(1.3, throttled(0, 5500, 11000, 16500, 22000), 50, 5000),
    "saturated_peak": m.judge_stall(1.3, throttled(0, 3000, 6000, 12000, 15000), 50, 5000),
    "small_jump": m.judge_stall(1.3, throttled(0, 100, 200, 3200, 3300), 50, 5000),
    "unknown": m.judge_stall(1.3, throttled(None, None, 9000, None), 50, 5000),
    "single": m.judge_stall(1.3, throttled(0), 50, 5000),
    "no_lag": m.judge_stall(None, throttled(0, 500), 50, 5000),
    "missing_key": m.judge_stall(1.3, [{}, {"node_throttled_ms": 9000}, {}], 50, 5000),
}


# A stalled step is repeated once; a repeat that stalls again is INVALID and ends the round.
def stall_scenario(name, lags, **options):
    container()
    runs = []

    def generators(self, value, sampler):
        runs.append(value)
        return [{**DOCUMENT, "lag_ms": {"p99": lags[min(len(runs), len(lags)) - 1]}}]

    real = m.Round.run_generators
    round_, args = new_round(name)
    vars(args).update(options)
    m.Round.run_generators = generators
    try:
        summary = m.ramp(round_, args)
    finally:
        m.Round.run_generators = real
    files = step_files(args)
    with open(os.path.join(case_dir(args), files[0])) as handle:
        first = json.load(handle)
    return {"runs": runs, "files": files, "summary": summary, "first": first}


results["stall_once"] = stall_scenario("stall_once", [242, 1])
results["stall_twice"] = stall_scenario("stall_twice", [242, 300])

# A node saturated above its ceiling backs the generator up: the step lags (p99 162 ms) but the generator released every request on
# time (release lag 1 ms), so the step fails by p99 (1900 ms) and the ramp refines. A generator that itself released late is a stall.
def lag_scenario(name, lag, release, p99_bucket):
    real = m.Round.run_generators
    doc = {**DOCUMENT, "hist": {str(p99_bucket): 10}, "lag_ms": {"p99": lag}}
    m.Round.run_generators = lambda self, value, sampler: [doc if release is None else {**doc, "release_lag_ms": {"p99": release}}]
    measure[0] = "http-native"
    try:
        record = scenario(name)["record"]
    finally:
        measure[0] = "ws"
        m.Round.run_generators = real
    return {k: record[k] for k in ("status", "valid", "stop_reason")} | {"generator": record["generator"]}


results["lag_saturated"] = lag_scenario("lag_saturated", 162.2, 1.0, 19000)
results["lag_stalled"] = lag_scenario("lag_stalled", 241.9, 241.9, 7658)
results["lag_old_generator"] = lag_scenario("lag_old_generator", 162.2, None, 19000)

# A step fails when 503s (with or without Retry-After) exceed 1% of the answers; exactly 1% passes. 200 answers in one second.
def refused_scenario(name, statuses):
    real = m.Round.run_generators
    m.Round.run_generators = lambda self, value, sampler: [{**DOCUMENT, "statuses": statuses, "hist": {"5": 200}, "planned": 200, "sent": 200, "completed": 200, "opened": 200}]
    measure[0] = "http-wasm"
    try:
        record = scenario(name)["record"]
    finally:
        measure[0] = "ws"
        m.Round.run_generators = real
    return {k: record[k] for k in ("status", "valid", "stop_reason", "useful_rate")}


results["refused"] = {
    "two_pct": refused_scenario("refused_two", {"200": 196, "503 retry-after": 4}),
    "two_pct_no_retry": refused_scenario("refused_two_nr", {"200": 196, "503 no retry-after": 4}),
    "half_pct": refused_scenario("refused_half", {"200": 199, "503 retry-after": 1}),
    "one_pct": refused_scenario("refused_one", {"200": 198, "503 retry-after": 2}),
}

def slow_log(*stamps, ms=1061):
    """A node log with one slow store request at each time of day in `stamps` and an unrelated line."""
    return "03:42:20.822 [info] atanor: ready\n" + "".join(f"{s} [warning] atanor: HTTP request PUT store:8333 took {ms} ms\n" for s in stamps)


BURST = slow_log(*(f"03:46:42.{900 + i:03d}" for i in range(12)))
SPREAD = slow_log(*(f"03:{10 + i}:00.000" for i in range(12)))
# A failing step whose node log shows a burst of slow store requests is INVALID ("stall:") and repeated once; a repeat that stalls too fails the
# step on the store ("store:"), valid; a slow store spread over time, a few slow requests, requests under the limit and the check turned off leave the verdict (fail) as it was.
def store_stall_scenario(name, logs, off=False):
    container()
    runs = []

    def generators(self, value, sampler):
        runs.append(value)
        return [{**DOCUMENT, "statuses": {"200": 10}, "hist": {"9000": 10}}]

    real = m.Round.run_generators, m.node_log_since
    round_, args = new_round(name)
    args.measure, args.max_store_stall_ms = "http-native", 0 if off else 1000.0
    m.Round.run_generators, m.node_log_since = generators, lambda node, since: logs[min(len(runs), len(logs)) - 1]
    try:
        summary = m.ramp(round_, args)
    finally:
        m.Round.run_generators, m.node_log_since = real
    with open(os.path.join(case_dir(args), step_files(args)[0])) as handle:
        first = json.load(handle)
    return {"runs": runs, "summary": summary, "first": {k: first[k] for k in ("status", "valid", "stop_reason", "criteria", "store_stall", "first_attempt", "notes")}}


results["store_stall_once"] = store_stall_scenario("store_stall_once", [BURST, ""])
results["store_stall_twice"] = store_stall_scenario("store_stall_twice", [BURST, BURST])
results["store_slow_spread"] = store_stall_scenario("store_slow_spread", [SPREAD])
results["store_few_slow"] = store_stall_scenario("store_few_slow", [slow_log("03:46:42.900", "03:46:42.901")])
results["store_fast"] = store_stall_scenario("store_fast", [slow_log("03:46:42.900", ms=999)])
results["store_stall_off"] = store_stall_scenario("store_stall_off", [BURST], off=True)
results["store_stall_pure"] = {"off": m.store_stall(BURST, 0, 10), "none": m.store_stall("", 1000, 10), "judge_none": m.judge_store_stall(None)}


# The 503 answers of a step are set against the refusal counters the node grew (all its causes); what no counter explains is counted and noted.
def refusal_scenario(name, grown, statuses=None, newer=False, reasons=None):
    """The node's /runtime shows `grown` refusals after its first reading (None: no /runtime); the generator answers 10 503s of 100.
    `newer`: the node also reports `unavailable_by_reason` and `wakes` (3 after its first reading); `reasons` the generator's 503 reasons."""
    seen = []

    def runtime(info, path, timeout):
        if path != "/runtime" or grown is None:
            return None
        seen.append(1)
        counted = {k: (v if len(seen) > 1 else 0) for k, v in grown.items()}
        # The memory pressure hibernated 4 cells after the first reading.
        pressure = {"hibernated": 7 if len(seen) > 1 else 3, "hibernate_at_bytes": 384 * MB}
        # A newer node also counts the release compaction outcomes: 2 cut by the deadline after the first reading, tail 192.
        hibernations = {"compaction": {"none": 1, "done": 5 if len(seen) > 1 else 3, "deadline": 2 if len(seen) > 1 else 0, "error": 0}, "tail_max": 192 if len(seen) > 1 else 6}
        more = {"wakes": 20 if len(seen) > 1 else 5, "hibernations": hibernations} if newer else {}
        more_admission = {"unavailable_by_reason": {"store_unavailable": 4 if len(seen) > 1 else 1, "breaker_open": 2},
                                    "awake_limit_by": {"no_wait": 0, "wait_expired": 5 if len(seen) > 1 else 1}} if newer else {}
        return {"admission": {"in_flight": 3, "refused": counted, "disk_used_bytes": 50 * MB, "disk_budget_bytes": 100 * MB, **more_admission}, "pressure": pressure, **more}

    real, real_admin = m.Round.run_generators, m.admin_json
    m.admin_json = runtime
    m.Round.run_generators = lambda self, value, sampler: [{**DOCUMENT, "statuses": statuses or {"200": 90, "503 retry-after": 10}, "hist": {"5": 100}, "planned": 100, "sent": 100, "completed": 100, "opened": 100, "reasons_503": reasons or {}}]
    measure[0] = "http-native"
    try:
        record = scenario(name)["record"]
    finally:
        measure[0] = "ws"
        m.Round.run_generators, m.admin_json = real, real_admin
    return {k: record[k] for k in ("refusals", "notes", "admission", "evictions", "statuses_503_by_reason")}


results["refusals"] = {"attributed": refusal_scenario("refusals_some", {"memory": 0, "wake_gate": 6, "busy": 1}),
                       "all_counted": refusal_scenario("refusals_all", {"wake_gate": 10}), "no_runtime": refusal_scenario("refusals_none", None),
                       "newer": refusal_scenario("refusals_newer", {"unavailable": 7, "busy": 1}, newer=True, reasons={"unavailable/store_unavailable": 7, "overloaded/busy": 3})}

# A step that starts with a dead node is invalid, runs no generator and ends the round.
results["dead_at_start"] = ramp_scenario("dead_at_start", dies_at=0, before={"running": False, "exit_code": 137})

# The memory criterion: memory.current - inactive_file (the node's working set, tmpfs included) against the scenario's memory, the tmpfs recorded apart (start, max, growth).
def memory_sample(t, current_mb, shmem_mb, inactive_mb=50):
    host = {"cpu_total": 100 * (t + 1), "cpu_idle": 100 * (t + 1), "loadavg1": 0.0, "available_gb": 8.0, "swap_used_mb": 0}
    node = {"memory_current": current_mb * MB, "shmem": shmem_mb * MB, "inactive_file": inactive_mb * MB, "peak": current_mb * MB, "limit": (512 + 768) * MB, "cpu_s": float(t), "cpu_limit": 1.0}
    return {"t": float(t), "node": node, "store": dict(node, cpu_s=0.0), "lb": {"cpu_s": 0.0}, "gen_cpu_s": 0.0, "self_cpu_s": 0.0, "gen_swap_mb": 0, "fds": None, "host": host}


# 700 MB current, 50 of it inactive file cache: the working set is 650 MB of the 512 MB scenario, as the node's gate sees it; the tmpfs (300) counts.
usage = m.summarize([memory_sample(0, 650, 256), memory_sample(1, 700, 300)], 0, 512 * MB)["memory"]
results["memory_criterion"] = {k: usage[k] for k in ("service_max_mb", "tmpfs_start_mb", "tmpfs_max_mb", "tmpfs_growth_mb", "limit_mb", "max_pct_of_limit")}

# The swap record: a stub cluster-swap-run writes result.json; the node is measured, so the usage is summarized against the scenario memory.
os.makedirs(os.path.join(work, "scripts"))
stub = os.path.join(work, "scripts", "load-env")  # the swap runs through `load-env swap`
with open(stub, "w") as file:
    file.write("#!/bin/sh\n[ \"$1\" = swap ] || exit 2\nwhile [ $# -gt 0 ]; do [ \"$1\" = --out ] && out=$2; shift; done\nmkdir -p \"$out\"\n"
               "echo '{\"sent\": 100, \"duration_s\": 10, \"a_exit_s\": 1.5, \"lost\": 0, \"duplicated\": 0, \"errors\": {\"503 held_elsewhere\": 30},\"phases\": {\"warmup\": {\"p99\": 20, \"max\": 30}}}' > \"$out/result.json\"\n")
os.chmod(stub, os.stat(stub).st_mode | stat.S_IXUSR)
m.Sampler.take = lambda self: memory_sample(time.time(), 650, 256)
swap_round, swap_args = new_round("swap")
swap_args.measure, swap_args.rate, swap_args.trigger, swap_args.swap_workers = "swap", 10, "sigterm", 1
swap_args.swap_warmup = swap_args.swap_overlap = swap_args.swap_settle = 1
swap_args.swap_timeout = 30
swap_summary = m.swap(swap_round, swap_args, swap_round.info)
results["swap_command"] = m.swap_command(swap_args, 10, "out")[:2]
results["exit_status"] = {"swap_ok": m.exit_status("swap", swap_summary), "swap_fail": m.exit_status("swap", {"status": "fail", "invalid": None}),
                          "swap_invalid": m.exit_status("swap", {"status": "invalid", "invalid": "no result"}),
                          "ramp_ok": m.exit_status("ws", {"invalid": None, "stopped_by": "p99"}), "ramp_invalid": m.exit_status("ws", {"invalid": "delivery 80%"})}
with open(os.path.join(case_dir(swap_args), "step-10.json")) as file:
    swap_record = json.load(file)
results["swap"] = {k: swap_record[k] for k in ("status", "valid", "stop_reason")} | {"service_max_mb": swap_record["memory"]["service_max_mb"],
                                                                                    "limit_mb": swap_record["memory"]["limit_mb"],
                                                                                    "refused": swap_record["status_503"]["with_retry_after"]}

# Host swap is judged by its growth during the step; a high but flat level is valid.
def swap_usage(start, peak):
    return {"swap_usage": {"containers_max_mb": {}, "generator_growth_mb": 0}, "host": dict(zip(("swap_start_mb", "swap_max_mb", "swap_growth_mb"), m.swap_growth_mb([start, peak])))}


results["host_swap"] = {"flat": m.judge_swap(swap_usage(3380, 3380), 16, 256), "grows": m.judge_swap(swap_usage(3380, 3680), 16, 256)}

# The quiet wait: a decision on intervals (start, end, foreign load), and the foreign load counts the harness itself as the lab's own.
results["is_quiet"] = {"empty": m.is_quiet([], 1, 60), "short": m.is_quiet([(0, 30, 0.2)], 1, 60), "long": m.is_quiet([(0, 30, 0.2), (30, 61, 0.9)], 1, 60),
                       "burst_resets": m.is_quiet([(0, 40, 0.2), (40, 50, 1.6), (50, 100, 0.2)], 1, 60), "burst_last": m.is_quiet([(0, 100, 0.2), (100, 110, 1.0)], 1, 60)}
results["judge_host"] = {"over": m.judge_host(1.6, 1.0), "at": m.judge_host(1.0, 1.0), "unknown": m.judge_host(None, 1.0)}


def load_sample(t, busy_cores, self_cpu_s=0.0, node_cpu_s=0.0):
    """node_cpu_s None: the node's cgroup could not be read, as cgroup_sample reports it ({})."""
    idle = 100 * m.CORES * t - busy_cores * 100 * t  # 100 ticks per core and second
    host = {"cpu_total": 100 * m.CORES * t, "cpu_idle": idle, "loadavg1": 0.0, "available_gb": 8.0, "swap_used_mb": 0}
    node = {} if node_cpu_s is None else {"cpu_s": node_cpu_s}
    return {"t": float(t), "host": host, "node": node, "store": {"cpu_s": 0.0}, "lb": {"cpu_s": 0.0}, "gen_cpu_s": 0.0, "self_cpu_s": self_cpu_s}


# 3 cores busy: 1 is the harness, 1 the node, 1 is foreign.
busy, foreign = m.net_load(load_sample(0, 0), load_sample(10, 3, self_cpu_s=10.0, node_cpu_s=10.0))
results["net_load"] = {"busy": round(busy, 2), "foreign": round(foreign, 2)}


# Observed shape: the node had ~300 CPU seconds and one read of its cgroup failed. Neither the interval into the gap nor the one out of it,
# nor one with an unreadable generator, may become tens of foreign cores; the step mean skips them and says how many.
steady = [load_sample(3 * i, 1, node_cpu_s=300.0 + 3.0 * i) for i in range(4)]
steady[2] = load_sample(6, 1, node_cpu_s=None)
steady_back = dict(steady[3], host=dict(steady[3]["host"], cpu_total=steady[3]["host"]["cpu_total"] + 100, cpu_idle=0))  # idle counter went back
gap = {"into": m.net_load(steady[1], steady[2]), "out_of": m.net_load(steady[2], steady[3]), "generator": m.net_load(dict(steady[0], gen_cpu_s=None), steady[1]),
       "idle_back": m.net_load(steady[3], steady_back)}
samples = [memory_sample(3 * i, 650, 256) for i in range(4)]
for sample in samples:
    sample["node"]["cpu_s"] = 300.0 + sample["t"]
samples[2]["node"] = {}
usage = m.summarize(samples, 0, 512 * MB)["host"]
results["net_load_gap"] = gap | {"skipped": usage["net_load_skipped"], "mean": usage["net_load_mean"], "max": usage["net_load_max"],
                                 "verdict": m.judge_host(usage["net_load_mean"], 1.0)}
results["is_quiet_gap"] = m.is_quiet([(0, 30, 0.2), (40, 80, 0.2)], 1, 60)


def wait_scenario(busy_cores):
    real, real_cpu = (m.host_sample, m.cgroup_dir), m.process_cpu
    clock = {"t": 0.0}

    def fake_host():
        clock["t"] += 1.0
        return load_sample(clock["t"], busy_cores)["host"]

    m.host_sample, m.cgroup_dir, m.process_cpu = fake_host, lambda pid: work + "/no-cgroup", lambda pid: 0.0
    args = argparse.Namespace(sample_s=0.01, host_load_max=1.0, quiet_window=0.05, quiet_max_wait=0.3)
    try:
        quiet, load = m.wait_quiet(args, {"node": {"pid": 1}, "store": {"pid": 1}, "lb": {"pid": 1}})
    finally:
        (m.host_sample, m.cgroup_dir), m.process_cpu = real, real_cpu
    return {"quiet": quiet, "load": load}


results["wait_quiet"] = {"idle": wait_scenario(0.2), "busy": wait_scenario(2.5)}

# A busy host that never calms stops the step as "host busy", with no generator run; a contaminated step is INVALID with the load named.
def host_scenario(name, busy_cores):
    container()
    runs = []
    real = m.host_sample, m.Round.run_generators
    hook.update(during=lambda: (runs.append(1), time.sleep(0.3)), error=None)  # the sampler ticks while the generators "run"
    round_, args = new_round(name)
    args.host_load_max, args.quiet_window, args.quiet_max_wait = 1.0, 0.05, 0.3
    args.sample_s = 0.01
    ticks = {"total": 0, "idle": 0}

    def fake_host():  # cumulative ticks: every call is one second of the host with busy_cores busy
        ticks["total"] += 100 * m.CORES
        ticks["idle"] += round(100 * (m.CORES - busy_cores(len(runs))))
        return {"cpu_total": ticks["total"], "cpu_idle": ticks["idle"], "loadavg1": 0.0, "available_gb": 8.0, "swap_used_mb": 0}

    real_cpu, real_cgroup = m.process_cpu, m.cgroup_sample
    m.host_sample, m.Sampler.take, m.process_cpu = fake_host, real_take, lambda pid: 0.0  # the harness's own CPU is not under test here
    m.cgroup_sample = lambda directory: memory_sample(0, 650, 256)["node"]  # every cgroup readable, with no CPU of its own
    try:
        record = round_.step(10, "ramp")
    finally:
        m.host_sample, m.process_cpu, m.cgroup_sample = real[0], real_cpu, real_cgroup
        m.Sampler.take = lambda self: memory_sample(time.time(), 650, 256)
    return {"status": record["status"], "valid": record["valid"], "stop_reason": record["stop_reason"], "generator_runs": len(runs)}


results["host_busy"] = host_scenario("host_busy", lambda ran: 2.5)
results["host_contaminated"] = host_scenario("host_contaminated", lambda ran: 2.5 if ran else 0.2)
# A stall of the harness's own ticker next to the first breaker-open sample is a stop of the whole VM; one far from it, or no open breaker, is not.
def stall_sample(t, state):
    return {"t": t, "runtime": {"store": {"s3://b": {"state": state}}}}


samples = [stall_sample(100.0, "closed"), stall_sample(105.0, "closed"), stall_sample(110.0, "open")]
results["stalls_together"] = m.stall_summary(samples, [(107.0, 5.5)])
results["stalls_apart"] = m.stall_summary(samples, [(40.0, 5.5)])
results["stalls_no_breaker"] = m.stall_summary(samples[:2], [(103.0, 5.5)])
results["stalls_none"] = m.stall_summary([], [])
# The ticker records the overshoot of its sleep: a sleep that takes 1.6 s instead of 0.1 s is a stall of 1.5 s, one of 0.1 s is not.
ticker = m.Sampler.__new__(m.Sampler)
ticker.stop_flag, ticker.stalls = m.threading.Event(), []
clock, sleeps = [0.0], [0.1, 1.6]


def fake_sleep(seconds):
    clock[0] += sleeps.pop(0)
    if not sleeps:
        ticker.stop_flag.set()


real_sleep, real_monotonic = m.time.sleep, m.time.monotonic
m.time.sleep, m.time.monotonic = fake_sleep, lambda: clock[0]
try:
    ticker.watch()
finally:
    m.time.sleep, m.time.monotonic = real_sleep, real_monotonic
results["ticker"] = [over for _, over in ticker.stalls]
# The host's own cores: a step whose mean busy cores pass the share of them is INVALID; the scale measure refuses a host that is too small.
real_cores = m.CORES
m.CORES = 4
results["judge_busy"] = [m.judge_busy(3.5, 0.85), m.judge_busy(3.4, 0.85), m.judge_busy(None, 0.85)]
results["cpu_caps"] = [list(m.cpu_caps(n, {"node_cpus": 1, "store_cpus": s, "lb_cpus": s}, 4)) for n, s in ((3, 2), (1, 2), (2, 1), (3, 1))]
m.CORES = real_cores
# The ws ramp must stay under the node's connection cap, and the cap under its descriptor limit.
results["ws_cap"] = [m.ws_cap_problem(51200, 16384, None), m.ws_cap_problem(100, 16384, None), m.ws_cap_problem(51200, 70000, 65536), m.ws_cap_problem(51200, 70000, 1048576)]
results["max_connections"] = [m.http_max_connections(), m.os.environ.update(ATANOR_LOAD_HTTP_MAX_CONNECTIONS="70000") or m.http_max_connections()]
m.os.environ.pop("ATANOR_LOAD_HTTP_MAX_CONNECTIONS")

# ---- a round of a config file: the layout, the config_hash, --skip-done, the plan kinds, the stall repeats and the timeout of a generator ----
lc = m.load_config
results["stall_repeats"] = {"two": stall_scenario("stall_repeats_two", [242, 242, 1], stall_repeats=2)["runs"],
                            "none": stall_scenario("stall_repeats_none", [242], stall_repeats=0)["runs"]}


def case_args(name, config_hash="h1", skip=True, **over):
    """The arguments of a step of the config round, in a results directory of their own."""
    round_, args = new_round(name)
    vars(args).update({"config_hash": config_hash, "skip_done": skip, "scenario": "A", "measure": "http-native", "steps": None, "start": 10, "max": 40,
                       "factor": 2, "refine": 2, "ws_interval": 30.0, **over})
    return round_.info, args


def run_case(info, args, slow_from, runs):
    """The ramp of `args` with a stub generator that is slow from `slow_from` on (a failing p99); `runs` collects the values that ran."""
    def generators(self, value, sampler):
        runs.append(value)
        return [{**DOCUMENT, "statuses": {"200": 10}, "hist": {"9000" if value >= slow_from else "5": 10}}]

    real, text = (m.Round.run_generators, m.load_env), json.dumps(info)  # the reset empties `info` before it reads it again
    m.Round.run_generators, m.load_env = generators, lambda *a: text if a[0] == "info" else ""
    container()
    try:
        return m.ramp(m.Round(args, info), args)
    finally:
        m.Round.run_generators, m.load_env = real


def files_of(out):
    return sorted(os.path.relpath(os.path.join(d, f), out) for d, _, names in os.walk(out) for f in names if f.endswith(".json") and not f.startswith("."))


def read_json(*parts):
    with open(os.path.join(*parts)) as handle:
        return json.load(handle)


# The bisection: 10 and 20 pass, 40 fails, the refinement tries 30 (fails) and 25 (passes), and the confirmation of 25 is repetition 2.
info, args = case_args("bisect")
runs = []
summary = run_case(info, args, 30, runs)
bisect_files = files_of(args.out)
results["bisect"] = {"runs": runs, "files": bisect_files, "summary": {k: summary[k] for k in ("good", "approved", "confirmed", "first_failure")},
                     "phases": {f: [read_json(args.out, f)["phase"], read_json(args.out, f)["status"], read_json(args.out, f)["config_hash"]] for f in bisect_files},
                     "fresh": [read_json(args.out, "A", "http-native", f)["fresh_node"] for f in ("step-40.json", "step-30.json", "step-25.json", "step-25-2.json")]}
# The ceiling kind is a ladder of fractions of a ceiling, refined and confirmed as configured.
with open(os.path.join(work, "ceiling.toml"), "w") as handle:
    handle.write("[measures.http-native.steps]\nkind = \"ceiling\"\nceiling = 400\nrefine = 1\n")
ceiling_steps = m.config_defaults(lc.load_config(os.path.join(work, "ceiling.toml")), "http-native", "A", "c.toml")["steps"]
info, args = case_args("ceiling", refine=1, steps=ceiling_steps)
runs = []
summary = run_case(info, args, 500, runs)
results["ceiling"] = {"steps": ceiling_steps, "runs": runs, "files": files_of(args.out), "good": summary["good"], "approved": summary["approved"]}

# --skip-done: a done step is not run again and its result decides the ramp; an INVALID one runs again; another config's file stops the round.
info, args = case_args("skip", refine=0, steps="10,20,40")
first_runs, again, third, fourth, other, forced = [], [], [], [], [], []
first = run_case(info, args, 40, first_runs)
second = run_case(info, args, 10, again)  # every step would be slow now, so any run would change the verdict
step_dir = os.path.join(args.out, "A", "http-native")
os.remove(os.path.join(step_dir, "step-20-2.json"))
third_summary = run_case(info, args, 40, third)
invalid = read_json(step_dir, "step-40.json")
invalid.update(status="invalid", valid=False, stop_reason="host busy")
m.write_json(os.path.join(step_dir, "step-40.json"), invalid)
fourth_summary = run_case(info, args, 40, fourth)
try:
    run_case(info, argparse.Namespace(**{**vars(args), "config_hash": "h2"}), 40, other)
    refused = None
except SystemExit as error:
    refused = str(error.code)
fifth = argparse.Namespace(**{**vars(args), "skip_done": False})
rerun_summary = run_case(info, fifth, 40, forced)
results["skip_done"] = {"first": first_runs, "again": again, "same_summary": first == second == third_summary == fourth_summary == rerun_summary,
                        "third": third, "invalid_reran": fourth, "refused": refused, "refused_ran": other, "no_skip": forced, "files": files_of(args.out),
                        "approved": first["approved"], "hash_in_file": read_json(step_dir, "step-20-2.json")["config_hash"]}

# The layout: the node count is the variant of the scale measure, the join and the summaries have their own place.
info, args = case_args("layout")
scale_round = m.Round(args, info, stem="scale-http-native-n2")
scale_record = scale_round.step(998, "ramp")
scale_round.step(998, "confirm")
results["layout"] = {"files": files_of(args.out), "measure": scale_record["measure"], "load": scale_record["load"], "config_hash": scale_record["config_hash"],
                     "join": os.path.relpath(m.join_base(args, "A", 600), args.out), "join_float": os.path.relpath(m.join_base(args, "A", 600.0), args.out),
                     "summary": os.path.relpath(m.result_file(args, "A", "ws", "summary"), args.out),
                     "baseline": os.path.relpath(m.result_file(args, "A", "cells", "baseline"), args.out)}

# The swap in the layout: its rate is the approved one of http-wasm-jobs, and a done swap is not run again.
swap_info, swap_args = case_args("swap_nested", rate=None, trigger="sigterm", swap_workers=1, swap_warmup=1, swap_overlap=1, swap_settle=1, swap_timeout=30)
swap_args.measure = "swap"
m.write_json(m.result_file(swap_args, "A", "http-wasm-jobs", "summary"), {"approved": 10})
swapped = m.swap(m.Round(swap_args, swap_info), swap_args, swap_info)
swap_dir = os.path.join(swap_args.out, "A", "swap")
before = sorted(os.listdir(swap_dir))
swapped_again = m.swap(m.Round(swap_args, swap_info), swap_args, swap_info)
results["swap_nested"] = {"first": swapped["status"], "again": swapped_again["status"], "approved": [swapped["approved"], swapped_again["approved"]],
                          "files": [f for f in before if f.startswith("step-")], "same_files": before == sorted(os.listdir(swap_dir)),
                          "hash": read_json(swap_dir, "step-10.json")["config_hash"]}

# The round's timeout stops the ramp before its next step.
info, args = case_args("deadline", deadline=time.time() - 1)
try:
    m.Round(args, info).step(10, "ramp")
    stop = None
except m.RoundStop as error:
    stop = str(error)
results["deadline"] = [stop, os.path.exists(os.path.join(args.out, "A"))]

# What the config says reaches the arguments: a criterion that is off gets a limit nothing reaches.
with open(os.path.join(work, "args.toml"), "w") as handle:
    handle.write("[round]\nmeasures = [\"cells\"]\nstep_timeout_s = 123\n[judging]\nstall_repeats = 3\n[judging.p99]\nenabled = false\n[judging.delivery]\nenabled = false\n"
                 "[judging.errors]\nenabled = false\n[judging.store_stall]\nenabled = false\n[judging.host_load]\nenabled = false\n[judging.host_memory]\nenabled = false\n"
                 "[workload]\nwarmup = false\n[measures.cells.steps]\nkind = \"ceiling\"\nceiling = 400\nduration_s = 50\n")
given = m.config_defaults(lc.load_config(os.path.join(work, "args.toml")), "cells", "A", "c.toml")
official = m.config_defaults(lc.load_config(f"{repo}/load/rounds/018f.toml"), "scale", "A", "o.toml")
results["config_defaults"] = {"p99_off": math.isinf(given["p99_ms"]), "p99_on": m.config_defaults(lc.load_config(), "cells", "A", "c.toml")["p99_ms"], "delivery": given["delivery"],
                              "judge_errors": given["judge_errors"], "stall_ms": given["max_store_stall_ms"], "host_off": math.isinf(given["host_load_max"]),
                              "quiet_window": given["quiet_window"], "min_gb": given["min_available_gb"], "timeout": given["step_timeout"], "no_warmup": given["no_warmup"],
                              "repeats": given["stall_repeats"], "steps": given["steps"], "hash": len(given["config_hash"]),
                              "command": given["command"], "scale": [official["ceilings"], official["factors"], official["max_nodes"], official["load_plans"]["http-native"]["values"],
                                                                      official["steps"] if "steps" in official else "none"]}


# [scale.judging.LOAD]: each load of the scale ramps with its own rules; the others keep the measure's
with open(os.path.join(work, "scale-judging.toml"), "w") as handle:
    handle.write("[measures.scale.judging.p99]\nmax_ms = 400\n[scale.judging.cells.p99]\nmax_ms = 900\n[scale.judging.cells.errors]\nenabled = false\n")
scale_args = argparse.Namespace(**m.config_defaults(lc.load_config(os.path.join(work, "scale-judging.toml")), "scale", "A", "c.toml"))
ramped = {}
real_fresh, real_round, real_ramp = m.fresh_cluster, m.Round, m.ramp
m.fresh_cluster, m.Round = lambda nodes: {}, lambda a, info, stem=None: None
m.ramp = lambda round_, a: ramped.setdefault(a.measure, (a.p99_ms, a.judge_errors)) and {}
for scaled in ("cells", "http-native"):
    m.scale_config(scale_args, scaled, 1, None, None)
m.fresh_cluster, m.Round, m.ramp = real_fresh, real_round, real_ramp
results["scale_judging"] = {"ramped": ramped, "args": [scale_args.p99_ms, scale_args.judge_errors]}


def errors_scenario(name, judged):
    real = m.Round.run_generators
    m.Round.run_generators = lambda self, value, sampler: [{**DOCUMENT, "statuses": {"200": 9, "500": 1}, "hist": {"5": 10}}]
    container()
    info, args = case_args(name, judge_errors=judged)
    try:
        record = m.Round(args, info).step(10, "ramp")
    finally:
        m.Round.run_generators = real
    return [record["status"], record["stop_reason"]]


results["errors"] = [errors_scenario("errors_on", True), errors_scenario("errors_off", False)]

# A generator runs under `timeout`: one that outlives step_timeout_s is killed and the step is INVALID (timeout); a good one is not touched,
# and its CPU is read from the generator, not from `timeout`.
with open(os.path.join(fake, "load-gen"), "w") as handle:
    handle.write("#!/bin/sh\nwhile [ $# -gt 0 ]; do [ \"$1\" = --out ] && out=$2; shift; done\n[ -e \"$FAKE_DIR/gen-sleep\" ] && sleep 30\n"
                 "echo '{\"statuses\": {\"200\": 10}, \"hist\": {\"5\": 10}, \"max_ms\": 1.0, \"planned\": 10, \"sent\": 10, \"completed\": 10, \"cpu_s\": 0.1, \"lag_ms\": {\"p99\": 1}, \"opened\": 10}' > \"$out\"\n")
os.chmod(os.path.join(fake, "load-gen"), 0o755)


def generator_scenario(name, sleeps, limit):
    flag = os.path.join(fake, "gen-sleep")
    if sleeps:
        open(flag, "w").close()
    elif os.path.exists(flag):
        os.remove(flag)
    container()
    info, args = case_args(name, step_timeout=limit)
    seen, original = [], m.generator_pid
    m.generator_pid = lambda wrapper: seen.append((wrapper.pid, original(wrapper))) or seen[-1][1]
    began = time.time()
    real = m.Round.run_generators
    m.Round.run_generators = real_run_generators
    try:
        record = m.Round(args, info).step(10, "ramp")
    finally:
        m.Round.run_generators, m.generator_pid = real, original
        if os.path.exists(flag):
            os.remove(flag)
    return {"status": record["status"], "valid": record["valid"], "stop_reason": record["stop_reason"], "seconds": round(time.time() - began),
            "child_pid_read": bool(seen) and seen[0][0] != seen[0][1]}


results["generator_timeout"] = generator_scenario("gen_timeout", True, 1)
results["generator_ok"] = generator_scenario("gen_ok", False, 30)
print(json.dumps(results))
