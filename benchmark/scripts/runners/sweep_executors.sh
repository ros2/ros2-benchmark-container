#!/bin/bash

# Copyright (c) 2026, iRobot ROS
# All rights reserved.
#
# This source code is licensed under the BSD 3-Clause License found in the
# LICENSE file in the root directory of this source tree.

# =================================================================================================
#
# Sweep executors over a pub/sub matrix, then compare the runs: run the ordinary
# single/multi-process runners once per executor (varying SYSTEM_EXECUTOR /
# SYSTEM_EXECUTOR_THREADS), parse each with generate_all_metrics.sh, and call
# compare_runs.py for the charts and provenance diff. The executor axis lives
# here, not in the .conf files, so the existing confs are reused unchanged.
#
# Run inside the benchmark container (needs PERF_FRAMEWORK_INSTALL_DIR and,
# unless SKIP_CPU_GOVERNOR=1, root for the CPU governor).
#
# =================================================================================================

set -eo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
SCRIPTS_DIR="$(cd "${THIS_DIR}/.." >/dev/null && pwd)"
BENCH_DIR="$(cd "${SCRIPTS_DIR}/.." >/dev/null && pwd)"
TEST_MATRIX_DIR="${BENCH_DIR}/test-matrix"

# Defaults ------------------------------------------------------------------
OUTPUT_BASE=""
TEST_DURATION="${ROS2_BENCHMARK_TEST_DURATION:-10}"

# Executors to sweep, as "executor:threads:label" (threads may be empty for the
# irobot_benchmark default). Override with --executors "a:1:LabelA;b::LabelB".
DEFAULT_EXECUTORS="SingleThreadedExecutor::SingleThreaded;EventsExecutor::EventsExecutor;MultiThreadedExecutor:4:MultiThreaded (4t);EventsCBGExecutor:1:EventsCBG (1t);EventsCBGExecutor:4:EventsCBG (4t)"
EXECUTORS_SPEC="${DEFAULT_EXECUTORS}"

# Confs each executor runs against (comma-separated basenames or paths).
# Override with --single-confs / --multi-confs.
SINGLE_CONFS="single_process_pub_sub.conf"
MULTI_CONFS="multi_process_pub_sub.conf"

# Note attached to every run's manifest in this sweep; label is per-executor.
SWEEP_NOTES="${ROS2_BENCHMARK_RUN_NOTES:-}"

usage() {
  cat <<EOF
Usage: $0 [options]

Sweep executors over a pub/sub matrix and compare the runs.

Options:
  --output <dir>         Base output directory. Default:
                         /benchmark_results/executor_comparison_<date>
  -t, --duration <sec>   Seconds per test (default: ${TEST_DURATION}).
  --executors <spec>     ';'-separated "executor:threads:label" entries.
                         threads may be empty. Default is the standard set:
                         ST / EventsExecutor / MT-4t / EventsCBG-1t / EventsCBG-4t.
  --single-confs <list>  Comma-separated single-process confs (basename or path).
                         Default: ${SINGLE_CONFS}
  --multi-confs <list>   Comma-separated multi-process confs (basename or path).
                         Default: ${MULTI_CONFS}
  --notes <text>         Note recorded in every run's manifest.
  -h, --help             Show this help.

Example:
  # Compare a stock build against a source-built rclcpp (run twice, different
  # images/overlays), tagging each so the graphs name themselves:
  $0 --executors "EventsCBGExecutor:4:EventsCBG (stock)" --notes "apt rclcpp"
  # ... rebuild/overlay with your rclcpp, then:
  $0 --executors "EventsCBGExecutor:4:EventsCBG (thread iso)" --notes "branch jm/thread-iso"
  # ... and compare across the two output dirs with compare_runs.py.
EOF
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) OUTPUT_BASE="$2"; shift 2 ;;
    -t|--duration) TEST_DURATION="$2"; shift 2 ;;
    --executors) EXECUTORS_SPEC="$2"; shift 2 ;;
    --single-confs) SINGLE_CONFS="$2"; shift 2 ;;
    --multi-confs) MULTI_CONFS="$2"; shift 2 ;;
    --notes) SWEEP_NOTES="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

