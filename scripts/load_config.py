#!/usr/bin/env python3
"""The round config of the load tests: read a TOML file, merge it over the built-in defaults, validate it.

  load_config.py --check FILE     print the resolved config (JSON) and its hash; exit 1 and list every problem when it is invalid
  load_config.py --defaults       print the built-in defaults
  load_config.py --env FILE SCENARIO [MEASURE]   print the ATANOR_LOAD_* lines of the lab of a scenario (and the store of a measure)

The defaults live here and nowhere else. The layout is documented key by key in load/rounds/example.toml. As a module:
load_config(path) -> dict, resolve(raw) -> dict, plan(config, measure, scenario) -> dict, judging_of(config, measure, load) -> dict,
config_hash(config) -> str, case_hash(config, scenario, measure) -> str, case_list(config) -> [(scenario, measure)], plan_values,
env_lines, dump_toml; ConfigError.problems lists every problem found.
"""
import argparse
import copy
import difflib
import hashlib
import json
import math
import os
import re
import shlex
import sys
import time
import tomllib

SCENARIOS = ("A", "B")
MEASURES = ("http-native", "http-wasm", "http-wasm-jobs", "ws", "cells", "swap", "scale")
RAMP_MEASURES = ("http-native", "http-wasm", "http-wasm-jobs", "ws", "cells")
SCALE_LOADS = ("http-native", "http-wasm", "http-wasm-jobs", "cells")
RAMPS = {"http-native": (25, 20000), "http-wasm": (25, 20000), "http-wasm-jobs": (25, 20000), "ws": (100, 60000), "cells": (100, 100000)}
UNITS = {"http-native": "req/s", "http-wasm": "req/s", "http-wasm-jobs": "req/s", "ws": "connections", "cells": "cells", "swap": "req/s", "scale": "req/s or cells"}
FACTORS = [0.75, 1.0, 1.25, 1.5]  # the steps of a ceiling plan, as fractions of its ceiling
SIZE = re.compile(r"^[0-9]+[kmg]?b?$", re.IGNORECASE)  # as size_bytes of scripts/load-common
CEILING_KEY = re.compile(r"^([a-z-]+):([0-9]+)$")
BACKINGS = ("nocow", "tmpfs", "disk")
ABSOLUTE_PATH = re.compile(r"^(?:|/.+)$")  # store.nocow_dir: empty (the default directory) or absolute
ERL_FLAGS = re.compile(r"^(?:|(?:\+[A-Za-z]+|[A-Za-z0-9:_.]+)(?: (?:\+[A-Za-z]+|[A-Za-z0-9:_.]+))*)$")  # `+SDio 2 +S 1:1`; it ends up in an env var


class ConfigError(Exception):
    """An invalid config; `problems` is the list of every problem found, as "path: message"."""

    def __init__(self, problems, source=None):
        self.problems, self.source = list(problems), source
        super().__init__(f"invalid load config{f' {source}' if source else ''}:\n" + "\n".join(f"  - {p}" for p in self.problems))


# ---- the schema ----------------------------------------------------------------------------------------

