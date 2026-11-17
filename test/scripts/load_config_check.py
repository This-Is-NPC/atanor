#!/usr/bin/env python3
"""Drives scripts/load_config.py: no container is started.

Usage: load_config_check.py WORKDIR. Prints one JSON object (test/scripts/load_config_test.exs asserts it).
"""
import argparse
import importlib.machinery
import importlib.util
import json
import os
import sys
import tomllib

sys.dont_write_bytecode = True
work = sys.argv[1]
repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def module(name, path):
    spec = importlib.util.spec_from_loader(name, importlib.machinery.SourceFileLoader(name, path))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


lc = module("load_config", f"{repo}/scripts/load_config.py")
lr = module("load_run", f"{repo}/scripts/load-run")


def write(name, text):
    path = os.path.join(work, name)
    with open(path, "w") as file:
        file.write(text)
    return path


def problems(text):
    """The problems of a config given as TOML text; [] when it is valid."""
    try:
        lc.load_config(write("case.toml", text))
        return []
    except lc.ConfigError as error:
        return error.problems


def missing():
    try:
        lc.load_config(os.path.join(work, "absent.toml"))
    except lc.ConfigError as error:
        return error.problems
    return []


# The defaults of load-run's arguments: main() builds the parser and parses, so stop it at the parse.
class Parsed(Exception):
    pass


original = argparse.ArgumentParser.parse_args


def capture(self, *args, **kwargs):
    raise Parsed(original(self, ["http-native"]))


argparse.ArgumentParser.parse_args = capture
try:
    lr.main()
except Parsed as parsed:
    defaults = vars(parsed.args[0])
finally:
    argparse.ArgumentParser.parse_args = original

example = lc.load_config(f"{repo}/load/rounds/example.toml")
official = lc.load_config(f"{repo}/load/rounds/018f.toml")
builtin = lc.load_config()
j, s, g, w, sw, sc = (builtin[k] for k in ("judging", "scale", "generator", "workload", "swap", "scale"))
# argparse dest -> value of the config
same = {
    "step_s": builtin["measures"]["http-native"]["steps"]["duration_s"], "factor": builtin["measures"]["http-native"]["steps"]["factor"],
    "refine": builtin["measures"]["http-native"]["steps"]["refine"], "p99_ms": j["p99"]["max_ms"], "max_refused_pct": j["refused"]["max_pct"],
    "memory_pct": j["memory"]["max_pct"], "fd_pct": j["fds"]["max_pct"], "delivery": j["delivery"]["min_ratio"],
    "host_load_max": j["host_load"]["max"], "max_busy_share": j["host_busy"]["max_share"], "quiet_window": j["host_load"]["quiet_window_s"],
    "quiet_max_wait": j["host_load"]["quiet_max_wait_s"], "max_generator_swap_mb": j["generator_swap"]["max_mb"],
    "max_host_swap_growth_mb": j["host_swap"]["max_growth_mb"], "max_store_disk_pct": j["store_fill"]["max_disk_pct"],
    "max_store_tmpfs_pct": j["store_fill"]["max_tmpfs_pct"], "max_lag_ms": j["generator_lag"]["max_ms"],
    "max_throttle_jump_ms": j["throttle"]["max_jump_ms"], "max_store_stall_ms": j["store_stall"]["min_ms"],
    "store_stall_requests": j["store_stall"]["min_requests"], "min_available_gb": j["host_memory"]["min_available_gb"],
    "sample_s": g["sample_s"], "timeout": g["timeout_s"], "gen_grace": g["grace_s"], "rate_per_proc": g["rate_per_proc"], "conns_per_rate": g["conns_per_rate"],
    "write_ratio": w["write_ratio"], "cells": w["cells"], "cell_period": w["cell_period_s"], "cells_conns": w["cells_conns"], "open_rate": w["open_rate"],
    "ws_interval": w["ws_interval_s"], "worker": w["worker"], "trigger": sw["trigger"], "swap_workers": sw["workers"], "swap_warmup": sw["warmup_s"],
    "swap_overlap": sw["overlap_s"], "swap_settle": sw["settle_s"], "swap_timeout": sw["timeout_s"], "max_nodes": sc["max_nodes"],
    "scale_factor": sc["factor"], "join_factor": sc["join"]["factor"], "join_warmup_s": sc["join"]["warmup_s"], "join_observe_s": sc["join"]["observe_s"],
    "join_node_wait_s": sc["join"]["node_wait_s"], "join_node_timeout_s": sc["join"]["node_timeout_s"], "join_sample_s": sc["join"]["sample_s"],
    "spread_tol_pct": sc["spread"]["tol_pct"], "spread_hold": sc["spread"]["hold"], "spread_min_cells": sc["spread"]["min_cells"],
    "loads": ",".join(sc["loads"]), "factors": ",".join(f"{f:g}" for f in sc["ceiling_factors"]),
}
mismatch = {k: [defaults[k], v] for k, v in same.items() if defaults[k] != v}
ramps = {m: [builtin["measures"][m]["steps"]["start"], builtin["measures"][m]["steps"]["max"]] for m in lc.RAMP_MEASURES}

