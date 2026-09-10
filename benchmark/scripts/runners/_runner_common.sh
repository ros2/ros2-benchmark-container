#!/bin/bash

# Copyright (c) 2026, iRobot ROS
# All rights reserved.
#
# This source code is licensed under the BSD 3-Clause License found in the
# LICENSE file in the root directory of this source tree.

# =================================================================================================
#
# Shared setup and helpers for the benchmark runners (run_single_process_benchmark.sh
# and run_multi_process_benchmark.sh). This file is *sourced* by those scripts, not
# executed directly.
#
# On source it parses the common arguments, applies the environment defaults, resolves
# the executor / threads / callback-group options, sets the CPU governor, and sources
# the test-matrix config. It also defines the helpers each runner calls from its own
# (deliberately different) benchmark loop.
#
# It uses the caller's positional parameters ("$@"), so each runner must source it near
# the top, before consuming its own arguments:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/_runner_common.sh"
#
# The two runners keep their own loop bodies: they build different result-directory
# layouts (single: <topology>/<rmw>_<comm>; multi: <RES>/<rmw>_<comm>) and launch a
# different number of irobot_benchmark processes. The post-processing parsers depend on
# those layouts, so they are intentionally NOT unified here.
#
# =================================================================================================

# Many variables set here (CONFIG_FILE, EXECUTOR_ARG, THREADS_OPTION, etc.) are
# consumed by the runner that sources this file, so shellcheck cannot see their use.
# shellcheck disable=SC2034

# --- Argument Validation ---
if [ $# -lt 1 ]; then
  echo "Usage: $0 <config_file> [--remote-host-mode <publisher|subscriber>]"
  echo "  <config_file>: Path to the configuration file defining the test matrix."
  echo "  --remote-host-mode <mode>: 'publisher' or 'subscriber' to add a remote process to the test."
  exit 1
fi

# Set default timeout for how long the script should wait after spawning the router
# before running the benchmarks.
if [[ -z "$ZENOH_ROUTER_WAIT_TIMEOUT" ]]; then
  ZENOH_ROUTER_WAIT_TIMEOUT=1.0
fi

CONFIG_FILE=$1
shift # Shift arguments to parse options

if [ ! -f "$CONFIG_FILE" ]; then
  echo -e "\033[31m[ERROR] Configuration file '$CONFIG_FILE' not found!\033[0m"
  exit 1
fi

# Ensure scripts directory is set if not provided externally.
if [ -z "${ROS2_BENCHMARK_SCRIPTS_DIR}" ]; then
  THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
  ROS2_BENCHMARK_SCRIPTS_DIR="${THIS_DIR}/.."
fi

# Set default output path if not provided externally.
if [[ -z "$ROS2_BENCHMARK_OUTPUT_DIR" ]]; then
  current_date=$(date +"%d_%m_%y_%Hh%M")
  ROS2_BENCHMARK_OUTPUT_DIR="/benchmark_results/results_${current_date}"
fi

# Set default test duration if not provided externally.
if [ -z "${ROS2_BENCHMARK_TEST_DURATION}" ]; then
  ROS2_BENCHMARK_TEST_DURATION=1
fi

# --- Option Parsing ---
REMOTE_HOST_MODE="none"
while [[ $# -gt 0 ]]; do
  case "$1" in
  --remote-host-mode)
    if [[ -n "$2" && ! "$2" =~ ^- ]]; then
      REMOTE_HOST_MODE="$2"
      shift
    else
      echo "Error: --remote-host-mode requires a value (e.g., 'publisher' or 'subscriber')"
      exit 1
    fi
    ;;
  *)
    echo "Error: Unknown option $1"
    exit 1
    ;;
  esac
  shift
done

echo "Loading configuration from: $CONFIG_FILE"
# shellcheck source=/dev/null
source "$CONFIG_FILE"

# --- Environment Setup ---
GOVERNOR_SCRIPT="${ROS2_BENCHMARK_SCRIPTS_DIR}/utils/set_cpu_governor.sh"
IROBOT_BENCHMARK="${PERF_FRAMEWORK_INSTALL_DIR}/irobot_benchmark/irobot_benchmark"

# Possible args for different executor types
declare -A EXECUTOR_ARGS=( ["SingleThreadedExecutor"]="1" ["EventsExecutor"]="2" ["MultiThreadedExecutor"]="3" ["EventsCBGExecutor"]="4")

# Configure system executor, using the EventsExecutor by default.
if [[ -z "${SYSTEM_EXECUTOR}" ]]; then
  SYSTEM_EXECUTOR="EventsExecutor"
fi

if [[ -v EXECUTOR_ARGS[${SYSTEM_EXECUTOR}] ]]; then
    EXECUTOR_ARG="${EXECUTOR_ARGS[${SYSTEM_EXECUTOR}]}"
else
  echo -e "Invalid executor ${SYSTEM_EXECUTOR}. Please choose from SingleThreadedExecutor, MultiThreadedExecutor or EventsExecutor."
  exit 1
fi

# Thread count for thread-pool executors. Only forwarded when explicitly set to
# a positive value — otherwise irobot_benchmark falls back to its own default
# (hardware_concurrency).
THREADS_OPTION=""
if [[ -n "${SYSTEM_EXECUTOR_THREADS}" && "${SYSTEM_EXECUTOR_THREADS}" -gt 0 ]]; then
  THREADS_OPTION="--threads ${SYSTEM_EXECUTOR_THREADS}"
fi

# Set CPU governor to 'performance' mode for consistent results.
# CI runners (e.g. GitHub-hosted) have no cpufreq sysfs and cannot change the
# governor, so honor SKIP_CPU_GOVERNOR=1 to skip this tuning entirely. Unset (the
# default) preserves the strict behavior required for reproducible measurements.
if [[ "${SKIP_CPU_GOVERNOR}" != "1" ]]; then
  original_governor=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor)
  echo "Setting CPU governor to 'performance'."
  $GOVERNOR_SCRIPT performance
  if [ $? -ne 0 ]; then
    echo -e "\033[31m[ERROR] Failed to set CPU governor. Exiting.\033[0m"
    exit 1
  fi
  # Ensure the original governor is restored when the script exits.
  trap "$GOVERNOR_SCRIPT $original_governor" EXIT
