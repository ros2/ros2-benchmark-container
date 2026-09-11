#!/usr/bin/env python3

# Copyright (c) 2026, iRobot ROS
# All rights reserved.
#
# This source code is licensed under the BSD 3-Clause License found in the
# LICENSE file in the root directory of this source tree.

"""
Write run_manifest.json into a results directory: the resolved ROS 2 stack
(version + source + git SHA per package), executor/thread/callback-group
settings, and a human label/notes for the run.

Resolves from the live sourced environment, so it must run in the shell that
runs the benchmark, after the ROS setup files are sourced.

Inputs come from the environment (all optional):
  ROS2_BENCHMARK_OUTPUT_DIR   results dir to write the manifest into (or argv[1])
  ROS2_BENCHMARK_RUN_LABEL    display label (series name in compare_runs.py).
                              Defaults to executor(+threads).
  ROS2_BENCHMARK_RUN_NOTES    freeform note on what this run changed.
  ROS_DISTRO / ROS_INSTALL_DIR, AMENT_PREFIX_PATH, RMW_IMPLEMENTATION
  SYSTEM_EXECUTOR, SYSTEM_EXECUTOR_THREADS, SYSTEM_CALLBACK_GROUP_TYPE
  ROS2_BENCHMARK_MANIFEST_FULL=1  capture every package, not just the core list.
"""

import argparse
import json
import os
import platform
import socket
import subprocess
import sys
from datetime import datetime, timezone
from xml.etree import ElementTree

SCHEMA = "ros2-benchmark-run-manifest/v1"

# Curated core: the packages whose version/source can explain a difference
# between two executor / client library runs. --full records everything instead.
CORE_PACKAGES = [
    "rcl",
    "rclcpp",
    "rclcpp_action",
    "rclcpp_components",
    "rmw",
    "rmw_implementation",
    "rcpputils",
    "rcutils",
    "rmw_fastrtps_cpp",
    "rmw_cyclonedds_cpp",
    "rmw_zenoh_cpp",
    # The benchmark harness itself (external/ros2-performance).
    "performance_test",
    "performance_test_factory",
    "irobot_benchmark",
]


def _run(cmd, cwd=None):
    """Run a command, returning stripped stdout or None on any failure."""
    try:
        out = subprocess.run(
            cmd,
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=15,
        )
        if out.returncode != 0:
            return None
        return out.stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        return None


def _package_version(package_xml):
    """Read the <version> tag from a package.xml, or None."""
    try:
        root = ElementTree.parse(package_xml).getroot()
        node = root.find("version")
        if node is not None and node.text:
            return node.text.strip()
    except (ElementTree.ParseError, OSError):
        pass
    return None


def _ament_prefixes():
    raw = os.environ.get("AMENT_PREFIX_PATH", "")
    return [p for p in raw.split(os.pathsep) if p]


def _find_git_root(path):
    """Walk up from path until a directory containing .git, or None."""
    cur = os.path.abspath(path)
    while True:
        if os.path.exists(os.path.join(cur, ".git")):
            return cur
        parent = os.path.dirname(cur)
        if parent == cur:
            return None
        cur = parent


def _git_info(repo):
    """Collect sha / branch / dirty / remote for a git working tree."""
    sha = _run(["git", "rev-parse", "HEAD"], cwd=repo)
    if sha is None:
        return None
    branch = _run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=repo)
    status = _run(["git", "status", "--porcelain"], cwd=repo)
    remote = _run(["git", "config", "--get", "remote.origin.url"], cwd=repo)
    return {
        "repo": repo,
        "sha": sha,
        "branch": branch,
        "dirty": bool(status),
        "remote": remote,
    }


def _workspace_src_roots(prefixes, ros_install_dir):
    """The 'src' roots backing the non-apt prefixes (a .../install is backed by .../src)."""
    roots = []
    for prefix in prefixes:
        if ros_install_dir and prefix.startswith(ros_install_dir):
            continue
        if prefix.startswith("/opt/ros/"):
            continue
        marker = os.sep + "install"
        idx = prefix.find(marker)
        ws = prefix[:idx] if idx != -1 else prefix
        roots.append(os.path.join(ws, "src"))
    roots.extend(["/ws/src", "/overlay_ws/src"])
    seen, out = set(), []
    for r in roots:
        if r not in seen and os.path.isdir(r):
            seen.add(r)
            out.append(r)
    return out


def _build_source_index(src_roots):
    # An install prefix does not name its source repo, so map package name -> git
    # info by finding the repo containing each package.xml under the src roots.
    index = {}
    repo_cache = {}
    for root in src_roots:
        for dirpath, dirnames, filenames in os.walk(root):
            # Do not descend into nested build/install/log artifacts.
            dirnames[:] = [
                d for d in dirnames if d not in ("build", "install", "log", ".git")
            ]
            if "package.xml" not in filenames:
                continue
            pkg_xml = os.path.join(dirpath, "package.xml")
            try:
                node = ElementTree.parse(pkg_xml).getroot().find("name")
            except (ElementTree.ParseError, OSError):
                continue
            if node is None or not node.text:
                continue
            name = node.text.strip()
            if name in index:
                continue
            repo = _find_git_root(dirpath)
            if repo is None:
                continue
            if repo not in repo_cache:
                repo_cache[repo] = _git_info(repo)
            index[name] = repo_cache[repo]
    return index


