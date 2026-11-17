#!/usr/bin/env python3
"""Drives scripts/load (the round of a config file) with stub `mise`, `load-run`, `load-env` and `load-report`: no container is started.

Usage: load_round_check.py WORKDIR. Prints one JSON object (test/scripts/load_run_test.exs asserts it).
"""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import stat
import subprocess
import sys

sys.dont_write_bytecode = True
work = sys.argv[1]
repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
fake = os.path.join(work, "fake")
log = os.path.join(work, "calls.log")
os.makedirs(fake)

STUBS = {
    "mise": '#!/bin/sh\necho "mise $*" >> "$FAKE_LOG"\n[ -e "$FAKE_DIR/mise-fails" ] && [ "$2" = load:up ] && exit 1\nexit 0\n',
    "load-env": '#!/bin/sh\necho "load-env $*" >> "$FAKE_LOG"\n',
    "load-report": '#!/bin/sh\necho "load-report $*" >> "$FAKE_LOG"\n',
    "load-run": '#!/bin/sh\necho "load-run $*" >> "$FAKE_LOG"\necho "env $ATANOR_LOAD_SCENARIO $ATANOR_LOAD_MEASURE" >> "$FAKE_LOG"\n'
                '[ -e "$FAKE_DIR/sleep-$1" ] && sleep 0.6\n[ -e "$FAKE_DIR/exit-$1" ] && exit "$(cat "$FAKE_DIR/exit-$1")"\nexit 0\n',
    # the remote host: `ssh HOST SCRIPT` answers the check and the status from files, anything else is the start of the round
    "ssh": '#!/bin/sh\necho "ssh $1 :: $2" >> "$FAKE_LOG"\ncase "$2" in\n  *"git fetch"*) cat "$FAKE_DIR/ssh-check" ;;\n  *"tail -n"*) cat "$FAKE_DIR/ssh-status" ;;\n'
           '  *) echo started ;;\nesac\n',
    "rsync": '#!/bin/sh\necho "rsync $*" >> "$FAKE_LOG"\n',
    "scp": '#!/bin/sh\necho "scp $*" >> "$FAKE_LOG"\n',
}
for name, body in STUBS.items():
    path = os.path.join(fake, name)
    with open(path, "w") as file:
        file.write(body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
os.environ.update(PATH=fake + os.pathsep + os.environ["PATH"], FAKE_DIR=fake, FAKE_LOG=log)

spec = importlib.util.spec_from_loader("load_round", importlib.machinery.SourceFileLoader("load_round", f"{repo}/scripts/load"))
ld = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ld)
ld.HERE = fake
lc = ld.load_config


def run(name, toml, *argv, flags=(), setup=lambda out: None):
    """Runs a round of `toml` (in its own output directory) and returns its status, what it printed and the calls the stubs recorded."""
    out = os.path.join(work, name)
    path = os.path.join(work, f"{name}.toml")
    with open(path, "w") as file:
        file.write(f"[output]\ndir = \"{out}\"\n" + toml)
    for stub in os.listdir(fake):
        if stub.startswith(("exit-", "sleep-")) or stub == "mise-fails":
            os.remove(os.path.join(fake, stub))
    for flag, text in flags:
        with open(os.path.join(fake, flag), "w") as file:
            file.write(text)
    setup(out)
    if os.path.exists(log):
        os.remove(log)
    stdout, stderr = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
        status = ld.main(["--config", path, *argv])
    calls = []
    if os.path.exists(log):
        with open(log) as file:
            calls = [line.rstrip().replace(out, "OUT").replace(fake + "/", "") for line in file]
    return {"status": status, "stdout": stdout.getvalue().replace(out, "OUT"), "stderr": stderr.getvalue().replace(out, "OUT"), "calls": calls, "out": out}


def mise(result):
    return [c for c in result["calls"] if c.startswith(("mise", "load-env", "load-report"))]


def load_runs(result):
    return [c for c in result["calls"] if c.startswith("load-run")]


results = {}

# --dry-run: the plan of the official round, with nothing started and nothing written
with contextlib.redirect_stdout(io.StringIO()) as shown:
    status = ld.main(["--config", f"{repo}/load/rounds/018f.toml", "--dry-run"])
text = shown.getvalue()
config = lc.load_config(f"{repo}/load/rounds/018f.toml")
results["dry_run"] = {"status": status, "text": text.replace(repo, "REPO"), "hashes": all(lc.case_hash(config, s, m) in text for s, m in lc.case_list(config)),
                      "calls": os.path.exists(log), "results_dir": os.path.exists(f"{repo}/load/results/018f")}