def resolved(text):
    return lc.load_config(write("resolved.toml", text))


def hashes(text, scenario, *measures):
    config = resolved(text)
    return [lc.case_hash(config, scenario, m) for m in measures]


store_override = resolved("[measures.ws.store]\nbacking = \"disk\"\nlatency_ms = 2.5\n")
ceiling_plan = lc.plan(resolved("[measures.cells.steps]\nkind = \"ceiling\"\nceiling = 400\n"), "cells", "A")
scale_scenario = lc.scale_of(resolved("[round]\nscenarios = [\"A\", \"B\"]\n[scale]\nceiling_factors = [1.0]\n[scale.per_scenario.B]\nceiling_factors = [2.0]\n"
                                      "[scale.per_scenario.B.ceilings]\n\"http-native:1\" = 7\n"), "B")
base_hash = hashes("", "A", "ws", "cells", "swap", "scale")
plans = {f"{s}_{m}": lc.plan(official, m, s)["values"] for m in ("http-native", "ws", "cells", "http-wasm-jobs") for s in ("A", "B")}
a, b = lc.config_hash(builtin), lc.config_hash(lc.resolve({"judging": {"p99": {"max_ms": 250}}}))
c = lc.config_hash(lc.resolve({"judging": {"p99": {"max_ms": 300}}}))

