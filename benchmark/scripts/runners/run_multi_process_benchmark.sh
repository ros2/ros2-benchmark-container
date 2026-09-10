#!/bin/bash

# Copyright (c) 2026, iRobot ROS
# All rights reserved.
#
# This source code is licensed under the BSD 3-Clause License found in the
# LICENSE file in the root directory of this source tree.

# =================================================================================================
#
# This script runs multi-process benchmarks for the ROS 2 performance testing framework.
#
# It is designed to launch two concurrent performance test processes, making it suitable
# for inter-process communication benchmarks on a single host or distributed tests
# involving a remote host.
#
# The script takes a configuration file that defines the test matrix, including:
# - `RMW_LIST`: A list of RMW implementations to test.
# - `TOPOLOGY1`, `TOPOLOGY2`: Paired lists of topology files. For each test, one
#   process is launched with a topology from TOPOLOGY1 and another with the
#   corresponding one from TOPOLOGY2.
# - `COMMS_<RMW>`: Communication modes to test for each RMW (e.g., ipc_off, loaned).
#
# It also supports a `--remote-host-mode` for distributed testing.
#
# Common setup (argument/option parsing, environment defaults, executor options, CPU
# governor, config sourcing) and shared helpers live in _runner_common.sh.
#
# =================================================================================================

# Parse arguments, apply defaults, and source the config. Uses "$@", so this must
# come before we touch the positional parameters.
source "$(dirname "${BASH_SOURCE[0]}")/_runner_common.sh"

# Validate that essential variables are defined in the config file.
require_config_vars RMW_LIST TOPOLOGY1

# --- Output Directory Setup ---
OUTPUT_DIR="${ROS2_BENCHMARK_OUTPUT_DIR}/${OUTPUT_DIR_NAME}"
echo "Results will be stored in: $OUTPUT_DIR"
rm -rf "$OUTPUT_DIR" && mkdir -p "$OUTPUT_DIR"

# --- Benchmark Execution Loop ---
for RMW in "${RMW_LIST[@]}"; do
  echo -e "\n\033[1;34mProcessing RMW: $RMW\033[0m"

  # Dynamically get the COMMS and LOANED_ENV_VARS arrays for the current RMW.
  declare -n COMMS="COMMS_${RMW}"
  declare -n LOANED_ENV_VARS="LOANED_ENV_VARS_${RMW}"
  echo "  COMMS for $RMW: ${COMMS[@]}"
  echo "  LOANED_ENV_VARS for $RMW: ${LOANED_ENV_VARS[@]}"

  for COMM in "${COMMS[@]}"; do
    echo -e "\n  \033[1;32mTesting COMM: $COMM\033[0m"

    # Set the RMW_IMPLEMENTATION for the benchmark processes.
    export RMW_IMPLEMENTATION="rmw_${RMW}_cpp"

    # Export specific environment variables if running a 'loaned' message test.
    if [[ "$COMM" == "loaned" ]]; then
      apply_loaned_env_vars
    fi

    # Loop through the paired topologies defined in the config file.
    for i in "${!TOPOLOGY1[@]}"; do
      start_zenoh_router_if_needed "$RMW"

      T1="${TOPOLOGY1[i]}"
      T2="${TOPOLOGY2[i]}"
      RES="${RESULTS[i]}"

      echo -e "    \033[32m-> Running topology pair: ($T1, $T2)\033[0m"

      RESULT_FOLDER="${OUTPUT_DIR}/${RES}/${RMW}_${COMM}"
      mkdir -p "$RESULT_FOLDER"

      # Select the correct topology file based on the communication mode.
      if [[ "$COMM" == "loaned" ]]; then
        TOP1_PATH="${TOPOLOGIES_DIR}/${T1}_loaned.json"
      else
        TOP1_PATH="${TOPOLOGIES_DIR}/${T1}.json"
      fi
      TOP2_PATH="${TOPOLOGIES_DIR}/${T2}.json"

      # If a remote mode is specified, launch a sibling container as a remote node.
      run_remote_process_if_needed "$REMOTE_HOST_MODE" "$RMW_IMPLEMENTATION"

      # --- Local Benchmark Execution ---
      # Construct and execute the main benchmark command.
      # This launches two processes concurrently using the specified topologies.
      COMMAND="${IROBOT_BENCHMARK} ${TOP1_PATH} ${TOP2_PATH} --executor ${EXECUTOR_ARG} ${THREADS_OPTION} ${CALLBACK_GROUP_OPTION} --ipc off -t ${ROS2_BENCHMARK_TEST_DURATION} -s 1000 --csv-out on --results-dir ${RESULT_FOLDER}"
      echo -e "     Command: \n       $COMMAND"

      eval "$COMMAND"
      benchmark_exit_code=$?

      stop_zenoh_router

      if [ $benchmark_exit_code -ne 0 ]; then
        echo -e "\033[31m[ERROR] Command failed: $COMMAND\033[0m"
        exit 1
      fi
    done

    # Unset environment variables at the end of the loop to avoid side effects.
    unset_rmw_env_vars
  done
done

echo -e "\n\033[1;32mMulti-process benchmark run completed successfully.\033[0m"
