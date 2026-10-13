#!/usr/bin/env python3
"""Summarise gait_lab runs of several versions (acceptance gates + key numbers).

Usage:
  gait_summary.py DIR TAG [TAG ...] [--phases scen:phase,...] [--keys k1,k2]

DIR holds one log per scenario and version, named <TAG>_<scenario>.log (the
stdout of `gait_lab.tscn -- scenario=<scenario> [probe=1]`). Prints

  * gate failures per version (GATE lines, the `idle` spawn-drop phase
    excluded, as every version fails it the same way), and the number of
    phases over each acceptance threshold;
  * a markdown table (one row per scenario:phase and metric, one column per
    version) for the requested phases and keys.

Values are taken verbatim from the METRIC/ACTING lines of gait_metrics.gd.
"""
import glob
import os
import re
import sys

THRESHOLDS = [
    # (label, key, test on the float value)
    ("late_behind > .10 m", "late_behind", lambda v: v > .10),
    ("stuck > 3 ticks", "stuck_max", lambda v: v > 3),
    ("both feet up at duty >= .5", "both_up_duty", lambda v: v > 0),
    ("pronk", "pronk", lambda v: v > 0),
    ("taps", "taps", lambda v: v > 0),
    ("skate > 6 mm", "skate_max", lambda v: v > 6.0),
    ("slip > 5 mm", "slip_max", lambda v: v > 5.0),
    ("stance knee step > 8 deg/tick", "knee_step_stance", lambda v: v > 8.0),
    ("landing knee > 25 deg/frame", "knee4_land", lambda v: v > 25.0),
    ("shown knee step > 12 deg/tick", "shown_knee_step", lambda v: v > 12.0),
    ("hip-foot torsion > 45 deg", "torsion_g/s", lambda v: v > 45.0),
    ("grounded sole > 2 cm up", "g_off", lambda v: v > 20.0),
]

NUM = re.compile(r"-?\d+(?:\.\d+)?")


def load(path):
    phases, order = {}, []
    for line in open(path, encoding="utf-8", errors="replace"):
        if not line.startswith(("METRIC ", "ACTING ", "GATE ")):
            continue
        parts = line.split()
        name = parts[1]
        if name not in phases:
            phases[name] = {}
            order.append(name)
        if line.startswith("GATE "):
            # arrive_act also prints informational "GATE <action> settle_ticks=" lines.
            if len(parts) > 2 and parts[2] in ("ok", "FAIL"):
                phases[name]["GATE"] = parts[2]
            continue
        for p in parts[2:]:
            if "=" in p:
                k, v = p.split("=", 1)
                phases[name][k] = v
    return phases, order


def number(value):
    m = NUM.search(value or "")
    return float(m.group(0)) if m else None


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1
    d, tags, wanted, keys = argv[0], [], None, ["late_behind", "stuck_max", "both_up_duty", "skate_max", "slip_max", "knee_step_stance", "knee4_land", "shown_knee_step", "torsion_g/s"]
    i = 1
    while i < len(argv):
        if argv[i] == "--phases":
            wanted = [tuple(x.split(":", 1)) for x in argv[i + 1].split(",")]
            i += 2
        elif argv[i] == "--keys":
            keys = argv[i + 1].split(",")
            i += 2
        else:
            tags.append(argv[i])
            i += 1
    data = {}
    for tag in tags:
        for path in sorted(glob.glob(os.path.join(d, tag + "_*.log"))):
            scen = os.path.basename(path)[len(tag) + 1:-4]
            data.setdefault(tag, {})[scen] = load(path)
    scens = sorted(set.intersection(*[set(data.get(t, {})) for t in tags])) if tags else []
    print("scenarios compared: %d" % len(scens))
    print("| check | " + " | ".join(tags) + " |")
    print("|---|" + "---|" * len(tags))
    row = []
    for tag in tags:
        fails = sum(1 for s in scens for ph, vals in data[tag][s][0].items() if ph != "idle" and vals.get("GATE") == "FAIL")
        row.append(str(fails))
    print("| gate failures (idle excluded) | " + " | ".join(row) + " |")
    for label, key, test in THRESHOLDS:
        row = []
        for tag in tags:
            n = 0
            for s in scens:
                for ph, vals in data[tag][s][0].items():
                    if ph == "idle":
                        continue
                    v = number(vals.get(key))
                    if v is not None and test(v):
                        n += 1
            row.append(str(n))
        print("| phases with %s | " % label + " | ".join(row) + " |")
    if wanted:
        print()
        print("| scenario | phase | metric | " + " | ".join(tags) + " |")
        print("|---|---|---|" + "---|" * len(tags))
        for scen, ph in wanted:
            for k in keys:
                vals = [data.get(t, {}).get(scen, ({}, []))[0].get(ph, {}).get(k, "-") for t in tags]
                if all(v == "-" for v in vals):
                    continue
                print("| %s | %s | %s | %s |" % (scen, ph, k, " | ".join(vals)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