# an invalid config is refused with every problem and nothing starts
bad = run("bad", "[judging.p99]\nmax_ms = -1\n[round]\nstep_timeout_s = 10\nmeasures = [\"ws\"]\n[nope]\nx = 1\n")
results["invalid"] = {"status": bad["status"], "stderr": bad["stderr"], "calls": bad["calls"], "out_made": os.path.exists(bad["out"])}

# a round of two scenarios: the lab is started per scenario, each measure after the first runs on a fresh lab, the report follows its scenario
two = run("two", "[round]\nscenarios = [\"A\", \"B\"]\nmeasures = [\"http-native\", \"swap\"]\n")
resolved = lc.load_config(os.path.join(two["out"], "config.toml"))
results["two"] = {"status": two["status"], "calls": two["calls"], "config_toml": resolved["output"]["dir"] == two["out"] and resolved["round"]["scenarios"] == ["A", "B"]}

# a measure with its own store has its own lab, and the next one goes back to the scenario's
own = run("own", "[round]\nmeasures = [\"http-native\", \"ws\", \"cells\"]\n[measures.ws.store]\nbacking = \"disk\"\n")
results["own_lab"] = {"status": own["status"], "calls": mise(own)}

# a measure that ends INVALID (exit 1) does not stop the others, but the round's status is 1; the timeout of the round (exit 3) stops it
invalid = run("invalid_exit", "[round]\nmeasures = [\"http-native\", \"cells\"]\n", flags=[("exit-http-native", "1")])
stopped = run("stopped", "[round]\nmeasures = [\"http-native\", \"cells\"]\n", flags=[("exit-http-native", "3")])
results["exits"] = {"invalid": [invalid["status"], len(load_runs(invalid))], "stopped": [stopped["status"], len(load_runs(stopped)), "STOP" in stopped["stdout"],
                                                                                          mise(stopped)[-2:]]}

# --skip-done and the hash of a case: a file of another config refuses the round before any container; --no-skip-done runs it
def step_file(out, config_hash):
    os.makedirs(os.path.join(out, "A", "http-native"))
    with open(os.path.join(out, "A", "http-native", "step-10.json"), "w") as file:
        json.dump({"config_hash": config_hash}, file)


other = lambda out: step_file(out, "another")
same = lambda out: step_file(out, lc.case_hash(lc.resolve({"round": {"measures": ["http-native"]}}), "A", "http-native"))
refused = run("refused", "[round]\nmeasures = [\"http-native\"]\n", setup=other)
forced = run("forced", "[round]\nmeasures = [\"http-native\"]\n", "--no-skip-done", setup=other)


kept = run("kept", "[round]\nmeasures = [\"http-native\"]\n", setup=same)
results["hash"] = {"refused": [refused["status"], refused["calls"], refused["stderr"]], "forced": [forced["status"], [c.split(" --scenario ")[1] for c in load_runs(forced)]],
                   "same_hash_runs": [kept["status"], len(load_runs(kept))], "skip_flag": load_runs(kept)[0].endswith("--skip-done")}

# the timeout of the round: the case that passes it ends, the next one does not start; the lab is removed
slow = run("slow", "[round]\nmeasures = [\"http-native\", \"cells\"]\ntimeout_s = 0.3\n", flags=[("sleep-http-native", "")])
results["round_timeout"] = {"status": slow["status"], "runs": len(load_runs(slow)), "deadline_passed": "--deadline" in load_runs(slow)[0], "stdout": "STOP: round.timeout_s passed" in slow["stdout"],
                            "calls": mise(slow)}

# a lab that does not start ends the round, and what was started is removed
broken = run("broken", "[round]\nmeasures = [\"http-native\"]\n", flags=[("mise-fails", "")])
results["lab_fails"] = {"status": broken["status"], "runs": len(load_runs(broken)), "calls": mise(broken)}

# the scale measure keeps the lab (it starts its own nodes), and the measures around it reset as usual
scale = run("scale", "[round]\nmeasures = [\"http-native\", \"scale\", \"cells\"]\n")
results["scale"] = {"status": scale["status"], "calls": mise(scale)}
# a case whose steps and summary are all done (same hash, none INVALID) is reused without a lab; the others run on a lab started for them
HASHES = {m: lc.case_hash(lc.resolve({"round": {"measures": ["http-native", "cells"]}}), "A", m) for m in ("http-native", "cells")}