class Leaf:
    """One value: `kind` int, float, bool, str, size or list; `lo`/`hi` bound a number (`open_lo`: lo itself is out); `choices`
    restrict a str or the items of a list; `item` is the kind of the items of a list."""

    def __init__(self, kind, default, lo=None, hi=None, open_lo=False, choices=None, item=None, nonempty=False, ascending=False, pattern=None, expected=None):
        self.kind, self.default, self.lo, self.hi, self.open_lo = kind, default, lo, hi, open_lo
        self.choices, self.item, self.nonempty, self.ascending, self.pattern = choices, item, nonempty, ascending, pattern
        self.expected = expected  # what a `pattern` accepts, for the problem text

    def range_text(self):
        parts = []
        if self.lo is not None:
            parts.append(f"{'>' if self.open_lo else '>='} {self.lo:g}")
        if self.hi is not None:
            parts.append(f"<= {self.hi:g}")
        return " and ".join(parts)

    def number(self, path, value, kind, problems):
        wrong = isinstance(value, bool) or not isinstance(value, (int, float) if kind == "float" else int)
        if wrong or (isinstance(value, float) and not math.isfinite(value)):
            problems.append(f"{path}: expected {'a number' if kind == 'float' else 'a whole number'}, got {describe(value)}")
            return None
        low = self.lo is not None and (value <= self.lo if self.open_lo else value < self.lo)
        if low or (self.hi is not None and value > self.hi):
            problems.append(f"{path}: {value:g} is out of range, expected {self.range_text()}")
            return None
        return float(value) if kind == "float" else value

    def check(self, path, value, problems):
        """The normalised value (a float leaf holds floats, so 1 and 1.0 are one value), or None after recording a problem."""
        if self.kind in ("int", "float"):
            return self.number(path, value, self.kind, problems)
        if self.kind == "bool":
            if not isinstance(value, bool):
                problems.append(f"{path}: expected true or false, got {describe(value)}")
                return None
            return value
        if self.kind in ("str", "size"):
            if not isinstance(value, str):
                problems.append(f"{path}: expected a string, got {describe(value)}")
                return None
            if self.kind == "size" and not (SIZE.match(value) and int(re.sub(r"\D", "", value)) > 0):
                problems.append(f"{path}: {value!r} is not a size, use a whole number with k, m or g (512m, 2g)")
                return None
            if self.choices and value not in self.choices:
                problems.append(f"{path}: {value!r} is not one of {', '.join(self.choices)}")
                return None
            if self.pattern and not self.pattern.match(value):
                problems.append(f"{path}: {value!r} is not {self.expected}")
                return None
            return value
        return self.check_list(path, value, problems)

    def check_list(self, path, value, problems):
        if not isinstance(value, list):
            problems.append(f"{path}: expected a list, got {describe(value)}")
            return None
        if self.nonempty and not value:
            problems.append(f"{path}: must not be empty")
            return None
        item = Leaf(self.item, None, self.lo, self.hi, self.open_lo, self.choices)
        found = [item.check(f"{path}[{i}]", v, problems) for i, v in enumerate(value)]
        if any(v is None for v in found):
            return None
        if self.ascending and any(b <= a for a, b in zip(found, found[1:])):
            problems.append(f"{path}: the values must grow, each above the one before")
            return None
        if self.choices and len(set(found)) != len(found):
            problems.append(f"{path}: lists a value twice")
            return None
        return found


class Table:
    """A table of known keys. `sparse`: only the keys that are given are kept (an override of another table)."""

    def __init__(self, children, sparse=False):
        self.children, self.sparse = children, sparse


class Map:
    """A table of `keys` (a name each), each holding `child(key)`; `fill`: every key is present, with its defaults."""

    def __init__(self, keys, child, label, fill=False):
        self.keys, self.child, self.label, self.fill = keys, child, label, fill


def describe(value):
    return {bool: "a boolean", int: "a whole number", float: "a number", str: "a string", list: "a list", dict: "a table"}.get(type(value), type(value).__name__)


def steps_table(start, maximum, sparse=False):
    """The step plan of a measure: a `ladder` of fixed values, a `ceiling` ladder of `factors` times `ceiling`, or a `bisect` that grows
    from `start` by `factor` up to `max`, then refines."""
    return Table({
        "kind": Leaf("str", "bisect", choices=("ladder", "bisect", "ceiling")),
        "values": Leaf("list", [], item="int", lo=0, open_lo=True, ascending=True),
        "ceiling": Leaf("int", 0, lo=0),
        "factors": Leaf("list", list(FACTORS), item="float", lo=0, open_lo=True, nonempty=True),
        "start": Leaf("float", float(start), lo=0, open_lo=True),
        "factor": Leaf("float", 2.0, lo=1, open_lo=True),
        "max": Leaf("float", float(maximum), lo=0, open_lo=True),
        "duration_s": Leaf("float", 180.0, lo=0, open_lo=True),
        "refine": Leaf("int", 3, lo=0),
        "confirm": Leaf("bool", True),
        "reset_each_step": Leaf("bool", False),
    }, sparse)


def store_override():
    """The keys of [store] a measure may override for its own runs."""
    return Table({"backing": Leaf("str", "nocow", choices=BACKINGS), "tmpfs_size": Leaf("size", "1g"), "latency_ms": Leaf("float", 25.0, lo=0)},
                 sparse=True)


