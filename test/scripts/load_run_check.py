#!/usr/bin/env python3
"""Drives scripts/load-run's Round with a stub `docker` and `load-env` on PATH, no container started.

Usage: load_run_check.py WORKDIR. Prints one JSON object: the step records of each scenario (test/scripts/load_run_test.exs asserts them).
"""
import argparse
import importlib.machinery
import importlib.util
import json
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
  logs) echo "beam: eheap_alloc: cannot allocate memory" ;;
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

DOCUMENT = {"statuses": {"message answered": 10}, "hist": {"5": 10}, "max_ms": 1.0, "planned": 10, "sent": 10, "completed": 10,
            "cpu_s": 0.1, "lag_ms": {"p99": 1}, "opened": 10}
hook = {"during": lambda: None, "error": None}


def run_generators(self, value, sampler):
    hook["during"]()
    if hook["error"]:
        raise RuntimeError(hook["error"])
    return [dict(DOCUMENT)]


m.Round.run_generators = run_generators


def new_round(name):
    out = os.path.join(work, name)
    os.makedirs(out)
    args = argparse.Namespace(out=out, measure="ws", step_s=1.0, timeout=1.0, gen_grace=1.0, open_rate=100.0, host_load_max=1e9, min_available_gb=0.0,
                              sample_s=0.05, repeat_invalid=0, host_wait=0.0, delivery=0.95, memory_pct=1e9, fd_pct=1e9, p99_ms=250.0,
                              max_generator_swap_mb=1e9, max_host_swap_growth_mb=1e12, command="test", steps="10,20", start=10, max=20, factor=2, refine=0)
    pid = os.getpid()
    info = {"scenario": "A", "memory_limit_bytes": 512 * MB, "store_latency_ms": 25, "node": {"id": "abc", "ip": "127.0.0.1", "pid": pid}, "store": {"ip": "127.0.0.1", "pid": pid},
            "lb": {"pid": pid}, "admin": "http://127.0.0.1:1"}
    return m.Round(args, info), args


def scenario(name, during=lambda: None, error=None, before=None, info=None):
    container(**(before or {}))
    hook.update(during=during, error=error)
    round_, _ = new_round(name)
    round_.info.update(info or {})
    record = round_.step(10, "ramp")
    return {"record": record, "files": sorted(os.listdir(round_.args.out))}


results = {}
# The node is fine; only the store rtt measurement fails (load-env exits 1).
results["rtt_fails"] = scenario("rtt_fails")
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
                          "refuse_at_bytes": 400 * MB, "refusing": n > 1, "disk_used_bytes": None, "disk_budget_bytes": None, "disk_refusing": False}}


real_admin_json = m.admin_json
m.admin_json = fake_runtime
real_cgroup_sample, real_s3 = m.cgroup_sample, m.s3_counters
m.cgroup_sample = lambda d: {"memory_current": 300 * MB, "shmem": 256 * MB if "store" in d else 1, "peak": 300 * MB, "limit": 1280 * MB, "cpu_s": time.time(), "cpu_limit": 1.0}
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
    return {"summary": summary, "generator_runs": len(calls), "files": sorted(f for f in os.listdir(args.out) if f.endswith(".json"))}


results["ramp"] = ramp_scenario("ramp", dies_at=2)
# After a failing step the refine and confirm steps run on a fresh node (a stubbed reset); ramp steps and a clean confirmation do not.
def fresh_scenario(name, slow_call):
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
        args.measure, args.steps, args.refine = "http-native", "10,20", 2
        summary = m.ramp(round_, args)
    finally:
        m.load_env, m.Round.run_generators = real_load_env, real_generators
    steps = []
    for file in sorted(f for f in os.listdir(args.out) if f.endswith(".json") and "summary" not in f):
        with open(os.path.join(args.out, file)) as handle:
            record = json.load(handle)
        steps.append([record["phase"], record["status"], record["fresh_node"], record["reset_s"] is not None])
    return {"steps": steps, "resets": resets, "approved": summary["approved"]}


