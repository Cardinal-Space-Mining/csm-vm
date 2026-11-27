#!/usr/bin/env bash

set -euo pipefail
trap 'echo "Error: Script failed at line $LINENO."; exit 1;' ERR

SCRIPT=$(readlink -f "$0")
SCRIPTPATH=$(dirname "$SCRIPT")

# Homebrew's tools (qemu, socat, pv) aren't on PATH in non-interactive shells
# (ssh commands, launchd, the orchestrator agent).
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"

# --- Configuration ------------------------------------------------------------
# The installer ISO
ISO_URL="https://cdimage.ubuntu.com/ubuntu/releases/26.04/release/ubuntu-26.04.1-live-server-arm64.iso"
ISO_NAME="$(basename "$ISO_URL")"
# The VM storage disk (file). Names are release-agnostic since the guest can be
# upgraded in place (do-release-upgrade) without the disk changing.
BASE_DISK_FILE="ubuntu-aarch64-base.qcow2"
OVERLAY_DISK_FILE="ubuntu-aarch64-overlay.qcow2"
# Older versions of this script used release-specific names; these get migrated.
LEGACY_DISK_PREFIXES=("ubuntu24-aarch64")
BASE_DISK_PATH="$SCRIPTPATH/$BASE_DISK_FILE"
OVERLAY_DISK_PATH="$SCRIPTPATH/$OVERLAY_DISK_FILE"
BASE_DISK_BACKUP_PATH="$SCRIPTPATH/${BASE_DISK_FILE%.qcow2}.backup.qcow2"
OVERLAY_DISK_BACKUP_PATH="$SCRIPTPATH/${OVERLAY_DISK_FILE%.qcow2}.backup.qcow2"
DISK_SIZE="64G"
DISK_CACHE_MODE="none"
# Hardware configuration (defaults; may be overridden by machine.conf)
CPUS=6
RAM=12G
NET_MODE="bridged"
ETH_IFACE="en0" # this is the MacOS-side interface that get's bridged (ethernet port)
MAC_BRIDGE="52:54:00:12:34:56"  # the MAC address in the VM tied to the bridged iface
MAC_HOST="52:54:00:12:34:57"    # the MAC address for the host-to-vm direct iface
MAC_WIFI="52:54:00:12:34:58"    # the MAC address for shared wifi internet access
# Socket for calling shutdown
MONITOR_SOCKET="/tmp/qemu-monitor.sock"
# The VM's serial console in daemon/launchd mode (connect with
# `sudo socat -,raw,echo=0 UNIX-CONNECT:/tmp/qemu-serial.sock`)
SERIAL_SOCKET="/tmp/qemu-serial.sock"
# How long --stopd/--restartd wait for the guest to power off after pressing
# its power button (override with --timeout SECONDS). A hung guest otherwise
# keeps them waiting forever.
STOP_TIMEOUT_S=120
# Pressed again this often while waiting: a press during boot is lost
POWER_PRESS_PERIOD_S=10
# An overlay left by a session that didn't shut down (a power cut, an e-stop)
# is kept as ubuntu-aarch64-overlay.saved-<when it was last written>.qcow2;
# this many of the newest are kept (each can be gigabytes).
SAVED_OVERLAYS_KEPT=5
# What --launchd (autostart at boot) does with such an overlay: "save" it and
# boot the base disk, or "reuse" it (boot straight back into that session).
LAUNCHD_OVERLAY="save"
# QEMU's own output in daemon mode (errors when it fails to start)
QEMU_LOG="$SCRIPTPATH/qemu.log"
# How long to wait at boot for the bridged interface to appear
ETH_WAIT_S=30
# What to do with an overlay left by a previous session, without asking:
# commit | reuse | discard (set with --overlay; empty = ask)
OVERLAY_CHOICE=""
# USB Whitelist: Non-storage USB devices must be whitelisted here to be passed to QEMU.
# Use `system_profiler SPUSBHostDataType` to list devices and find vendor/product id.
# Format: "vendorid:productid"
USB_WHITELIST=(
  "0x16d0:0x117e"   # CANable2
  "0x045e:0x0b12"   # Xbox controller
  "0x0bda:0x8153"   # Realtek ethernet adapter
  "0x0e8d:0x7961"   # Brostrend AXE3000
)