def measure_table(name):
    run_on = Leaf("list", [], item="str", choices=SCENARIOS)
    common = {"run_on": run_on, "store": store_override(), "judging": Table(judging_children(sparse=True), sparse=True),
              "variant": Map((), lambda _: None, "variant")}  # reserved: [measures.M.variant.V.store] and .steps; no measure has variants yet
    if name in ("swap", "scale"):
        return Table(common)
    start, maximum = RAMPS[name]
    return Table({**common, "steps": steps_table(start, maximum),
                  "per_scenario": Map(SCENARIOS, lambda _: steps_table(start, maximum, sparse=True), "scenario")})


def scenario_table(cpus, memory, tmpfs):
    return Table({"cpus": Leaf("float", float(cpus), lo=0, open_lo=True), "memory": Leaf("size", memory), "data_tmpfs": Leaf("size", tmpfs),
                  "nodes": Leaf("int", 1, lo=1, hi=10)})


def pct(default):
    return Leaf("float", float(default), lo=0, hi=100, open_lo=True)


def positive(default):
    return Leaf("float", float(default), lo=0, open_lo=True)


def share(default):
    return Leaf("float", float(default), lo=0, hi=1, open_lo=True)


def criterion(sparse=False, **limits):
    """A criterion: `enabled` and its limits."""
    return Table({"enabled": Leaf("bool", True), **limits}, sparse)


def judging_children(sparse=False):
    """The rules of [judging]; sparse: the same keys as an override for one measure (only what is given is kept)."""
    return {
        "stall_repeats": Leaf("int", 1, lo=0),
        "errors": criterion(sparse),
        "p99": criterion(sparse, max_ms=positive(250)),
        "refused": criterion(sparse, max_pct=pct(1)),
        "memory": criterion(sparse, max_pct=pct(90)),
        "fds": criterion(sparse, max_pct=pct(90)),
        "delivery": criterion(sparse, min_ratio=share(0.95)),
        "store_fill": criterion(sparse, max_tmpfs_pct=pct(90), max_disk_pct=pct(90)),
        "store_stall": criterion(sparse, min_ms=positive(1000), min_requests=Leaf("int", 10, lo=1), window_s=positive(5), fail_on_repeat=Leaf("bool", True)),
        "generator_lag": criterion(sparse, max_ms=positive(50)),
        "throttle": criterion(sparse, max_jump_ms=positive(5000), jump_factor=positive(5)),
        "host_load": criterion(sparse, max=positive(1), quiet_window_s=positive(60), quiet_max_wait_s=positive(1800)),
        "host_busy": criterion(sparse, max_share=share(0.85)),
        "generator_swap": criterion(sparse, max_mb=positive(16)),
        "host_swap": criterion(sparse, max_growth_mb=positive(256)),
        "host_memory": criterion(sparse, min_available_gib=positive(6)),
    }


