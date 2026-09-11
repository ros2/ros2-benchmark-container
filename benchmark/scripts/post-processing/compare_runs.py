#!/usr/bin/env python3

# Copyright (c) 2026, iRobot ROS
# All rights reserved.
#
# This source code is licensed under the BSD 3-Clause License found in the
# LICENSE file in the root directory of this source tree.

"""
Compare a set of benchmark runs, with the run as the comparison axis.

Given several results directories already parsed by generate_all_metrics.sh, this
draws grouped-bar charts with the run as the series (latency, CPU, RSS), plus a
provenance diff of which ROS-stack rows differ across the runs. Series labels and
provenance come from each run's run_manifest.json (see capture_run_manifest.py).
It is agnostic about why the runs differ (executor, rclcpp source, before/after).

Usage:
    compare_runs.py <run_dir> [<run_dir> ...] [options]
    compare_runs.py --run <run_dir>:<label> [--run <run_dir>:<label> ...] [options]

Options:
    --output <dir>   Where to write charts + CSVs (default: ./run_comparison).
    --filter <str>   Only include test cases whose key contains <str>
                     (e.g. 'pub-sub_single_process' or 'zenoh').
    --metrics <list> Comma-separated subset of: latency,cpu,rss (default: all).
    --per-page <n>   Max test cases per chart figure (default: 12).

A run may be given as a bare directory (label taken from its manifest, or the
directory name if it has none) or as <dir>:<label> to override the label -- handy
for older runs made before manifests existed.
"""

import argparse
import os
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import pandas as pd  # noqa: E402

try:
    import json
except ImportError:  # pragma: no cover
    json = None

# Column name in average_metrics.csv -> (short key, axis label, chart title).
METRICS = {
    "latency": ("Latency_us", "Latency (us) (lower = better)", "Latency"),
    "cpu": ("CPU", "CPU usage (% of a core)", "CPU usage"),
    "rss": ("RSS_MB", "RSS (MB) (lower = better)", "Resident memory"),
}
METRIC_COLUMN = {"latency": "Latency_us", "cpu": "CPU", "rss": "RSS_MB"}


class Run:
    """One labeled benchmark run: its parsed metrics + manifest provenance."""

    def __init__(self, path, label_override=None):
        self.path = os.path.normpath(path)
        self.name = os.path.basename(self.path)
        self.manifest = self._load_manifest()
        self.notes = (self.manifest or {}).get("notes")
        self.ros_stack = (self.manifest or {}).get("ros_stack", {})
        self.label = (
            label_override
            or (self.manifest or {}).get("label")
            or self.name
        )
        self.metrics = self._load_metrics()

    def _load_manifest(self):
        path = os.path.join(self.path, "run_manifest.json")
        if json is None or not os.path.isfile(path):
            return None
        try:
            with open(path) as f:
                return json.load(f)
        except (OSError, ValueError):
            return None

    def _load_metrics(self):
        """Return {test_case_key: {metric_column: float}} for this run."""
        csv_path = os.path.join(self.path, "parsed_results", "average_metrics.csv")
        if not os.path.isfile(csv_path):
            print(
                "WARNING: {} has no parsed_results/average_metrics.csv; "
                "run generate_all_metrics.sh on it first.".format(self.path),
                file=sys.stderr,
            )
            return {}
        df = pd.read_csv(csv_path, sep=";")
        df["_key"] = df["Directory"].apply(self._test_case_key)
        out = {}
        for _, row in df.iterrows():
            values = {}
            for col in ("CPU", "RSS_MB", "VSZ_MB", "Latency_us"):
                if col in row:
                    values[col] = pd.to_numeric(row[col], errors="coerce")
            out[row["_key"]] = values
        return out

    def _test_case_key(self, directory):
        # Strip the run dir name and everything before it, leaving a path that
        # joins across runs regardless of nesting depth.
        parts = str(directory).split("/")
        if self.name in parts:
            idx = len(parts) - 1 - parts[::-1].index(self.name)
            return "/".join(parts[idx + 1:])
        return str(directory).lstrip("/")


def collect_runs(args):
    runs = []
    for path in args.run_dirs:
        runs.append(Run(path))
    for spec in args.run:
        if ":" in spec:
            path, label = spec.rsplit(":", 1)
        else:
            path, label = spec, None
        runs.append(Run(path, label_override=label))
    return runs


def build_frame(runs, metric_column, key_filter):
    """DataFrame indexed by test-case key, one column per run label."""
    keys = []
    for run in runs:
        for k in run.metrics:
            if key_filter and key_filter not in k:
                continue
            if k not in keys:
                keys.append(k)
    keys.sort()
    data = {}
    for run in runs:
        data[run.label] = [
            run.metrics.get(k, {}).get(metric_column, float("nan")) for k in keys
        ]
    return pd.DataFrame(data, index=keys)


def plot_metric(frame, title, ylabel, out_prefix, per_page):
    """Grouped-bar chart(s) of one metric, run as the series."""
    if frame.empty:
        return []
    written = []
    n_pages = (len(frame) + per_page - 1) // per_page
    for page in range(n_pages):
        chunk = frame.iloc[page * per_page:(page + 1) * per_page]
        fig, ax = plt.subplots(
            figsize=(max(8, len(chunk) * 1.1), 6), constrained_layout=True
        )
        chunk.plot(kind="bar", ax=ax, width=0.8)
        ax.set_ylabel(ylabel)
        page_note = "" if n_pages == 1 else " (page {}/{})".format(page + 1, n_pages)
        ax.set_title("{} by run{}".format(title, page_note))
        ax.set_xlabel("")
        ax.tick_params(axis="x", labelrotation=45)
        for label in ax.get_xticklabels():
            label.set_ha("right")
        ax.legend(title="Run", fontsize="small")
        ax.grid(axis="y", linestyle=":", alpha=0.5)
        suffix = "" if n_pages == 1 else "_p{}".format(page + 1)
        out = "{}{}.png".format(out_prefix, suffix)
        fig.savefig(out, dpi=120)
        plt.close(fig)
        written.append(out)
    return written