results["fresh_after_fail"] = fresh_scenario("fresh_after_fail", slow_call=2)
results["fresh_never_failed"] = fresh_scenario("fresh_never_failed", slow_call=0)

# A step that starts with a dead node is invalid, runs no generator and ends the round.
results["dead_at_start"] = ramp_scenario("dead_at_start", dies_at=0, before={"running": False, "exit_code": 137})

# The memory criterion: memory.current - shmem against the scenario's memory, the tmpfs recorded apart (start, max, growth).
def memory_sample(t, current_mb, shmem_mb):
    host = {"cpu_total": 100 * (t + 1), "cpu_idle": 100 * (t + 1), "loadavg1": 0.0, "available_gb": 8.0, "swap_used_mb": 0}
    node = {"memory_current": current_mb * MB, "shmem": shmem_mb * MB, "peak": current_mb * MB, "limit": (512 + 768) * MB, "cpu_s": float(t), "cpu_limit": 1.0}
    return {"t": float(t), "node": node, "store": {}, "lb": {}, "gen_cpu_s": 0.0, "gen_swap_mb": 0, "fds": None, "host": host}


# 700 MB current, 300 of it tmpfs: the service uses 400 MB of the 512 MB scenario, not 700 of 1280.
usage = m.summarize([memory_sample(0, 650, 256), memory_sample(1, 700, 300)], 0, 512 * MB)["memory"]
results["memory_criterion"] = {k: usage[k] for k in ("service_max_mb", "tmpfs_start_mb", "tmpfs_max_mb", "tmpfs_growth_mb", "limit_mb", "max_pct_of_limit")}

# The swap record: a stub cluster-swap-run writes result.json; the node is measured, so the usage is summarized against the scenario memory.
os.makedirs(os.path.join(work, "scripts"))
stub = os.path.join(work, "scripts", "cluster-swap-run")
with open(stub, "w") as file:
    file.write("#!/bin/sh\nwhile [ $# -gt 0 ]; do [ \"$1\" = --out ] && out=$2; shift; done\nmkdir -p \"$out\"\n"
               "echo '{\"sent\": 100, \"duration_s\": 10, \"a_exit_s\": 1.5, \"lost\": 0, \"duplicated\": 0, \"errors\": {}, \"phases\": {\"warmup\": {\"p99\": 20, \"max\": 30}}}' > \"$out/result.json\"\n")
os.chmod(stub, os.stat(stub).st_mode | stat.S_IXUSR)
m.Sampler.take = lambda self: memory_sample(time.time(), 650, 256)
swap_round, swap_args = new_round("swap")
swap_args.rate, swap_args.trigger, swap_args.swap_workers = 10, "sigterm", 1
swap_args.swap_warmup = swap_args.swap_overlap = swap_args.swap_settle = 1
swap_args.swap_timeout = 30
m.swap(swap_round, swap_args, swap_round.info)
with open(os.path.join(swap_args.out, "A_swap_01-swap-10.json")) as file:
    swap_record = json.load(file)
results["swap"] = {k: swap_record[k] for k in ("status", "valid", "stop_reason")} | {"service_max_mb": swap_record["memory"]["service_max_mb"],
                                                                                    "limit_mb": swap_record["memory"]["limit_mb"]}

# Host swap is judged by its growth during the step; a high but flat level is valid.
def swap_usage(start, peak):
    return {"swap_usage": {"containers_max_mb": {}, "generator_growth_mb": 0}, "host": dict(zip(("swap_start_mb", "swap_max_mb", "swap_growth_mb"), m.swap_growth_mb([start, peak])))}


results["host_swap"] = {"flat": m.judge_swap(swap_usage(3380, 3380), 16, 256), "grows": m.judge_swap(swap_usage(3380, 3680), 16, 256)}

print(json.dumps(results))