SCHEMA = Table({
    "round": Table({
        "scenarios": Leaf("list", ["A"], item="str", choices=SCENARIOS, nonempty=True),
        "measures": Leaf("list", ["http-native", "http-wasm", "http-wasm-jobs", "ws", "cells", "swap"], item="str", choices=MEASURES, nonempty=True),
        "cases": Leaf("list", [], item="str"),
        "step_timeout_s": positive(600),
        "timeout_s": Leaf("float", 0.0, lo=0),
    }),
    "output": Table({"dir": Leaf("str", ""), "name": Leaf("str", "")}),
    "host": Table({"ssh": Leaf("str", ""), "repo": Leaf("str", ""), "results": Leaf("str", ""), "timeout_s": positive(172800)}),
    "scenarios": Map(SCENARIOS, lambda key: scenario_table(1, "512m", "256m") if key == "A" else scenario_table(2, "2g", "1g"), "scenario", fill=True),
    "store": Table({"backing": Leaf("str", "nocow", choices=BACKINGS), "nocow_dir": Leaf("str", "", pattern=ABSOLUTE_PATH, expected="an absolute path (or empty, for the default directory)"), "tmpfs_size": Leaf("size", "1g"),
                    "memory": Leaf("size", "2g"), "cpus": positive(2), "latency_ms": Leaf("float", 25.0, lo=0)}),
    "balancer": Table({"cpus": positive(2), "memory": Leaf("size", "512m")}),
    "node": Table({"http_max_connections": Leaf("int", 0, lo=0), "erl_flags": Leaf("str", "", pattern=ERL_FLAGS,
                                                       expected="a list of Erlang flags, use words, numbers and `+flag` separated by single spaces (+SDio 2 +S 1:1)"),
                   "compaction": Table({"hold_bytes": Leaf("int", 0, lo=0), "concurrency": Leaf("int", 0, lo=0), "urgent_concurrency": Leaf("int", 0, lo=0),
                                         "merge_concurrency": Leaf("int", 0, lo=0), "release_concurrency": Leaf("int", 0, lo=0)}),
                   "store": Table({"pool_size": Leaf("int", 0, lo=0), "pool_timeout_ms": Leaf("int", 0, lo=0)})}),
    "measures": Map(MEASURES, measure_table, "measure", fill=True),
    "judging": Table(judging_children()),
    "generator": Table({"rate_per_proc": positive(600), "conns_per_rate": positive(0.5), "timeout_s": positive(10), "grace_s": Leaf("float", 30.0, lo=0),
                        "sample_s": positive(5)}),
    "workload": Table({"write_ratio": Leaf("float", 0.5, lo=0, hi=1), "cells": Leaf("int", 64, lo=1), "warmup": Leaf("bool", True),
                       "cell_period_s": positive(10), "cells_conns": Leaf("int", 64, lo=1), "open_rate": positive(100), "ws_interval_s": positive(30),
                       "worker": Leaf("str", "native", choices=("native", "wasm"))}),
    "swap": Table({"rate": Leaf("float", 0.0, lo=0), "trigger": Leaf("str", "sigterm", choices=("sigterm", "api")), "workers": Leaf("int", 12, lo=1),
                   "warmup_s": Leaf("float", 25.0, lo=0), "overlap_s": Leaf("float", 5.0, lo=0), "settle_s": Leaf("float", 30.0, lo=0),
                   "timeout_s": positive(900)}),
    "scale": Table({
        "max_nodes": Leaf("int", 3, lo=1, hi=10),
        "loads": Leaf("list", ["http-native", "cells"], item="str", choices=SCALE_LOADS, nonempty=True),
        "factor": Leaf("float", 1.25, lo=1, open_lo=True),
        "ceilings": Map(None, lambda _: Leaf("int", None, lo=0, open_lo=True), "ceiling"),
        "ceiling_factors": Leaf("list", list(FACTORS), item="float", lo=0, open_lo=True, nonempty=True),
        "per_scenario": Map(SCENARIOS, lambda _: Table({"ceilings": Map(None, lambda _: Leaf("int", None, lo=0, open_lo=True), "ceiling"),
                                                        "ceiling_factors": Leaf("list", list(FACTORS), item="float", lo=0, open_lo=True, nonempty=True)},
                                                       sparse=True), "scenario"),
        "join": criterion(rate=Leaf("float", 0.0, lo=0), factor=positive(1.5), warmup_s=Leaf("float", 30.0, lo=0), observe_s=positive(120),
                          node_wait_s=positive(90), node_timeout_s=positive(300), sample_s=positive(2)),
        "spread": Table({"tol_pct": pct(25), "hold": Leaf("int", 3, lo=1), "min_cells": Leaf("int", 10, lo=1)}),
        "judging": Map(SCALE_LOADS, lambda _: Table(judging_children(sparse=True), sparse=True), "load"),
    }),
})


# ---- reading and merging ---------------------------------------------------------------------------------

def default_of(node):
    if isinstance(node, Leaf):
        return copy.deepcopy(node.default)
    if isinstance(node, Table):
        return {} if node.sparse else {k: default_of(c) for k, c in node.children.items()}
    return {k: default_of(node.child(k)) for k in node.keys} if node.fill else {}


def unknown(path, key, known):
    close = difflib.get_close_matches(key, list(known), n=1)
    return f"{path}: unknown key" + (f" (did you mean {close[0]!r}?)" if close else f", expected one of {', '.join(known)}")