# --- Load machine config (optional overrides) ---------------------------------
# Create a machine.conf next to this script to override CPUS, RAM, ETH_IFACE,
# MAC_BRIDGE, MAC_HOST, MAC_WIFI, and/or USB_WHITELIST. Example machine.conf:
#
#   CPUS=4
#   RAM=8G
#   ETH_IFACE="en1"
#   MAC_BRIDGE="52:54:00:aa:bb:cc"
#   MAC_HOST="52:54:00:aa:bb:cd"
#   MAC_WIFI="52:54:00:aa:bb:ce"
#   USB_WHITELIST=(
#     "0x16d0:0x117e"
#     "0x045e:0x0b12"
#   )
#
MACHINE_CONF="${SCRIPTPATH}/machine.conf"
if [ -f "$MACHINE_CONF" ]; then
  # echo "Loading machine config: $MACHINE_CONF"
  # shellcheck source=/dev/null
  source "$MACHINE_CONF"
# else
#   echo "No machine.conf found; using defaults."
fi

# --- Libraries ----------------------------------------------------------------
# Each is a set of functions (and the variables they share), in lib/ next to
# this script.
for lib in common overlay saved qemu modes; do
  if [ ! -f "$SCRIPTPATH/lib/$lib.sh" ]; then
    echo "ERROR: $SCRIPTPATH/lib/$lib.sh is missing (run-vm.sh needs its lib/ folder)." >&2
    exit 1
  fi
done
# (named one by one, so tools can see what run-vm.sh needs)
source "$SCRIPTPATH/lib/common.sh"
source "$SCRIPTPATH/lib/overlay.sh"
source "$SCRIPTPATH/lib/saved.sh"
source "$SCRIPTPATH/lib/qemu.sh"
source "$SCRIPTPATH/lib/modes.sh"


# --- Main Logic ---------------------------------------------------------------
usage() \
{
  echo -e "Usage: run-vm.sh <OPTIONS>"\
    "\nOPTIONS:"\
    "\n --help | -h  : Print this help message and immediately exit."\
    "\n --wifi | -w  : Enable Wi-Fi sharing (vmnet-shared)."\
    "\n --overlay X  : With --startd/--restartd/--term, what to do with an overlay left by"\
    "\n                a previous session, without asking: commit, reuse or discard."\
    "\n --timeout N  : With --stopd/--restartd, seconds to wait for the guest to power"\
    "\n                off (default ${STOP_TIMEOUT_S}); after that, give up with exit code 2."\
    "\n --term       : Run the VM attached to the current terminal session."\
    "\n --startd     : Run the VM as a headless daemon."\
    "\n --stopd      : Attempt to shutdown a headless daemon VM."\
    "\n --restartd   : Attempt to restart a headless daemon VM."\
    "\n --fkilld     : Force-kill all VM processes."\
    "\n --launchd    : Run the VM in the foreground for use with launchd."\
    "\n --clean      : Commit any pending overlay to base without starting the VM."\
    "\n --backup     : Copy the base disk to a single backup file (VM must be stopped)."\
    "\n --restore    : Restore the base disk from the backup file (VM must be stopped)."\
    "\n --status     : Report whether the VM is currently running."\
    "\n --list-saved : List saved overlays (sessions that didn't shut down)."\
    "\n --recover F  : Make saved overlay F the VM's overlay (the current one is saved"\
    "\n                first); start with --overlay reuse to boot that session."\
    "\n --forget F   : Delete saved overlay F."\
    "\nIf no install is detected, a terminal session will be spawned"\
    "\nto setup the VM regardless of the provided flags."
  exit 0
}

# What every start does before QEMU runs: one VM at a time, its network and USB
# devices, and its overlay ("interactive" may ask what to do with a leftover).
prepare_vm() \
{
  refuse_if_running
  add_networking
  add_usb_devices
  create_or_reuse_overlay "$1"
}