print(json.dumps({
    "mismatch": mismatch, "checked": len(same), "ramps": ramps, "ramps_of_load_run": {m: list(v) for m, v in lr.RAMPS.items() if m in lc.RAMP_MEASURES},
    "units_match": sorted(lc.MEASURES) == sorted(lr.UNITS), "scale_loads_match": list(lc.SCALE_LOADS) == list(lr.SCALE_LOADS),
    "example_is_default": example == builtin, "official": {"plans": plans, "http_wasm": lc.plan(official, "http-wasm", "A")["kind"], "scale": official["scale"],
                                                          "scale_run_on": official["measures"]["scale"]["run_on"], "store": official["store"]["backing"],
                                                          "min_available_gb": official["judging"]["host_memory"]["min_available_gb"],
                                                          "max_connections": official["node"]["http_max_connections"]},
    "hash": {"stable": a == b, "changes": a != c, "length": len(a)},
    "unknown_key": problems("[measures.cells.steps]\nfactr = 3\n"),
    "unknown_table": problems("[judgng.p99]\nmax_ms = 1\n"),
    "wrong_type": problems("[judging.p99]\nmax_ms = \"fast\"\n[judging.delivery]\nenabled = 1\n"),
    "out_of_range": problems("[judging.delivery]\nmin_ratio = 1.5\n[judging.refused]\nmax_pct = 0\n[measures.cells.steps]\nrefine = -1\n"),
    "unknown_measure": problems("[round]\nmeasures = [\"http-native\", \"disk\"]\n[measures.disk]\nrun_on = []\n"),
    "unknown_scenario": problems("[round]\nscenarios = [\"C\"]\n[scenarios.C]\ncpus = 1\n"),
    "ladder_without_values": problems("[measures.cells.steps]\nkind = \"ladder\"\n"),
    "ladder_not_growing": problems("[measures.cells.steps]\nkind = \"ladder\"\nvalues = [10, 5]\n"),
    "bisect_start_above_max": problems("[measures.ws.steps]\nstart = 100\nmax = 50\n"),
    "bisect_with_values": problems("[measures.ws.steps]\nvalues = [1, 2]\n"),
    "per_scenario_not_in_round": problems("[measures.ws.per_scenario.B]\nkind = \"ladder\"\nvalues = [1]\n"),
    "per_scenario_ladder": problems("[round]\nscenarios = [\"A\", \"B\"]\n[measures.ws.per_scenario.B]\nkind = \"ladder\"\n"),
    "bad_size": problems("[scenarios.A]\nmemory = \"lots\"\n"),
    "ceiling_key": problems("[scale.ceilings]\n\"cells\" = 5\n\"cells:9\" = 5\n\"ws:1\" = 5\n"),
    "ssh_without_repo": problems("[host]\nssh = \"lab\"\n"),
    "many": len(problems("[judging.p99]\nmax_ms = -1\n[judging.refused]\nmax_pct = 500\n[bogus]\nx = 1\n")),
    "not_toml": problems("[judging\n"),
    "missing_file": missing(),
    # round.cases: the order, the conflict with run_on, the reserved variant
    "cases_order": lc.case_list(resolved("[round]\ncases = [\"B/ws\", \"A/cells\", \"A/swap\"]\n")),
    "cases_default": lc.case_list(resolved("[round]\nscenarios = [\"A\", \"B\"]\nmeasures = [\"ws\", \"scale\"]\n[measures.scale]\nrun_on = [\"A\"]\n")),
    "cases_run_on": problems("[round]\ncases = [\"A/ws\"]\n[measures.ws]\nrun_on = [\"A\"]\n"),
    "cases_variant": problems("[round]\ncases = [\"A/ws/x\"]\n"),
    "cases_bad": problems("[round]\ncases = [\"A\", \"C/ws\", \"A/disk\", \"A/cells\", \"A/cells\"]\n"),
    "variant_table": problems("[measures.ws.variant.v.store]\nbacking = \"disk\"\n"),
    # [measures.M.store]: the override, its own hash and lab, and what it validates
    "store_override": {"ws": store_override["measures"]["ws"]["store"], "cells": store_override["measures"]["cells"]["store"],
                       "env_ws": lc.env_lines(store_override, "A", "ws")["ATANOR_LOAD_STORE_DISK"], "env_cells": lc.env_lines(store_override, "A", "cells")["ATANOR_LOAD_STORE_DISK"],
                       "latency_ws": lc.env_lines(store_override, "A", "ws")["ATANOR_LOAD_STORE_LATENCY_MS"],
                       "hash_ws_changes": lc.case_hash(store_override, "A", "ws") != base_hash[0], "hash_cells_same": lc.case_hash(store_override, "A", "cells") == base_hash[1]},
    "store_override_bad": problems("[measures.ws.store]\nbacking = \"usb\"\nmemory = \"1g\"\n"),
    # the timeouts, the connection cap of ws, the ceiling kind
    "timeout_low": problems("[round]\nmeasures = [\"ws\"]\nstep_timeout_s = 100\n"),
    "timeout_ok": problems("[round]\nmeasures = [\"ws\"]\nstep_timeout_s = 210\n"),
    "timeout_default_is_valid": problems("[round]\nmeasures = [\"http-native\", \"scale\"]\n"),
    "timeout_scale_join": problems("[round]\nmeasures = [\"scale\"]\nstep_timeout_s = 300\n[scale]\nmax_nodes = 2\n"),
    "ws_cap": problems("[round]\nmeasures = [\"ws\"]\n[node]\nhttp_max_connections = 1000\n[measures.ws.steps]\nkind = \"ladder\"\nvalues = [500, 1000]\n"),
    "ws_cap_ok": problems("[round]\nmeasures = [\"ws\"]\n[node]\nhttp_max_connections = 1000\n[measures.ws.steps]\nkind = \"ladder\"\nvalues = [500, 999]\n"),
    "ws_cap_bisect": problems("[round]\nmeasures = [\"ws\"]\n[node]\nhttp_max_connections = 1000\n"),
    "ceiling_plan": [ceiling_plan["kind"], lc.plan_values(ceiling_plan)],
    "ceiling_missing": problems("[measures.cells.steps]\nkind = \"ceiling\"\n"),
    "ceiling_with_values": problems("[measures.cells.steps]\nkind = \"ceiling\"\nceiling = 5\nvalues = [1]\n"),
    "scale_per_scenario": [scale_scenario["ceilings"], scale_scenario["ceiling_factors"]],
    "scale_per_scenario_bad": problems("[scale.per_scenario.A.ceilings]\n\"cells:9\" = 5\n"),
    "errors_off": resolved("[judging.errors]\nenabled = false\n")["judging"]["errors"],
    # the hash of a case: the case's own settings, not the other measures', the output, the host or the timeouts
    "case_hash": {"stable": base_hash == hashes("[output]\nname = \"x\"\n[host]\nssh = \"lab\"\nrepo = \"/r\"\n[round]\ntimeout_s = 5\nstep_timeout_s = 700\n", "A", "ws", "cells", "swap", "scale"),
                  "ws_only_with_ws": [a == b for a, b in zip(hashes("[measures.cells.steps]\nrefine = 1\n", "A", "ws", "cells", "swap", "scale"), base_hash)],
                  "store_all": [a != b for a, b in zip(hashes("[store]\nlatency_ms = 30\n", "A", "ws", "cells", "swap", "scale"), base_hash)],
                  "scenario": hashes("[round]\nscenarios = [\"A\", \"B\"]\n", "B", "ws")[0] != base_hash[0],
                  "scale_sees_load_plans": hashes("[measures.cells.steps]\nrefine = 1\n", "A", "scale")[0] != base_hash[3],
                  "swap_section": hashes("[swap]\nworkers = 3\n", "A", "swap")[0] != base_hash[2]},
    # the resolved config as TOML reads back to itself
    "toml_round_trip": [lc.resolve(tomllib.loads(lc.dump_toml(c))) == c for c in (builtin, official, example, store_override, resolved("[scale.ceilings]\n\"cells:1\" = 5\n"))],
    "env_scale_no_nodes": ["ATANOR_LOAD_NODES" in lc.env_lines(official, "A", "scale"), lc.env_lines(official, "A", "ws")["ATANOR_LOAD_NODES"]],
    "env_cap": [lc.env_lines(builtin, "A")["ATANOR_LOAD_HTTP_MAX_CONNECTIONS"], lc.env_lines(official, "B", "ws")["ATANOR_LOAD_HTTP_MAX_CONNECTIONS"]],
    "official_plan_values": lc.plan_values(lc.plan(official, "http-wasm", "A"))[:3],
}))