def _classify_source(prefix, ros_install_dir):
    if ros_install_dir and prefix.startswith(ros_install_dir):
        return "apt"
    if prefix.startswith("/opt/ros/"):
        return "apt"
    if prefix.startswith("/overlay_ws"):
        return "overlay"
    return "workspace"


def _dpkg_version(distro, package):
    if not distro:
        return None
    deb = "ros-{}-{}".format(distro, package.replace("_", "-"))
    return _run(["dpkg-query", "-W", "-f=${Version}", deb])


def resolve_package(package, prefixes, ros_install_dir, distro, source_index):
    # Record the first prefix on AMENT_PREFIX_PATH carrying the package: that is
    # the one that actually loads. Returns the entry, or None if not found.
    for prefix in prefixes:
        pkg_xml = os.path.join(prefix, "share", package, "package.xml")
        if not os.path.isfile(pkg_xml):
            continue
        source = _classify_source(prefix, ros_install_dir)
        entry = {
            "version": _package_version(pkg_xml),
            "source": source,
            "prefix": prefix,
        }
        if source == "apt":
            entry["dpkg"] = _dpkg_version(distro, package)
        else:
            entry["git"] = source_index.get(package)
        return entry
    return None


def _all_package_names(prefixes):
    """Every package present on AMENT_PREFIX_PATH (first prefix wins)."""
    names = []
    seen = set()
    for prefix in prefixes:
        share = os.path.join(prefix, "share")
        if not os.path.isdir(share):
            continue
        for name in sorted(os.listdir(share)):
            if name in seen:
                continue
            if os.path.isfile(os.path.join(share, name, "package.xml")):
                seen.add(name)
                names.append(name)
    return names


def build_manifest(full=False):
    distro = os.environ.get("ROS_DISTRO")
    ros_install_dir = os.environ.get("ROS_INSTALL_DIR") or (
        "/opt/ros/{}".format(distro) if distro else None
    )
    prefixes = _ament_prefixes()
    src_roots = _workspace_src_roots(prefixes, ros_install_dir)
    source_index = _build_source_index(src_roots)

    executor = os.environ.get("SYSTEM_EXECUTOR") or "EventsCBGExecutor"
    threads = os.environ.get("SYSTEM_EXECUTOR_THREADS") or None
    cbg_type = os.environ.get("SYSTEM_CALLBACK_GROUP_TYPE") or None

    label = os.environ.get("ROS2_BENCHMARK_RUN_LABEL", "").strip()
    if not label:
        label = executor + (" ({}t)".format(threads) if threads else "")
    notes = os.environ.get("ROS2_BENCHMARK_RUN_NOTES", "").strip() or None

    packages = _all_package_names(prefixes) if full else CORE_PACKAGES
    ros_stack = {}
    for pkg in packages:
        entry = resolve_package(
            pkg, prefixes, ros_install_dir, distro, source_index
        )
        if entry is not None:
            ros_stack[pkg] = entry

    return {
        "schema": SCHEMA,
        "label": label,
        "notes": notes,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "host": {
            "hostname": socket.gethostname(),
            "arch": platform.machine(),
            # Cores the benchmark saw (hardware_concurrency). cpu_perc is divided
            # by this, so per-core CPU = cpu_perc * cpu_count.
            "cpu_count": os.cpu_count(),
        },
        "run": {
            "distro": distro,
            "executor": executor,
            "threads": int(threads) if threads and threads.isdigit() else None,
            "callback_group_type": cbg_type,
            "default_rmw": os.environ.get("RMW_IMPLEMENTATION"),
        },
        "capture": {
            "mode": "full" if full else "core",
            "ament_prefix_path": prefixes,
        },
        "ros_stack": ros_stack,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "output_dir",
        nargs="?",
        default=os.environ.get("ROS2_BENCHMARK_OUTPUT_DIR"),
        help="Results directory to write run_manifest.json into "
        "(defaults to $ROS2_BENCHMARK_OUTPUT_DIR).",
    )
    parser.add_argument(
        "--full",
        action="store_true",
        default=os.environ.get("ROS2_BENCHMARK_MANIFEST_FULL") == "1",
        help="Record every package on AMENT_PREFIX_PATH, not just the curated core.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite an existing manifest (default: leave the first one in place).",
    )
    args = parser.parse_args()

    if not args.output_dir:
        # Nothing to write into; stay silent so we never break a run.
        return 0

    manifest_path = os.path.join(args.output_dir, "run_manifest.json")
    if os.path.exists(manifest_path) and not args.force:
        # Runners that share one results dir (run_all_benchmarks) each call this;
        # the first writer wins and the stack is identical across them.
        return 0

    try:
        os.makedirs(args.output_dir, exist_ok=True)
        manifest = build_manifest(full=args.full)
        with open(manifest_path, "w") as f:
            json.dump(manifest, f, indent=2, sort_keys=False)
            f.write("\n")
        print("Wrote run manifest: {} (label: {})".format(
            manifest_path, manifest["label"]))
    except Exception as exc:  # never fail the benchmark over provenance
        print("WARNING: could not write run manifest: {}".format(exc),
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