def merge(node, value, path, problems):
    """`value` (from the file) checked against `node` and merged over its defaults; an invalid value is reported and the default stays."""
    if isinstance(node, Leaf):
        checked = node.check(path, value, problems)
        return node.default if checked is None else checked
    if not isinstance(value, dict):
        problems.append(f"{path}: expected a table, got {describe(value)}")
        return default_of(node)
    out = default_of(node)
    if isinstance(node, Table):
        for key, given in value.items():
            if key not in node.children:
                problems.append(unknown(f"{path}.{key}" if path else key, key, node.children))
                continue
            before = len(problems)
            merged = merge(node.children[key], given, f"{path}.{key}" if path else key, problems)
            if not (node.sparse and len(problems) > before):  # a sparse table keeps only what is given and valid
                out[key] = merged
        return out
    for key, given in value.items():
        if node.keys is not None and key not in node.keys:
            expected = f"expected one of {', '.join(node.keys)}" if node.keys else f"there is no {node.label} yet"
            problems.append(f"{path}.{key}: unknown {node.label} {key!r}, {expected}")
        elif node.keys is None and not CEILING_KEY.match(key):
            problems.append(f"{path}.{key}: expected LOAD:NODES, like http-native:2")
        else:
            out[key] = merge(node.child(key), given, f"{path}.{key}", problems)
    return {k: v for k, v in out.items() if v is not None}


def plan(config, measure, scenario):
    """The step plan of a ramp measure in a scenario: its `steps` with the overrides of `per_scenario`."""
    entry = config["measures"][measure]
    return {**entry["steps"], **entry["per_scenario"].get(scenario, {})}


def hashed_plan(config, measure, scenario):
    """`plan` as hashed: `reset_each_step` is left out while false, so a round that does not set it keeps its hash."""
    return {k: v for k, v in plan(config, measure, scenario).items() if k != "reset_each_step" or v}


def steps_of(ceiling, factors):
    """The values of a ladder as fractions of a ceiling: rounded, at least 1, repeats dropped."""
    out = []
    for factor in factors:
        value = max(1, int(ceiling * factor + 0.5))
        if not out or out[-1] != value:
            out.append(value)
    return out


def ramp_values(p):
    """The values of a bisect plan before any refinement: `start` growing by `factor` up to `max`."""
    values, v = [], p["start"]
    while v <= p["max"]:
        values.append(round(v))
        v *= p["factor"]
    return values


def plan_values(p):
    """The values a plan runs before any refinement: the ladder's, the ceiling's fractions, or the bisect's growth."""
    if p["kind"] == "ladder":
        return list(p["values"])
    return steps_of(p["ceiling"], p["factors"]) if p["kind"] == "ceiling" else ramp_values(p)


def case_list(config):
    """[(scenario, measure)] of the round, in the order they run: `round.cases` as given, else each scenario with its measures
    (a measure with `run_on` only on those scenarios). A malformed case is left out (check_cases reports it)."""
    cases = config["round"]["cases"]
    if not cases:
        entries = config["measures"]
        return [(s, m) for s in config["round"]["scenarios"] for m in config["round"]["measures"] if not entries[m]["run_on"] or s in entries[m]["run_on"]]
    parts = [c.split("/") for c in cases]
    return [(p[0], p[1]) for p in parts if len(p) in (2, 3) and p[0] in SCENARIOS and p[1] in MEASURES]


def scale_of(config, scenario):
    """The [scale] section as it holds in a scenario: the ceilings and their factors of `per_scenario` replace the general ones."""
    scale = {k: v for k, v in config["scale"].items() if k != "per_scenario"}
    return {**scale, **config["scale"]["per_scenario"].get(scenario, {})}


def join_budget_s(config):
    """Seconds the load generator of the scale measure's join runs (0 without a join), as load-run budgets it."""
    scale = config["scale"]
    join = scale["join"]
    return 0.0 if not join["enabled"] or scale["max_nodes"] < 2 else join["warmup_s"] + (scale["max_nodes"] - 1) * (join["observe_s"] + join["node_wait_s"]) + join["observe_s"]


