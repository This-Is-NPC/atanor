#!/usr/bin/env python3
"""The round config of the load tests: read a TOML file, merge it over the built-in defaults, validate it.

  load_config.py --check FILE     print the resolved config (JSON) and its hash; exit 1 and list every problem when it is invalid
  load_config.py --defaults       print the built-in defaults

The defaults equal today's defaults of scripts/load-run, load-explore and load-common. The layout is documented key by key in
load/rounds/example.toml. As a module: load_config(path) -> dict, resolve(raw) -> dict, plan(config, measure, scenario) -> dict,
config_hash(config) -> str; ConfigError.problems lists every problem found.
"""
import argparse
import copy
import difflib
import hashlib
import json
import math
import re
import sys
import tomllib

SCENARIOS = ("A", "B")
MEASURES = ("http-native", "http-wasm", "http-wasm-jobs", "ws", "cells", "swap", "scale")
RAMP_MEASURES = ("http-native", "http-wasm", "http-wasm-jobs", "ws", "cells")
SCALE_LOADS = ("http-native", "http-wasm", "http-wasm-jobs", "cells")
RAMPS = {"http-native": (25, 20000), "http-wasm": (25, 20000), "http-wasm-jobs": (25, 20000), "ws": (100, 60000), "cells": (100, 100000)}
SIZE = re.compile(r"^[0-9]+[kmg]?b?$", re.IGNORECASE)  # as size_bytes of scripts/load-common
CEILING_KEY = re.compile(r"^([a-z-]+):([0-9]+)$")


class ConfigError(Exception):
    """An invalid config; `problems` is the list of every problem found, as "path: message"."""

    def __init__(self, problems, source=None):
        self.problems, self.source = list(problems), source
        super().__init__(f"invalid load config{f' {source}' if source else ''}:\n" + "\n".join(f"  - {p}" for p in self.problems))


# ---- the schema ----------------------------------------------------------------------------------------

class Leaf:
    """One value: `kind` int, float, bool, str, size or list; `lo`/`hi` bound a number (`open_lo`: lo itself is out); `choices`
    restrict a str or the items of a list; `item` is the kind of the items of a list."""

    def __init__(self, kind, default, lo=None, hi=None, open_lo=False, choices=None, item=None, nonempty=False, ascending=False):
        self.kind, self.default, self.lo, self.hi, self.open_lo = kind, default, lo, hi, open_lo
        self.choices, self.item, self.nonempty, self.ascending = choices, item, nonempty, ascending

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
    """The step plan of a measure: a `ladder` of fixed values, or a `bisect` that grows from `start` by `factor` up to `max`, then refines."""
    return Table({
        "kind": Leaf("str", "bisect", choices=("ladder", "bisect")),
        "values": Leaf("list", [], item="int", lo=0, open_lo=True, ascending=True),
        "start": Leaf("float", float(start), lo=0, open_lo=True),
        "factor": Leaf("float", 2.0, lo=1, open_lo=True),
        "max": Leaf("float", float(maximum), lo=0, open_lo=True),
        "duration_s": Leaf("float", 180.0, lo=0, open_lo=True),
        "refine": Leaf("int", 3, lo=0),
        "confirm": Leaf("bool", True),
    }, sparse)


def measure_table(name):
    run_on = Leaf("list", [], item="str", choices=SCENARIOS)
    if name in ("swap", "scale"):
        return Table({"run_on": run_on})
    start, maximum = RAMPS[name]
    return Table({"run_on": run_on, "steps": steps_table(start, maximum),
                  "per_scenario": Map(SCENARIOS, lambda _: steps_table(start, maximum, sparse=True), "scenario")})


def scenario_table(cpus, memory, tmpfs):
    return Table({"cpus": Leaf("float", float(cpus), lo=0, open_lo=True), "memory": Leaf("size", memory), "node_tmpfs": Leaf("size", tmpfs),
                  "nodes": Leaf("int", 1, lo=1, hi=10)})


def pct(default):
    return Leaf("float", float(default), lo=0, hi=100, open_lo=True)


def positive(default):
    return Leaf("float", float(default), lo=0, open_lo=True)


def share(default):
    return Leaf("float", float(default), lo=0, hi=1, open_lo=True)


def criterion(**limits):
    """A criterion: `enabled` and its limits."""
    return Table({"enabled": Leaf("bool", True), **limits})