if [[ -z "${OUTPUT_BASE}" ]]; then
  OUTPUT_BASE="/benchmark_results/executor_comparison_$(date +%d_%m_%y_%Hh%M)"
fi
mkdir -p "${OUTPUT_BASE}"

# Resolve a conf basename to a full path under test-matrix (pass-through if abs).
resolve_conf() {
  local c="$1"
  if [[ "$c" == /* ]]; then echo "$c"; else echo "${TEST_MATRIX_DIR}/${c}"; fi
}

# Turn a label into a filesystem-safe slug for the per-executor result dir.
slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_' | sed 's/__*/_/g; s/^_//; s/_$//'
}

RUN_DIRS=()

echo "=== Executor comparison sweep ==="
echo "Output base:  ${OUTPUT_BASE}"
echo "Duration:     ${TEST_DURATION}s per test"
echo "Executors:    ${EXECUTORS_SPEC}"
echo

IFS=';' read -r -a EXEC_ENTRIES <<< "${EXECUTORS_SPEC}"
for entry in "${EXEC_ENTRIES[@]}"; do
  [[ -z "${entry}" ]] && continue
  # entry = executor:threads:label   (label may contain spaces/parens)
  executor="${entry%%:*}"
  rest="${entry#*:}"
  threads="${rest%%:*}"
  label="${rest#*:}"
  [[ -z "${label}" || "${label}" == "${rest}" ]] && label="${executor}"

  slug="$(slugify "${label}")"
  run_dir="${OUTPUT_BASE}/${slug}"
  echo "--- ${label}  (executor=${executor} threads=${threads:-default}) -> ${run_dir}"

  export SYSTEM_EXECUTOR="${executor}"
  if [[ -n "${threads}" ]]; then
    export SYSTEM_EXECUTOR_THREADS="${threads}"
  else
    unset SYSTEM_EXECUTOR_THREADS
  fi
  export ROS2_BENCHMARK_OUTPUT_DIR="${run_dir}"
  export ROS2_BENCHMARK_TEST_DURATION="${TEST_DURATION}"
  export ROS2_BENCHMARK_SCRIPTS_DIR="${SCRIPTS_DIR}"
  export ROS2_BENCHMARK_RUN_LABEL="${label}"
  [[ -n "${SWEEP_NOTES}" ]] && export ROS2_BENCHMARK_RUN_NOTES="${SWEEP_NOTES}"
  mkdir -p "${run_dir}"

  IFS=',' read -r -a singles <<< "${SINGLE_CONFS}"
  for conf in "${singles[@]}"; do
    [[ -z "${conf}" ]] && continue
    "${THIS_DIR}/run_single_process_benchmark.sh" "$(resolve_conf "${conf}")"
  done
  IFS=',' read -r -a multis <<< "${MULTI_CONFS}"
  for conf in "${multis[@]}"; do
    [[ -z "${conf}" ]] && continue
    "${THIS_DIR}/run_multi_process_benchmark.sh" "$(resolve_conf "${conf}")"
  done

  echo "Parsing metrics for ${label}..."
  "${BENCH_DIR}/generate_all_metrics.sh" "${run_dir}" --skip-long-tests --skip-remote-tests
  RUN_DIRS+=("${run_dir}")
done

echo
echo "=== Comparing ${#RUN_DIRS[@]} runs ==="
COMPARISON_DIR="${OUTPUT_BASE}/comparison"
python3 "${SCRIPTS_DIR}/post-processing/compare_runs.py" \
  "${RUN_DIRS[@]}" --output "${COMPARISON_DIR}"

echo
echo "Done. Per-executor results under ${OUTPUT_BASE}/, comparison in ${COMPARISON_DIR}/"