def generator_budget_s(config, scenario, measure):
    """(seconds the longest generator process of a case runs, what it is), plus the grace the generator may take; None for the swap."""
    grace = config["generator"]["grace_s"]
    if measure in RAMP_MEASURES:
        return plan(config, measure, scenario)["duration_s"] + grace, f"measures.{measure} duration_s + generator.grace_s"
    if measure == "scale":
        loads = [(plan(config, load, scenario)["duration_s"], load) for load in config["scale"]["loads"]]
        need, what = max([(d, f"measures.{load} duration_s") for d, load in loads] + [(join_budget_s(config), "the join of scale.join")])
        return need + grace, f"{what} + generator.grace_s"
    return None


def check_plans(config, problems):
    cases = config["round"]["cases"]
    pairs = case_list(config)
    selected = list(dict.fromkeys(s for s, _ in pairs)) if cases else config["round"]["scenarios"]
    names = "round.cases" if cases else "round.scenarios"
    cap, timeout = config["node"]["http_max_connections"], config["round"]["step_timeout_s"]
    for measure in dict.fromkeys(m for _, m in pairs) if cases else config["round"]["measures"]:
        entry = config["measures"][measure]
        base = f"measures.{measure}"
        for scenario in [] if cases else entry["run_on"]:
            if scenario not in selected:
                problems.append(f"{base}.run_on: scenario {scenario} is not in {names}")
        if measure in RAMP_MEASURES:
            for scenario in entry["per_scenario"]:
                if scenario not in selected:
                    problems.append(f"{base}.per_scenario.{scenario}: scenario {scenario} is not in {names}")
        for scenario in [s for s, m in pairs if m == measure]:
            need = generator_budget_s(config, scenario, measure)
            if need and timeout < need[0]:
                problems.append(f"round.step_timeout_s: {timeout:g} s is below {need[0]:g} s ({need[1]}) of {scenario}/{measure}")
            if measure not in RAMP_MEASURES:
                continue
            p = plan(config, measure, scenario)
            where = f"{base}.per_scenario.{scenario}" if scenario in entry["per_scenario"] else f"{base}.steps"
            if p["kind"] == "ladder" and not p["values"]:
                problems.append(f"{where}.values: a ladder needs values")
            if p["kind"] != "ladder" and p["values"]:
                problems.append(f"{where}.values: only a ladder uses values; set kind = \"ladder\" or remove them")
            if p["kind"] == "ceiling" and not p["ceiling"]:
                problems.append(f"{where}.ceiling: a ceiling plan needs the ceiling")
            if p["kind"] == "bisect" and p["start"] > p["max"]:
                problems.append(f"{where}: start {p['start']:g} is above max {p['max']:g}")
            highest = max(plan_values(p), default=0) if measure == "ws" and cap else 0
            if highest >= cap > 0:
                problems.append(f"{where}: the highest step, {highest} connections, is not below node.http_max_connections {cap}")


def check_cases(config, problems):
    cases = config["round"]["cases"]
    for i, text in enumerate(cases):
        parts, where = text.split("/"), f"round.cases[{i}]"
        if len(parts) not in (2, 3) or not all(parts):
            problems.append(f"{where}: expected SCENARIO/MEASURE, like A/http-native")
            continue
        if parts[0] not in SCENARIOS:
            problems.append(f"{where}: unknown scenario {parts[0]!r}, expected one of {', '.join(SCENARIOS)}")
        if parts[1] not in MEASURES:
            problems.append(f"{where}: unknown measure {parts[1]!r}, expected one of {', '.join(MEASURES)}")
        elif len(parts) == 3:
            problems.append(f"{where}: unknown variant {parts[2]!r}, {parts[1]} has no variants")
        if cases.index(text) != i:
            problems.append(f"{where}: {text!r} is listed twice")
    if cases:
        problems += [f"round.cases: cannot be used with measures.{m}.run_on; remove one of them" for m in MEASURES if config["measures"][m]["run_on"]]


def check_rest(config, problems):
    scale = config["scale"]
    groups = [("scale.ceilings", scale["ceilings"])] + [(f"scale.per_scenario.{s}.ceilings", o["ceilings"]) for s, o in scale["per_scenario"].items() if "ceilings" in o]
    for where, ceilings in groups:
        for key in ceilings:
            load, nodes = CEILING_KEY.match(key).groups()
            if load not in scale["loads"]:
                problems.append(f"{where}.{key}: {load} is not in scale.loads")
            if not 1 <= int(nodes) <= scale["max_nodes"]:
                problems.append(f"{where}.{key}: nodes must be 1 to scale.max_nodes ({scale['max_nodes']})")
    host = config["host"]
    if host["ssh"] and not host["repo"]:
        problems.append("host.repo: required when host.ssh is set")
    if not re.fullmatch(r"[A-Za-z0-9._-]*", config["output"]["name"]):
        problems.append("output.name: use letters, digits, dot, dash and underscore only")


