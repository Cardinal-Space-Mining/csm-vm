#!/usr/bin/env bash
set -euo pipefail

# Check if a QEMU process is running
PIDS=$(ps aux | grep '[q]emu-system-aarch64' | awk '{print $2}' || true)

if [ -n "$PIDS" ]; then
    echo -e "Ubuntu VM is running. PID(s): \n$PIDS"
    exit 0
else
    echo "Ubuntu VM is not running."
    exit 1
fi