def stack_diff(runs):
    """Rows of the ROS stack that differ across runs.

    Returns (differing, packages) where differing is a list of dicts (one per
    package whose version/source/sha is not identical across all runs).
    """
    all_pkgs = []
    for run in runs:
        for pkg in run.ros_stack:
            if pkg not in all_pkgs:
                all_pkgs.append(pkg)
    differing = []
    for pkg in all_pkgs:
        cells = {}
        signatures = set()
        for run in runs:
            entry = run.ros_stack.get(pkg)
            if entry is None:
                cell = "-"
            else:
                git = entry.get("git") or {}
                sha = (git.get("sha") or "")[:8]
                dirty = "+dirty" if git.get("dirty") else ""
                ver = entry.get("version") or "?"
                src = entry.get("source") or "?"
                cell = "{} [{}{}{}]".format(
                    ver, src, ("@" + sha) if sha else "", dirty
                )
            cells[run.label] = cell
            signatures.add(cell)
        if len(signatures) > 1:
            differing.append({"package": pkg, "cells": cells})
    return differing, all_pkgs


def write_provenance(runs, out_dir):
    differing, _ = stack_diff(runs)
    lines = ["# Run provenance comparison", ""]
    lines.append("## Runs")
    for run in runs:
        lines.append("- {}".format(run.label))
        if run.notes:
            lines.append("    notes: {}".format(run.notes))
        lines.append("    dir:   {}".format(run.path))
        if run.manifest is None:
            lines.append("    (no run_manifest.json; provenance unavailable)")
    lines.append("")
    lines.append("## ROS stack rows that differ across runs")
    if not differing:
        lines.append("(none -- the recorded stack is identical across all runs)")
    else:
        for item in differing:
            lines.append("- {}".format(item["package"]))
            for run in runs:
                lines.append(
                    "    {:<40} {}".format(run.label, item["cells"][run.label])
                )
    text = "\n".join(lines) + "\n"

    out_txt = os.path.join(out_dir, "comparison_provenance.txt")
    with open(out_txt, "w") as f:
        f.write(text)
    if json is not None:
        out_json = os.path.join(out_dir, "comparison_provenance.json")
        with open(out_json, "w") as f:
            json.dump(
                {
                    "runs": [
                        {
                            "label": r.label,
                            "notes": r.notes,
                            "dir": r.path,
                            "ros_stack": r.ros_stack,
                        }
                        for r in runs
                    ],
                    "differing_packages": differing,
                },
                f,
                indent=2,
            )
    return text


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("run_dirs", nargs="*", help="Results directories to compare.")
    parser.add_argument(
        "--run",
        action="append",
        default=[],
        metavar="DIR:LABEL",
        help="A run directory with an explicit label override (repeatable).",
    )
    parser.add_argument("--output", default="run_comparison", help="Output directory.")
    parser.add_argument("--filter", default=None, help="Only test cases containing this.")
    parser.add_argument(
        "--metrics",
        default="latency,cpu,rss",
        help="Comma-separated subset of: latency,cpu,rss.",
    )
    parser.add_argument("--per-page", type=int, default=12, help="Test cases per figure.")
    args = parser.parse_args()

    if not args.run_dirs and not args.run:
        parser.error("provide at least one run directory (positional or --run DIR:LABEL)")

    runs = collect_runs(args)
    runs = [r for r in runs if r.metrics]
    if len(runs) < 1:
        print("Error: no runs with parsed metrics found.", file=sys.stderr)
        return 1
    if len(runs) < 2:
        print(
            "WARNING: only one run has parsed metrics; charts will have a single "
            "series.",
            file=sys.stderr,
        )

    os.makedirs(args.output, exist_ok=True)
    selected = [m.strip() for m in args.metrics.split(",") if m.strip()]

    # Wide comparison CSV: one row per test case, <metric>__<label> columns.
    wide = {}
    written = []
    for metric in selected:
        if metric not in METRIC_COLUMN:
            print("Skipping unknown metric '{}'".format(metric), file=sys.stderr)
            continue
        column = METRIC_COLUMN[metric]
        frame = build_frame(runs, column, args.filter)
        if frame.empty:
            print("No test cases for metric '{}' (after filter).".format(metric))
            continue
        for label in frame.columns:
            wide["{}__{}".format(metric, label)] = frame[label]
        _, ylabel, title = METRICS[metric]
        out_prefix = os.path.join(args.output, "compare_{}".format(metric))
        written.extend(plot_metric(frame, title, ylabel, out_prefix, args.per_page))

    if wide:
        wide_df = pd.DataFrame(wide)
        wide_df.index.name = "test_case"
        csv_path = os.path.join(args.output, "comparison_metrics.csv")
        wide_df.to_csv(csv_path)
        written.append(csv_path)

    provenance = write_provenance(runs, args.output)

    print("\n" + provenance)
    print("Comparing {} runs: {}".format(
        len(runs), ", ".join(r.label for r in runs)))
    print("Wrote {} artifact(s) to {}/".format(len(written) + 2, args.output))
    return 0


if __name__ == "__main__":
    sys.exit(main())
