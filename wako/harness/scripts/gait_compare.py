#!/usr/bin/env python3
"""Compare gait acceptance metrics (METRIC and ACTING lines from gait_metrics.gd).

Usage:
  gait_compare.py LOG_A LOG_B [LOG_C ...] [--phases p1,p2] [--keys k1,k2] [--names a,b,c]

Each LOG is the stdout of a gait_lab run (or the grep'd .txt). Prints one
markdown table per metric key: a row per phase, a column per log, so a
baseline / previous / current comparison reads at a glance. Without --keys a
default acceptance set is printed. Values keep their units as printed.
"""
import sys

DEFAULT_KEYS = [
    "slip_max", "skate_max", "knee_fwd", "knee_step_stance", "shown_knee_step",
    "late_behind", "land_rel", "steps_per_s", "duty", "flight", "start_latency",
    "neutral_dev", "bob_p2p", "pitch_p2p", "roll_p2p", "twist_p2p",
    "knee_flex_mid/toeoff", "leg_gap_min", "toe_pen", "root_step", "root_turn",
    "perf_us", "plan_us",
]


def load(path):
    out = {}
    for line in open(path, encoding="utf-8", errors="replace"):
        if not (line.startswith("METRIC ") or line.startswith("ACTING ")):
            continue
        parts = line.split()
        name = parts[1]
        values = out.setdefault(name, {})
        for p in parts[2:]:
            if "=" in p:
                k, v = p.split("=", 1)
                values[k] = v
    return out


def main(argv):
    logs, phases, keys, names = [], None, DEFAULT_KEYS, None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--phases": phases = argv[i + 1].split(","); i += 2; continue
        if a == "--keys": keys = argv[i + 1].split(","); i += 2; continue
        if a == "--names": names = argv[i + 1].split(","); i += 2; continue
        logs.append(a); i += 1
    if len(logs) < 1:
        print(__doc__)
        return 1
    data = [load(p) for p in logs]
    names = names or [p.rsplit("/", 1)[-1] for p in logs]
    if phases is None:
        phases = [p for p in data[-1] if all(p in d for d in data)]
    for key in keys:
        rows = [(p, [d.get(p, {}).get(key, "-") for d in data]) for p in phases]
        rows = [r for r in rows if any(v != "-" for v in r[1])]
        if not rows: continue
        print(f"\n#### {key}")
        print("| phase | " + " | ".join(names) + " |")
        print("|---|" + "---|" * len(names))
        for phase, vals in rows:
            print(f"| {phase} | " + " | ".join(vals) + " |")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
