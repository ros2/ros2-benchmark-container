#!/bin/bash

# Copyright (c) 2026, iRobot ROS
# All rights reserved.
#
# This source code is licensed under the BSD 3-Clause License found in the
# LICENSE file in the root directory of this source tree.

# =================================================================================================
#
# This script runs single-process benchmarks for the ROS 2 performance testing framework.
#
# It is designed to launch a single performance test process that contains all the
# nodes defined in a given topology file. This makes it ideal for measuring
# intra-process communication performance.
#
# The script takes a configuration file that defines the test matrix, including:
# - `RMW_LIST`: A list of RMW implementations to test.
# - `TOPOLOGIES`: A list of topology files to run.
# - `COMMS_<RMW>`: Communication modes to test for each RMW (e.g., ipc_on, ipc_off, loaned).
#
# It also supports a `--remote-host-mode` for testing discovery with remote nodes.
#
# Common setup (argument/option parsing, environment defaults, executor options, CPU
# governor, config sourcing) and shared helpers live in _runner_common.sh.
#
# =================================================================================================

# Parse arguments, apply defaults, and source the config. Uses "$@", so this must
# come before we touch the positional parameters.
source "$(dirname "${BASH_SOURCE[0]}")/_runner_common.sh"

# Validate that essential variables are defined in the config file.
require_config_vars RMW_LIST TOPOLOGIES

# --- Output Directory Setup ---
# Append a suffix to the output directory if running in remote host mode.
OUTPUT_DIR="${ROS2_BENCHMARK_OUTPUT_DIR}/${OUTPUT_DIR_NAME}"
if [[ "$REMOTE_HOST_MODE" != "none" ]]; then
  OUTPUT_DIR="${ROS2_BENCHMARK_OUTPUT_DIR}/${OUTPUT_DIR_NAME}_remote_host"
fi
echo "Results will be stored in: $OUTPUT_DIR"
rm -rf "$OUTPUT_DIR" && mkdir -p "$OUTPUT_DIR"

# --- Benchmark Execution Loop ---
for RMW in "${RMW_LIST[@]}"; do
  echo -e "\n\033[1;34mProcessing RMW: $RMW\033[0m"

  # Set the RMW_IMPLEMENTATION for the benchmark process.
  export RMW_IMPLEMENTATION="rmw_${RMW}_cpp"

  # Dynamically get the COMMS and LOANED_ENV_VARS arrays for the current RMW.
  declare -n COMMS="COMMS_${RMW}"
  declare -n LOANED_ENV_VARS="LOANED_ENV_VARS_${RMW}"
  echo "  COMMS for $RMW: ${COMMS[@]}"
  echo "  LOANED_ENV_VARS for $RMW: ${LOANED_ENV_VARS[@]}"

  for COMM in "${COMMS[@]}"; do
    echo -e "\n  \033[1;32mTesting COMM: $COMM\033[0m"

    # Export specific environment variables if running a 'loaned' message test.
    if [[ "$COMM" == "loaned" ]]; then
      apply_loaned_env_vars
    fi

    # Set the --ipc flag based on the communication mode.
    IPC_OPTION="--ipc off"
    if [[ "$COMM" == "ipc_on" ]]; then
      IPC_OPTION="--ipc on"
    fi

    # Loop through each topology defined in the config file.
    for TOPOLOGY in "${TOPOLOGIES[@]}"; do
      start_zenoh_router_if_needed "$RMW"

      TEST_CASE_DIR="${OUTPUT_DIR}/${TOPOLOGY}"
      mkdir -p "${TEST_CASE_DIR}"

      # Select the correct topology file, using the '_loaned' version if required.
      if [[ "$COMM" == "loaned" ]]; then
        TOPOLOGY_PATH="${TOPOLOGIES_DIR}/${TOPOLOGY}_loaned.json"
      else
        TOPOLOGY_PATH="${TOPOLOGIES_DIR}/${TOPOLOGY}.json"
      fi

      RESULT_FOLDER="${TEST_CASE_DIR}/${RMW}_${COMM}"
      echo -e "    \033[32m-> Running topology: $TOPOLOGY\033[0m"
      echo "       Results will be in: $RESULT_FOLDER"

      # If a remote mode is specified, launch a sibling container as a remote node.
      run_remote_process_if_needed "$REMOTE_HOST_MODE" "$RMW_IMPLEMENTATION"

      # --- Local Benchmark Execution ---
      # Construct and execute the main benchmark command.
      COMMAND="${IROBOT_BENCHMARK} ${TOPOLOGY_PATH} --executor ${EXECUTOR_ARG} ${THREADS_OPTION} ${CALLBACK_GROUP_OPTION} ${IPC_OPTION} -t ${ROS2_BENCHMARK_TEST_DURATION} -s 1000 --csv-out on --results-dir ${RESULT_FOLDER}"
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

echo -e "\n\033[1;32mSingle-process benchmark run completed successfully.\033[0m"