def resolve(raw):
    """The config of `raw` (a dict as read from TOML) merged over the defaults; ConfigError lists every problem."""
    problems = []
    config = merge(SCHEMA, raw, "", problems)
    check_cases(config, problems)
    check_plans(config, problems)
    check_rest(config, problems)
    if problems:
        raise ConfigError(problems)
    return config


def load_config(path=None):
    """The resolved config of the TOML file at `path` (the defaults when None)."""
    if path is None:
        return resolve({})
    try:
        with open(path, "rb") as file:
            raw = tomllib.load(file)
    except OSError as error:
        raise ConfigError([f"cannot read the file: {error.strerror}"], path) from error
    except tomllib.TOMLDecodeError as error:
        raise ConfigError([f"not valid TOML: {error}"], path) from error
    try:
        return resolve(raw)
    except ConfigError as error:
        raise ConfigError(error.problems, path) from None


def config_hash(config):
    """A stable hash of a resolved config: the same settings give the same hash, whatever the order or spelling in the file."""
    return hashlib.sha256(json.dumps(config, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def store_of(config, measure=None):
    """The [store] section for a measure: `measures.<measure>.store` overrides the general one."""
    return {**config["store"], **(config["measures"][measure]["store"] if measure else {})}


def judging_of(config, measure=None, load=None):
    """The [judging] rules for a measure: `measures.<measure>.judging` overrides the keys it gives, rule by rule; for a load of the scale,
    `scale.judging.<load>` overrides those in turn (scale load > measure > round)."""
    layers = [config["measures"][measure]["judging"]] if measure else []
    if measure == "scale" and load:
        layers.append(config["scale"]["judging"].get(load, {}))
    rules = config["judging"]
    for given in layers:
        rules = {name: {**rule, **given[name]} if isinstance(rule, dict) and name in given else given.get(name, rule) for name, rule in rules.items()}
    return rules


def node_of(config):
    """[node] as hashed: `erl_flags` and the keys left at 0 (the node's default) in `compaction` and `store` are left out while unset, so a round that does not set them keeps its hash."""
    node = config["node"]
    return {"http_max_connections": node["http_max_connections"], **({"erl_flags": node["erl_flags"]} if node["erl_flags"] else {}),
            **{name: given for name in ("compaction", "store") if (given := {k: v for k, v in node[name].items() if v})}}


def case_config(config, scenario, measure):
    """What affects the results of a case, and nothing else: the scenario, the store (with the measure's override), the balancer, the node,
    the judging (with the measure's overrides), the generator, the workload, the measure's plan and, for the swap and the scale, their
    sections. Not `output`, `host` or `round` (the other measures' plans and the timeouts do not change what a step measures)."""
    case = {"scenario": scenario, "scenario_settings": config["scenarios"][scenario], "store": {k: v for k, v in store_of(config, measure).items() if k != "nocow_dir"}, "balancer": config["balancer"],
            "node": node_of(config), "judging": judging_of(config, measure), "generator": config["generator"], "workload": config["workload"], "measure": measure}
    if measure in RAMP_MEASURES:
        case["plan"] = hashed_plan(config, measure, scenario)
    elif measure == "swap":
        case["swap"] = config["swap"]
    else:
        case["scale"] = scale_of(config, scenario)
        case["scale"].pop("judging")  # enters as the merged rules of the loads that have an override
        case["load_judging"] = {load: judging_of(config, measure, load) for load in config["scale"]["loads"] if load in config["scale"]["judging"]}
        case["plans"] = {load: hashed_plan(config, load, scenario) for load in config["scale"]["loads"]}
    return case


def case_hash(config, scenario, measure):
    """The `config_hash` of the step files of a case: the hash of `case_config`."""
    return config_hash(case_config(config, scenario, measure))


def nocow_dir(store):
    """The directory of a nocow store: `nocow_dir`, else ${XDG_CACHE_HOME:-$HOME/.cache}/atanor-load/store. Machine-specific, so not hashed."""
    cache = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return store["nocow_dir"] or os.path.join(cache, "atanor-load", "store")


def env_lines(config, scenario, measure=None):
    """{ATANOR_LOAD_NAME: value} of the lab of a scenario, with the store of a measure. The scale measure sets its own number of nodes."""
    scenario_settings, store, balancer = config["scenarios"][scenario], store_of(config, measure), config["balancer"]
    node = config["node"]
    cap = node["http_max_connections"]
    lines = {"CPUS": f"{scenario_settings['cpus']:g}", "MEMORY": scenario_settings["memory"], "TMPFS_SIZE": scenario_settings["data_tmpfs"],
             "STORE_DISK": "1" if store["backing"] == "disk" else "0", "STORE_NOCOW_DIR": nocow_dir(store) if store["backing"] == "nocow" else "",
             "STORE_TMPFS_SIZE": store["tmpfs_size"], "STORE_MEMORY": store["memory"],
             "STORE_CPUS": f"{store['cpus']:g}", "STORE_LATENCY_MS": f"{store['latency_ms']:g}", "LB_CPUS": f"{balancer['cpus']:g}", "LB_MEMORY": balancer["memory"],
             "HTTP_MAX_CONNECTIONS": str(cap) if cap else "", "ERL_FLAGS": node["erl_flags"]}
    for table, prefix in (("compaction", "COMPACTION"), ("store", "S3")):
        for key, value in node[table].items():
            lines[f"{prefix}_{key.upper()}"] = str(value) if value else ""
    if measure != "scale":
        lines["NODES"] = str(scenario_settings["nodes"])
    return {f"ATANOR_LOAD_{k}": v for k, v in lines.items()}


def output_dir(config, root):
    """The results directory: `output.dir`, else `load/results/<output.name or a time stamp>` under `root`; absolute."""
    given = config["output"]["dir"]
    return os.path.abspath(given or os.path.join(root, "load", "results", config["output"]["name"] or time.strftime("%Y%m%d-%H%M%S")))


def toml_key(key):
    return key if re.fullmatch(r"[A-Za-z0-9_-]+", key) else json.dumps(key)


def toml_value(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, list):
        return "[" + ", ".join(toml_value(v) for v in value) + "]"
    return json.dumps(value) if isinstance(value, str) else repr(value)


def dump_toml(config):
    """`config` (a resolved config) as TOML text that resolves back to the same config."""
    lines = []

    def table(path, values):
        scalars = {k: v for k, v in values.items() if not isinstance(v, dict)}
        if path and scalars:
            lines.extend(["[" + ".".join(toml_key(k) for k in path) + "]", *(f"{toml_key(k)} = {toml_value(v)}" for k, v in scalars.items()), ""])
        for key, child in values.items():
            if isinstance(child, dict):
                table([*path, key], child)

    table([], config)
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--check", metavar="FILE", help="validate FILE and print the resolved config and its hash")
    group.add_argument("--defaults", action="store_true", help="print the built-in defaults")
    group.add_argument("--env", metavar="FILE", help="print the ATANOR_LOAD_* lines of the lab of SCENARIO, with the store of MEASURE, for a shell to eval")
    parser.add_argument("target", nargs="*", help="--env: SCENARIO [MEASURE]")
    args = parser.parse_args()
    if args.env:
        if not 1 <= len(args.target) <= 2 or args.target[0] not in SCENARIOS or (len(args.target) == 2 and args.target[1] not in MEASURES):
            parser.error(f"--env takes a scenario ({', '.join(SCENARIOS)}) and optionally a measure ({', '.join(MEASURES)})")
        try:
            config = load_config(args.env)
        except ConfigError as error:
            print(error, file=sys.stderr)
            sys.exit(1)
        for name, value in env_lines(config, *args.target).items():
            print(f"{name}={shlex.quote(value)}")
        return
    try:
        config = load_config(args.check)
    except ConfigError as error:
        print(error, file=sys.stderr)
        sys.exit(1)
    print(json.dumps(config, indent=1, sort_keys=True))
    print(f"hash {config_hash(config)}", file=sys.stderr)


if __name__ == "__main__":
    main()
