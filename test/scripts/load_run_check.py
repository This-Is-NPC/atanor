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
                              max_generator_swap_mb=1e9, max_host_swap_mb=1e12, command="test", steps="10,20", start=10, max=20, factor=2, refine=0)
    pid = os.getpid()
    info = {"scenario": "A", "store_latency_ms": 25, "node": {"id": "abc", "ip": "127.0.0.1", "pid": pid}, "store": {"ip": "127.0.0.1", "pid": pid},
            "lb": {"pid": pid}, "admin": "http://127.0.0.1:1"}
    return m.Round(args, info), args


def scenario(name, during=lambda: None, error=None, before=None):
    container(**(before or {}))
    hook.update(during=during, error=error)
    round_, _ = new_round(name)
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
# A ramp whose second step breaks the node ends in a summary, not a crash.
container()
hook.update(during=lambda: None, error=None)
round_, args = new_round("ramp")
calls = []


def die_on_second():
    calls.append(1)
    if len(calls) == 2:
        container(running=False, oom=True, exit_code=137)


hook["during"] = die_on_second
results["ramp"] = m.ramp(round_, args)
print(json.dumps(results))