else
  echo "SKIP_CPU_GOVERNOR=1 set; leaving CPU governor unchanged."
fi

RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"

# --- Shared helpers ---

# require_config_vars VAR [VAR...]: exit if any named variable is unset/empty.
require_config_vars() {
  local var
  for var in "$@"; do
    if [[ -z "${!var}" ]]; then
      echo -e "\033[31m[ERROR] Required test matrix variable '${var}' is not defined in '$CONFIG_FILE'!\033[0m"
      exit 1
    fi
  done
}

# apply_loaned_env_vars: eval each entry of the per-RMW LOANED_ENV_VARS array
# (the caller sets it as a nameref before invoking).
apply_loaned_env_vars() {
  local var
  for var in "${LOANED_ENV_VARS[@]}"; do
    eval "$var"
  done
}

# start_zenoh_router_if_needed RMW: for RMW=zenoh, spawn zenohd in the background
# and set ROUTER_PID. Aborts if the router does not come up.
start_zenoh_router_if_needed() {
  local rmw="$1"
  [[ "$rmw" != "zenoh" ]] && return 0

  echo "Detected that $rmw is being benchmarked. Spawning router..."
  ${RUNNER_DIR}/run_zenoh_router.sh ${ZENOH_ROUTER_CONFIG_URI} &

  # Wait for the router to come online
  sleep ${ZENOH_ROUTER_WAIT_TIMEOUT}

  ROUTER_PID=$(pgrep zenohd)
  if [[ -z "${ROUTER_PID}" ]]; then
    echo -e "\033[31m[ERROR] zenoh router failed to start (no zenohd process found). Check the router config path (ZENOH_ROUTER_CONFIG_URI).\033[0m"
    exit 1
  fi
  echo "Spawned zenoh router with PID ${ROUTER_PID}"
}

# stop_zenoh_router: kill the router started by start_zenoh_router_if_needed, if any.
stop_zenoh_router() {
  if [[ -n ${ROUTER_PID} ]]; then
    echo "Stopping zenoh router with PID $ROUTER_PID"
    kill ${ROUTER_PID}
    while kill -0 "${ROUTER_PID}">/dev/null 2>&1; do
        echo "Waiting for zenoh router to exit..."
        sleep 0.1
    done
    echo "Stopped zenoh router with PID $ROUTER_PID"
    unset ROUTER_PID
  fi
}

# run_remote_process_if_needed MODE RMW_IMPLEMENTATION: when a remote mode is
# requested, launch a sibling container acting as a remote publisher/subscriber.
run_remote_process_if_needed() {
  local mode="$1" rmw_impl="$2" script_for_remote_host
  [[ "$mode" == "none" ]] && return 0

  if [[ "$mode" == "publisher" ]]; then
    script_for_remote_host="set -e; source $PWD/install/setup.bash; sleep 5; echo 'Publishing...'; ros2 topic pub /test irobot_interfaces_plugin/msg/Stamped1mb -r 1 --times 5; echo 'Done.'; exit"
  elif [[ "$mode" == "subscriber" ]]; then
    script_for_remote_host="set -e; source /root/install/setup.bash; sleep 5; for topic in \$(ros2 topic list | grep -E '^/test(_[0-9]+)?$'); do echo \"Subscribing to \$topic...\"; ros2 topic echo \"\$topic\" > /dev/null & done; wait; echo 'Done subscribing.';"
  else
    echo "Error: Unknown remote host mode '$mode'"
    exit 1
  fi
  echo "Running remote process in '$mode' mode..."
  "${RUNNER_DIR}/run_remote_process.sh" "$rmw_impl" "$script_for_remote_host"
}

# unset_rmw_env_vars: clear per-RMW/comm env vars so they don't leak across iterations.
unset_rmw_env_vars() {
  unset FASTRTPS_DEFAULT_PROFILES_FILE
  unset RMW_FASTRTPS_USE_QOS_FROM_XML
  unset CYCLONEDDS_URI
  unset ZENOH_ROUTER_CONFIG_URI
  unset ZENOH_SESSION_CONFIG_URI
}
