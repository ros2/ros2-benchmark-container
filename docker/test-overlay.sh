#!/bin/bash

# Copyright (c) 2026, iRobot ROS
# All rights reserved.
#
# This source code is licensed under the BSD 3-Clause License found in the
# LICENSE file in the root directory of this source tree.

# =================================================================================================
# Integration test for the `docker/run -w <workspace>` overlay feature.
#
# It builds a throwaway workspace whose install/setup.bash sets a marker and
# prepends AMENT_PREFIX_PATH / LD_LIBRARY_PATH (exactly what a colcon overlay
# does), mounts it at /overlay_ws the way `docker/run -w` does, and asserts the
# container sources it *after* the base install so the overlay shadows the image.
#
# Usage: docker/test-overlay.sh [<ros_distro>] [<arch>]   (defaults: rolling, host arch)
# Requires the image to be built first (the sourcing lives in the image's ~/.bashrc).
# =================================================================================================

set -euo pipefail

DISTRO="${1:-rolling}"
ARCH="${2:-$(dpkg --print-architecture)}"
IMAGE="ros2-benchmark-container:${DISTRO}-${ARCH}"

WS="$(mktemp -d)"
trap 'rm -rf "$WS"' EXIT
mkdir -p "$WS/install"
cat > "$WS/install/setup.bash" <<'EOF'
export OVERLAY_MARKER=overlay-active
export AMENT_PREFIX_PATH="/overlay_ws/install:${AMENT_PREFIX_PATH:-}"
export LD_LIBRARY_PATH="/overlay_ws/install/lib:${LD_LIBRARY_PATH:-}"
EOF

echo "== Overlay integration test against ${IMAGE} =="

# A login-interactive shell (as `docker/run` gives) sources ~/.bashrc, which
# sources the base install and then the overlay if /overlay_ws is mounted.
mounted="$(docker run --rm -v "$WS:/overlay_ws" "$IMAGE" bash -ic '
  echo "MARKER=$OVERLAY_MARKER"
  echo "AMENT_HEAD=${AMENT_PREFIX_PATH%%:*}"
  echo "LD_HEAD=${LD_LIBRARY_PATH%%:*}"' 2>/dev/null)"
echo "$mounted"

fail() { echo "FAIL: $1"; exit 1; }
grep -q 'MARKER=overlay-active'          <<<"$mounted" || fail "overlay setup.bash was not sourced (image rebuilt after the .bashrc change?)"
grep -q 'AMENT_HEAD=/overlay_ws/install' <<<"$mounted" || fail "overlay is not first on AMENT_PREFIX_PATH"
grep -q 'LD_HEAD=/overlay_ws/install/lib' <<<"$mounted" || fail "overlay is not first on LD_LIBRARY_PATH"

# Control: with no overlay mounted the container still starts and the marker is unset.
unmounted="$(docker run --rm "$IMAGE" bash -ic 'echo "MARKER=[$OVERLAY_MARKER]"' 2>/dev/null)"
echo "$unmounted"
grep -q 'MARKER=\[\]' <<<"$unmounted" || fail "overlay marker present without a mount"

echo "PASS: overlay workspace is mounted, sourced after the base, and takes precedence."
