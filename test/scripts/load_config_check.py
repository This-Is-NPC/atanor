#!/usr/bin/env python3
"""Drives scripts/load_config.py: no container is started.

Usage: load_config_check.py WORKDIR. Prints one JSON object (test/scripts/load_config_test.exs asserts it).
"""
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


example = lc.load_config(f"{repo}/load/rounds/example.toml")
official = lc.load_config(f"{repo}/load/rounds/018f.toml")
builtin = lc.load_config()


def resolved(text):
    return lc.load_config(write("resolved.toml", text))


def hashes(text, scenario, *measures):
    config = resolved(text)
    return [lc.case_hash(config, scenario, m) for m in measures]


store_override = resolved("[measures.ws.store]\nbacking = \"disk\"\nlatency_ms = 2.5\n")
ceiling_plan = lc.plan(resolved("[measures.cells.steps]\nkind = \"ceiling\"\nceiling = 400\n"), "cells", "A")
scale_scenario = lc.scale_of(resolved("[round]\nscenarios = [\"A\", \"B\"]\n[scale]\nceiling_factors = [1.0]\n[scale.per_scenario.B]\nceiling_factors = [2.0]\n"
                                      "[scale.per_scenario.B.ceilings]\n\"http-native:1\" = 7\n"), "B")
judging_override = resolved("[measures.ws.judging.p99]\nmax_ms = 400\n[measures.ws.judging.refused]\nenabled = false\n[measures.ws.judging]\nstall_repeats = 2\n")
base_hash = hashes("", "A", "ws", "cells", "swap", "scale")
reset_b_base = resolved("[round]\nscenarios = [\"A\", \"B\"]\n")
reset_b = resolved("[round]\nscenarios = [\"A\", \"B\"]\n[measures.http-wasm-jobs.per_scenario.B]\nreset_each_step = true\n")
scale_judging = resolved("[measures.scale.judging.p99]\nmax_ms = 400\n[measures.scale.judging.refused]\nmax_pct = 2\n"
                         "[scale.judging.cells.p99]\nmax_ms = 900\n[scale.judging.cells.errors]\nenabled = false\n")
plans = {f"{s}_{m}": lc.plan(official, m, s)["values"] for m in ("http-native", "ws", "cells", "http-wasm-jobs") for s in ("A", "B")}
a, b = lc.config_hash(builtin), lc.config_hash(lc.resolve({"judging": {"p99": {"max_ms": 250}}}))
c = lc.config_hash(lc.resolve({"judging": {"p99": {"max_ms": 300}}}))

NODE_ENV = ["ATANOR_LOAD_COMPACTION_" + k for k in ("HOLD_BYTES", "CONCURRENCY", "URGENT_CONCURRENCY", "MERGE_CONCURRENCY", "RELEASE_CONCURRENCY")] + \
           ["ATANOR_LOAD_S3_POOL_SIZE", "ATANOR_LOAD_S3_POOL_TIMEOUT_MS", "ATANOR_LOAD_ERL_FLAGS"]
node_set = resolved("[node.compaction]\nhold_bytes = 67108864\nconcurrency = 4\nurgent_concurrency = 8\nmerge_concurrency = 6\nrelease_concurrency = 2\n"
                    "[node.store]\npool_size = 512\npool_timeout_ms = 3000\n[node]\nerl_flags = \"+SDio 2 +S 1:1\"\n")
lazy_zero = resolved("[node.lazy_restore]\nmin_bytes = 0\n")
lazy_set = resolved("[node.lazy_restore]\nmin_bytes = 1048576\n")
erl_bad = [problems(f"[node]\nerl_flags = {json.dumps(v)}\n") for v in ("+SDio 2; rm", "+S \"1\"", "$HOME", "a`b`", "+S 1\n+A 2", "+SDio  2", " +S 1", 5)]