def done_case(measure, step_status="ok", step_hash=None):
    def setup(out):
        case = os.path.join(out, "A", measure)
        os.makedirs(case)
        for name, document in (("step-10.json", {"config_hash": step_hash or HASHES[measure], "status": step_status, "valid": step_status != "invalid"}),
                               ("summary.json", {"config_hash": HASHES[measure], "invalid": None})):
            with open(os.path.join(case, name), "w") as file:
                json.dump(document, file)
    return setup


both = "[round]\nmeasures = [\"http-native\", \"cells\"]\n"
all_done = run("all_done", "[round]\nmeasures = [\"http-native\"]\n", setup=done_case("http-native"))
some_done = run("some_done", both, setup=done_case("http-native"))
invalid_step = run("invalid_step", "[round]\nmeasures = [\"http-native\"]\n", setup=done_case("http-native", step_status="invalid"))
forced_done = run("forced_done", "[round]\nmeasures = [\"http-native\"]\n", "--no-skip-done", setup=done_case("http-native"))
results["done_case"] = {"all_done": [all_done["status"], mise(all_done), len(load_runs(all_done)), "no lab started" in all_done["stdout"]],
                        "some_done": [some_done["status"], mise(some_done), [c.split(" ")[1] for c in load_runs(some_done)]],
                        "invalid_step": [mise(invalid_step), len(load_runs(invalid_step))], "no_skip_done": [mise(forced_done), len(load_runs(forced_done))]}

# --remote, --status and --fetch with a stubbed ssh, scp and rsync: nothing remote happens without one of them
head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True).stdout.strip()
HOST = "name = \"r1\"\n[host]\nssh = \"lab\"\nrepo = \"/srv/atanor\"\nresults = \"/srv/results/r1\"\ntimeout_s = 3600\n"


def remote(name, check="", status="", *flags, toml=HOST):
    for file, text in (("ssh-check", check), ("ssh-status", status)):
        with open(os.path.join(fake, file), "w") as handle:
            handle.write(text)
    return run(name, toml, *flags)


def network(result):
    return [c for c in result["calls"] if c.startswith(("ssh", "scp", "rsync"))]


good = f"HEAD={head}\nCONFIG=ok\nRUNNING=no\n"
started = remote("remote_ok", good, "", "--remote")
dirty = remote("remote_dirty", f" M lib/a.ex\n?? scratch\n{good}", "", "--remote")
behind = remote("remote_behind", "HEAD=0123456789abcdef\nCONFIG=ok\nRUNNING=no\n", "", "--remote")
busy = remote("remote_busy", f"HEAD={head}\nCONFIG=ok\nRUNNING=yes\n", "", "--remote")
absent = remote("remote_absent", f"HEAD={head}\nCONFIG=missing\nRUNNING=no\n", "", "--remote")
nohost = remote("remote_nohost", good, "", "--remote", toml="")
local = remote("remote_local", good, "", toml=HOST + "[round]\nmeasures = [\"http-native\"]\n")
results["remote"] = {"start": {"status": started["status"], "calls": network(started), "stdout": started["stdout"]},
                     "dirty": {"status": dirty["status"], "calls": len(network(dirty)), "stderr": dirty["stderr"], "stdout": dirty["stdout"]},
                     "behind": {"status": behind["status"], "calls": len(network(behind)), "stderr": behind["stderr"], "stdout": behind["stdout"]},
                     "busy": [busy["status"], len(network(busy)), busy["stderr"]], "absent": [absent["status"], len(network(absent)), absent["stderr"]],
                     "nohost": [nohost["status"], len(network(nohost)), nohost["stderr"]],
                     "local_round": {"status": local["status"], "network": network(local), "note": "this run is local" in local["stdout"], "runs": len(load_runs(local))},
                     "head": head}

# --status: whether the round is alive and the end of its log, without the lines that name a secret
status_text = "round: running (pid 4242)\nmeasure A/ws step 20\ns3 secret_access_key=abc123\nTOKEN seen\nthe admin key is x\nPassword=1\nlast line\n"
alive = remote("remote_status", "", status_text, "--status")
results["status"] = {"status": alive["status"], "stdout": alive["stdout"], "calls": network(alive)}

# --fetch: rsync when there is one, else scp -r; the local directory is the output dir
fetched = remote("remote_fetch", "", "", "--fetch")
real_which = ld.shutil.which
ld.shutil.which = lambda name: None
try:
    scp_fetch = remote("remote_fetch_scp", "", "", "--fetch")
finally:
    ld.shutil.which = real_which
results["fetch"] = {"rsync": [fetched["status"], network(fetched)], "scp": [scp_fetch["status"], network(scp_fetch)], "made": os.path.isdir(fetched["out"])}
print(json.dumps(results))