SCHEMA = Table({
    "round": Table({
        "scenarios": Leaf("list", ["A"], item="str", choices=SCENARIOS, nonempty=True),
        "measures": Leaf("list", ["http-native", "http-wasm", "http-wasm-jobs", "ws", "cells", "swap"], item="str", choices=MEASURES, nonempty=True),
    }),
    "output": Table({"dir": Leaf("str", ""), "name": Leaf("str", "")}),
    "host": Table({"ssh": Leaf("str", ""), "repo": Leaf("str", ""), "results": Leaf("str", "")}),
    "scenarios": Map(SCENARIOS, lambda key: scenario_table(1, "512m", "256m") if key == "A" else scenario_table(2, "2g", "1g"), "scenario", fill=True),
    "store": Table({"backing": Leaf("str", "tmpfs", choices=("tmpfs", "disk")), "tmpfs_size": Leaf("size", "1g"), "memory": Leaf("size", "2g"),
                    "cpus": positive(2), "latency_ms": Leaf("float", 25.0, lo=0)}),
    "balancer": Table({"cpus": positive(2), "memory": Leaf("size", "512m")}),
    "node": Table({"http_max_connections": Leaf("int", 0, lo=0)}),
    "measures": Map(MEASURES, measure_table, "measure", fill=True),
    "judging": Table({
        "stall_repeats": Leaf("int", 1, lo=0),
        "p99": criterion(max_ms=positive(250)),
        "refused": criterion(max_pct=pct(1)),
        "memory": criterion(max_pct=pct(90)),
        "fds": criterion(max_pct=pct(90)),
        "delivery": criterion(min_ratio=share(0.95)),
        "store_fill": criterion(max_tmpfs_pct=pct(90), max_disk_pct=pct(90)),
        "store_stall": criterion(min_ms=positive(1000), min_requests=Leaf("int", 10, lo=1), window_s=positive(5), fail_on_repeat=Leaf("bool", True)),
        "generator_lag": criterion(max_ms=positive(50)),
        "throttle": criterion(max_jump_ms=positive(5000), jump_factor=positive(5)),
        "host_load": criterion(max=positive(1), quiet_window_s=positive(60), quiet_max_wait_s=positive(1800)),
        "host_busy": criterion(max_share=share(0.85)),
        "generator_swap": criterion(max_mb=positive(16)),
        "host_swap": criterion(max_growth_mb=positive(256)),
        "host_memory": criterion(min_available_gb=positive(6)),
    }),
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
        "ceiling_factors": Leaf("list", [0.75, 1.0, 1.25, 1.5], item="float", lo=0, open_lo=True, nonempty=True),
        "join": criterion(rate=Leaf("float", 0.0, lo=0), factor=positive(1.5), warmup_s=Leaf("float", 30.0, lo=0), observe_s=positive(120),
                          node_wait_s=positive(90), node_timeout_s=positive(300), sample_s=positive(2)),
        "spread": Table({"tol_pct": pct(25), "hold": Leaf("int", 3, lo=1), "min_cells": Leaf("int", 10, lo=1)}),
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
            problems.append(f"{path}.{key}: unknown {node.label} {key!r}, expected one of {', '.join(node.keys)}")
        elif node.keys is None and not CEILING_KEY.match(key):
            problems.append(f"{path}.{key}: expected LOAD:NODES, like http-native:2")
        else:
            out[key] = merge(node.child(key), given, f"{path}.{key}", problems)
    return {k: v for k, v in out.items() if v is not None}


def plan(config, measure, scenario):
    """The step plan of a ramp measure in a scenario: its `steps` with the overrides of `per_scenario`."""
    entry = config["measures"][measure]
    return {**entry["steps"], **entry["per_scenario"].get(scenario, {})}


def check_plans(config, problems):
    selected = config["round"]["scenarios"]
    for measure in config["round"]["measures"]:
        entry = config["measures"][measure]
        base = f"measures.{measure}"
        for scenario in entry["run_on"]:
            if scenario not in selected:
                problems.append(f"{base}.run_on: scenario {scenario} is not in round.scenarios")
        if measure not in RAMP_MEASURES:
            continue
        for scenario in entry["per_scenario"]:
            if scenario not in selected:
                problems.append(f"{base}.per_scenario.{scenario}: scenario {scenario} is not in round.scenarios")
        for scenario in [s for s in selected if not entry["run_on"] or s in entry["run_on"]]:
            p = plan(config, measure, scenario)
            where = f"{base}.per_scenario.{scenario}" if scenario in entry["per_scenario"] else f"{base}.steps"
            if p["kind"] == "ladder" and not p["values"]:
                problems.append(f"{where}.values: a ladder needs values")
            if p["kind"] == "bisect":
                if p["values"]:
                    problems.append(f"{where}.values: only a ladder uses values; set kind = \"ladder\" or remove them")
                if p["start"] > p["max"]:
                    problems.append(f"{where}: start {p['start']:g} is above max {p['max']:g}")


def check_rest(config, problems):
    scale = config["scale"]
    for key in scale["ceilings"]:
        load, nodes = CEILING_KEY.match(key).groups()
        if load not in scale["loads"]:
            problems.append(f"scale.ceilings.{key}: {load} is not in scale.loads")
        if not 1 <= int(nodes) <= scale["max_nodes"]:
            problems.append(f"scale.ceilings.{key}: nodes must be 1 to scale.max_nodes ({scale['max_nodes']})")
    host = config["host"]
    if host["ssh"] and not host["repo"]:
        problems.append("host.repo: required when host.ssh is set")
    if not re.fullmatch(r"[A-Za-z0-9._-]*", config["output"]["name"]):
        problems.append("output.name: use letters, digits, dot, dash and underscore only")


def resolve(raw):
    """The config of `raw` (a dict as read from TOML) merged over the defaults; ConfigError lists every problem."""
    problems = []
    config = merge(SCHEMA, raw, "", problems)
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


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--check", metavar="FILE", help="validate FILE and print the resolved config and its hash")
    group.add_argument("--defaults", action="store_true", help="print the built-in defaults")
    args = parser.parse_args()
    try:
        config = load_config(args.check)
    except ConfigError as error:
        print(error, file=sys.stderr)
        sys.exit(1)
    print(json.dumps(config, indent=1, sort_keys=True))
    print(f"hash {config_hash(config)}", file=sys.stderr)


if __name__ == "__main__":
    main()