print(json.dumps({
    "example_is_default": example == builtin, "official": {"plans": plans, "http_wasm": lc.plan(official, "http-wasm", "A")["kind"], "scale": official["scale"],
                                                          "scale_run_on": official["measures"]["scale"]["run_on"], "store": official["store"]["backing"],
                                                          "min_available_gib": official["judging"]["host_memory"]["min_available_gib"],
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
    # store.nocow_dir is machine-specific: it enters no hash and the env lines carry it for a nocow store only
    "nocow": {"hash_same": hashes("[store]\nnocow_dir = \"/srv/store\"\n", "A", "ws") == base_hash[:1],
              "hash_backing_changes": hashes("[store]\nbacking = \"tmpfs\"\n", "A", "ws") != base_hash[:1],
              "env_dir": lc.env_lines(resolved("[store]\nnocow_dir = \"/srv/store\"\n"), "A")["ATANOR_LOAD_STORE_NOCOW_DIR"],
              "env_tmpfs": lc.env_lines(resolved("[store]\nbacking = \"tmpfs\"\nnocow_dir = \"/srv/store\"\n"), "A")["ATANOR_LOAD_STORE_NOCOW_DIR"],
              "relative": problems("[store]\nnocow_dir = \"store\"\n")},
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
    # [node.compaction] and [node.store]: env lines, validation, and a hash that only sees what is set
    "node_options": {"env_default": [lc.env_lines(builtin, "A")[k] for k in NODE_ENV], "env_set": [lc.env_lines(node_set, "A", "ws")[k] for k in NODE_ENV],
                     "hash_set_changes": lc.case_hash(node_set, "A", "ws") != base_hash[0],
                     "hash_default_as_before": lc.config_hash({**lc.case_config(builtin, "A", "ws"), "node": {"http_max_connections": 0}}) == base_hash[0],
                     "round_trip": lc.resolve(tomllib.loads(lc.dump_toml(node_set))) == node_set,
                     "erl_flags": {"default": builtin["node"]["erl_flags"], "default_hash_as_before": "erl_flags" not in lc.case_config(builtin, "A", "ws")["node"],
                                   "set_in_hash": lc.case_config(node_set, "A", "ws")["node"]["erl_flags"], "ok": problems("[node]\nerl_flags = \"+SDio 2 +S 1:1 +sbwt none\"\n"),
                                   "empty_ok": problems("[node]\nerl_flags = \"\"\n"), "bad": [len(p) for p in erl_bad]},
                     "bad": problems("[node.compaction]\nconcurrency = -1\nhold_bytes = \"big\"\nrelease_on = 4\n[node.store]\npool_size = 1.5\npool_timeout_ms = -1\nbogus = 1\n")},
    # [node.lazy_restore] min_bytes: unset (-1) by default, out of the hash and an empty env line; 0 is a value that reaches both
    "lazy_restore": {"default": builtin["node"]["lazy_restore"]["min_bytes"], "env_default": lc.env_lines(builtin, "A")["ATANOR_LOAD_LAZY_RESTORE_MIN_BYTES"],
                     "env_zero": lc.env_lines(lazy_zero, "A")["ATANOR_LOAD_LAZY_RESTORE_MIN_BYTES"], "env_set": lc.env_lines(lazy_set, "A", "cells")["ATANOR_LOAD_LAZY_RESTORE_MIN_BYTES"],
                     "default_not_in_hash": "lazy_restore" not in lc.case_config(builtin, "A", "cells")["node"],
                     "zero_in_hash": lc.case_config(lazy_zero, "A", "cells")["node"]["lazy_restore"], "zero_changes_hash": lc.case_hash(lazy_zero, "A", "cells") != lc.case_hash(builtin, "A", "cells"),
                     "round_trip": [lc.resolve(tomllib.loads(lc.dump_toml(c))) == c for c in (lazy_zero, lazy_set)],
                     "bad": [problems(f"[node.lazy_restore]\nmin_bytes = {v}\n") for v in ("-2", "\"4m\"", "1.5")]},
    # steps.reset_each_step (per measure, per scenario): off by default and then absent from the hash, so the rounds before it keep theirs
    "reset_each_step": {
        "default": lc.plan(builtin, "http-wasm-jobs", "A")["reset_each_step"],
        "plan_has_no_key": "reset_each_step" not in lc.case_config(builtin, "A", "ws")["plan"],
        "old_hashes": [lc.case_hash(official, "A", "ws")[:16], lc.case_hash(official, "B", "http-wasm-jobs")[:16], lc.case_hash(official, "A", "scale")[:16]],
        "scenario_only": [lc.plan(reset_b, "http-wasm-jobs", s)["reset_each_step"] for s in ("A", "B")],
        "hash": {"jobs_B_changes": lc.case_hash(reset_b, "B", "http-wasm-jobs") != lc.case_hash(reset_b_base, "B", "http-wasm-jobs"),
                 "jobs_A_same": lc.case_hash(reset_b, "A", "http-wasm-jobs") == lc.case_hash(reset_b_base, "A", "http-wasm-jobs"),
                 "ws_B_same": lc.case_hash(reset_b, "B", "ws") == lc.case_hash(reset_b_base, "B", "ws"),
                 "measure_wide": lc.case_hash(resolved("[measures.ws.steps]\nreset_each_step = true\n"), "A", "ws") != base_hash[0]},
        "round_trip": lc.resolve(tomllib.loads(lc.dump_toml(reset_b))) == reset_b,
        "bad": problems("[measures.ws.steps]\nreset_each_step = \"yes\"\n[measures.swap.steps]\nreset_each_step = true\n")},
    # steps.confirm_descents: 2 by default and then absent from the hash, so the rounds before it keep theirs; another value changes only that case's hash
    "confirm_descents": {
        "default": lc.plan(builtin, "cells", "A")["confirm_descents"],
        "plan_has_no_key": "confirm_descents" not in lc.case_config(builtin, "A", "cells")["plan"],
        "same_as_default": lc.case_hash(resolved("[measures.cells.steps]\nconfirm_descents = 2\n"), "A", "cells") == base_hash[1],
        "zero_changes": lc.case_hash(resolved("[measures.cells.steps]\nconfirm_descents = 0\n"), "A", "cells") != base_hash[1],
        "zero_in_plan": lc.case_config(resolved("[measures.cells.steps]\nconfirm_descents = 0\n"), "A", "cells")["plan"]["confirm_descents"],
        "ws_same": lc.case_hash(resolved("[measures.cells.steps]\nconfirm_descents = 0\n"), "A", "ws") == base_hash[0],
        "bad": problems("[measures.cells.steps]\nconfirm_descents = -1\n")},
    "official_plan_values":lc.plan_values(lc.plan(official, "http-wasm", "A"))[:3],
    # the names shared with Alambique, host.timeout_s and the per-measure judging
    "renames": {"data_tmpfs": [builtin["scenarios"]["A"]["data_tmpfs"], builtin["scenarios"]["B"]["data_tmpfs"]], "timeout_s": builtin["host"]["timeout_s"],
                "min_available_gib": builtin["judging"]["host_memory"]["min_available_gib"],
                "env_tmpfs": [lc.env_lines(builtin, "A")["ATANOR_LOAD_TMPFS_SIZE"], lc.env_lines(builtin, "B")["ATANOR_LOAD_TMPFS_SIZE"]],
                "old_node_tmpfs": problems("[scenarios.A]\nnode_tmpfs = \"1g\"\n"), "old_min_available_gb": problems("[judging.host_memory]\nmin_available_gb = 1\n"),
                "timeout_bad": problems("[host]\ntimeout_s = 0\n")},
    "measure_judging": {"override": judging_override["measures"]["ws"]["judging"], "others": judging_override["measures"]["cells"]["judging"],
                        "merged_ws": [lc.judging_of(judging_override, "ws")["p99"], lc.judging_of(judging_override, "ws")["refused"], lc.judging_of(judging_override, "ws")["stall_repeats"]],
                        "merged_cells": lc.judging_of(judging_override, "cells")["p99"], "general": judging_override["judging"]["p99"],
                        "hash_ws_changes": lc.case_hash(judging_override, "A", "ws") != base_hash[0], "hash_cells_same": lc.case_hash(judging_override, "A", "cells") == base_hash[1],
                        "hash_swap_same": lc.case_hash(judging_override, "A", "swap") == base_hash[2],
                        "bad": problems("[measures.ws.judging.p99]\nmax_ms = -1\nmax = 3\n[measures.ws.judging.nope]\nenabled = true\n"),
                        "round_trip": lc.resolve(tomllib.loads(lc.dump_toml(judging_override))) == judging_override},
    # [scale.judging.LOAD]: scale load > measures.scale.judging > [judging]; only that load changes, and the hash sees it
    "scale_judging": {"cells": [lc.judging_of(scale_judging, "scale", "cells")[k] for k in ("p99", "errors", "refused")],
                      "http_native": [lc.judging_of(scale_judging, "scale", "http-native")[k] for k in ("p99", "errors", "refused")],
                      "measure_only": lc.judging_of(scale_judging, "scale")["p99"], "other_measure": lc.judging_of(scale_judging, "cells", "cells")["p99"],
                      "hash_changes": lc.case_hash(scale_judging, "A", "scale") != lc.case_hash(resolved("[measures.scale.judging.p99]\nmax_ms = 400\n[measures.scale.judging.refused]\nmax_pct = 2\n"), "A", "scale"),
                      "hash_stable": hashes("", "A", "scale")[0] == base_hash[3], "hash_cells_same": lc.case_hash(scale_judging, "A", "cells") == lc.case_hash(resolved(""), "A", "cells"),
                      "round_trip": lc.resolve(tomllib.loads(lc.dump_toml(scale_judging))) == scale_judging,
                      "bad": problems("[scale.judging.cells.p99]\nmax_ms = -1\nmax = 3\n[scale.judging.cells.nope]\nenabled = true\n[scale.judging.ws.p99]\nmax_ms = 1\n")},
}))