MODE="default"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --term | --startd | --stopd | --restartd | --fkilld | --clean | --launchd | --backup | --restore | --status | --list-saved) MODE="$1"; shift ;;
    --recover | --forget)
      if [ -z "${2:-}" ]; then echo "ERROR: $1 takes a saved overlay's file name" >&2; exit 1; fi
      MODE="$1"; SAVED_NAME="$2"; shift 2 ;;
    -w | --wifi) NET_MODE="wifi"; shift ;;
    --timeout)
      case "${2:-}" in
        '' | *[!0-9]*) echo "ERROR: --timeout takes a number of seconds" >&2; exit 1 ;;
        *) STOP_TIMEOUT_S="$2"; shift 2 ;;
      esac
      ;;
    --overlay)
      case "${2:-}" in
        commit | reuse | discard) OVERLAY_CHOICE="$2"; shift 2 ;;
        *) echo "ERROR: --overlay takes commit, reuse or discard" >&2; exit 1 ;;
      esac
      ;;
    -h | --help | *) MODE="help"; break ;;
  esac
done

migrate_legacy_disks
# Marks an overlay a force stop left behind (after migration fixes the paths)
UNCLEAN_MARKER="${OVERLAY_DISK_PATH}.unclean"
COMMIT_LOCK="${OVERLAY_DISK_PATH}.lock"
RECOVERED_MARKER="${OVERLAY_DISK_PATH}.recovered"
note_unclean_leftover

if [ ! -f "$BASE_DISK_PATH" ]; then
  # Never launch the interactive installer from launchd
  if [ "$MODE" = "--launchd" ]; then
    echo "ERROR: No base disk at $BASE_DISK_PATH. Run ./run-vm.sh manually to install the VM." >&2
    exit 1
  fi
  # Refuse to start a fresh install if an unrecognized VM disk is present
  shopt -s nullglob
  OTHER_BASE_DISKS=( "$SCRIPTPATH"/*-base.qcow2 )
  shopt -u nullglob
  if [ ${#OTHER_BASE_DISKS[@]} -gt 0 ]; then
    echo "ERROR: No base disk at $BASE_DISK_PATH, but found existing VM disk(s):" >&2
    printf '  %s\n' "${OTHER_BASE_DISKS[@]}" >&2
    echo "Refusing to start a fresh install. Either:" >&2
    echo "  - keep using it: rename it to $BASE_DISK_FILE (commit any overlay first), or" >&2
    echo "  - start fresh: move it out of this directory, then re-run." >&2
    exit 1
  fi
  # Create base disk file
  create_and_use_disk_file
  # Find or fetch Ubuntu Server ARM64 ISO and add to VM
  add_iso_file
  # Add networking
  add_networking
  # Run in terminal mode so user can configure install
  run_terminal
else
  # Non-init run -- handle startup mode
  case "$MODE" in
    --startd)
      prepare_vm interactive
      run_daemon
      ;;
    --stopd)
      run_shutdown
      ;;
    --restartd)
      # (run_shutdown exits if the guest doesn't power off in time)
      run_shutdown
      prepare_vm interactive
      run_daemon
      ;;
    --term)
      prepare_vm interactive
      run_terminal
      ;;
    --launchd)
      prepare_vm non-interactive
      run_launchd
      ;;
    --fkilld)
      killall
      ;;
    --clean)
      verify_not_running
      if [ ! -f "$OVERLAY_DISK_PATH" ]; then
        echo "No overlay to commit."
      fi
      commit_overlay || exit 1
      ;;
    --backup)
      backup_base
      ;;
    --restore)
      restore_base
      ;;
    --list-saved)
      for saved in $(saved_overlays); do
        echo "$(basename "$saved")  $(du -h "$saved" | cut -f1)"
      done
      ;;
    --recover)
      recover_saved "$SAVED_NAME"
      ;;
    --forget)
      verify_not_running
      forget_saved "$SAVED_NAME"
      ;;
    --status)
      PIDS=$(qemu_pids)
      if [ -n "$PIDS" ]; then
        echo -e "Ubuntu VM is running. PID(s): \n$PIDS"
        exit 0
      else
        echo "Ubuntu VM is not running."
        exit 1
      fi
      ;;
    *)
      usage
      ;;
  esac
fi
