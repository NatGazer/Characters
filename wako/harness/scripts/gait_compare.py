#!/usr/bin/env python3
"""Compare gait acceptance metrics (METRIC lines from gait_metrics.gd).

Usage: gait_compare.py BEFORE.log AFTER.log [phase ...]
Prints one markdown table row per phase with before -> after values for the
acceptance numbers (slip, contact skate, knee side/steps, cadence, duty, flight,
swing lag, landing vs hip, start latency, stop neatness, per-tick sole step,
pose/plan cost).
"""
import sys

KEYS = [
    ("slip_max", "slip max"),
    ("skate_max", "contact skate"),
    ("knee_fwd", "knee fwd"),
    ("knee_step_stance", "knee step (stance)"),
    ("knee_step", "knee step (all)"),
    ("plan_lag", "swing lag"),
    ("land_rel", "landing ahead of hip"),
    ("steps_per_s", "steps/s"),
    ("duty", "duty L/R"),
    ("flight", "flight"),
    ("start_latency", "first lift"),
    ("neutral_dev", "stop: feet from neutral"),
    ("sole_step", "max sole step/tick"),
    ("perf_us", "pose eval us med/mean/max"),
    ("plan_us", "gait plan us med/mean/max"),
]


def load(path):
    out = {}
    for line in open(path, encoding="utf-8", errors="replace"):
        if not line.startswith("METRIC"):
            continue
        parts = line.split()
        name = parts[1]
        values = {}
        for p in parts[2:]:
            if "=" in p:
                k, v = p.split("=", 1)
                values[k] = v.split("(")[0]
        out[name] = values
    return out


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    before, after = load(sys.argv[1]), load(sys.argv[2])
    phases = sys.argv[3:] or [p for p in after if p in before]
    for phase in phases:
        b, a = before.get(phase, {}), after.get(phase, {})
        print(f"\n### {phase}  (v {b.get('v', '?')} -> {a.get('v', '?')} m/s)")
        print("| metric | before | after |\n|---|---|---|")
        for key, label in KEYS:
            if key in b or key in a:
                print(f"| {label} | {b.get(key, '-')} | {a.get(key, '-')} |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
