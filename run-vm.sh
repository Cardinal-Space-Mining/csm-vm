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

# --- QEMU base args (built after config is loaded) ----------------------------
QEMU_ARGS=(
  -machine virt
  -accel hvf
  -cpu host
  -smp "cpus=${CPUS},sockets=1,cores=${CPUS},threads=1"
  -m "$RAM"
  -drive "if=pflash,format=raw,file=/opt/homebrew/share/qemu/edk2-aarch64-code.fd,readonly=on"
  -monitor "unix:${MONITOR_SOCKET},server,nowait"
)


# --- Functionality ------------------------------------------------------------
# Run a command as root: directly when already root, else through sudo. Without
# a terminal sudo can't ask for a password, so -n makes it fail instead of hang.
as_root() \
{
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif [ -t 0 ]; then
    sudo "$@"
  else
    sudo -n "$@"
  fi
}

# Disk files belong to the owner of this directory even when the script runs as
# root (launchd, sudo): otherwise later commits by that user need sudo.
DISK_OWNER=$(stat -f %Su "$SCRIPTPATH")
give_to_owner() \
{
  if [ "$(id -u)" -eq 0 ]; then
    chown "$DISK_OWNER" "$@" 2>/dev/null || true
  fi
}

# A fresh, empty overlay on the base disk. CREATED_OVERLAY tells run_daemon it
# may remove it again if QEMU fails to start (it holds nothing yet).
CREATED_OVERLAY=0
new_overlay() \
{
  rm -f "$UNCLEAN_MARKER"
  qemu-img create -f qcow2 -b "$BASE_DISK_PATH" -F qcow2 "$OVERLAY_DISK_PATH"
  give_to_owner "$OVERLAY_DISK_PATH"
  CREATED_OVERLAY=1
}

# Rename disks from older release-specific names (e.g. ubuntu24-aarch64-base.qcow2)
# to the current names, repointing overlays at the renamed base. If a VM is running,
# keep using the legacy paths for this invocation so stop/commit still work.
migrate_legacy_disks() \
{
  [ -f "$BASE_DISK_PATH" ] && return 0

  local prefix old_base old_overlay old_base_bak old_overlay_bak
  for prefix in "${LEGACY_DISK_PREFIXES[@]}"; do
    old_base="$SCRIPTPATH/${prefix}-base.qcow2"
    [ -f "$old_base" ] || continue
    old_overlay="$SCRIPTPATH/${prefix}-overlay.qcow2"
    old_base_bak="$SCRIPTPATH/${prefix}-base.backup.qcow2"
    old_overlay_bak="$SCRIPTPATH/${prefix}-overlay.backup.qcow2"

    if pgrep -f "qemu-system-aarch64.*${old_overlay}" >/dev/null; then
      echo "Note: VM is running on legacy disk names (${prefix}-*); they will be migrated on the next run after it stops."
      BASE_DISK_PATH="$old_base"
      OVERLAY_DISK_PATH="$old_overlay"
      BASE_DISK_BACKUP_PATH="$old_base_bak"
      OVERLAY_DISK_BACKUP_PATH="$old_overlay_bak"
      return 0
    fi

    echo "Migrating legacy disk names ${prefix}-* -> ${BASE_DISK_FILE%-base.qcow2}-*..."
    mv "$old_base" "$BASE_DISK_PATH"
    if [ -f "$old_overlay" ]; then
      mv "$old_overlay" "$OVERLAY_DISK_PATH"
      # Unsafe rebase only rewrites the backing path; contents are unchanged
      qemu-img rebase -u -b "$BASE_DISK_PATH" -F qcow2 "$OVERLAY_DISK_PATH"
    fi
    if [ -f "$old_base_bak" ]; then
      mv "$old_base_bak" "$BASE_DISK_BACKUP_PATH" \
        || echo "WARNING: Could not rename $old_base_bak"
    fi
    if [ -f "$old_overlay_bak" ]; then
      if mv "$old_overlay_bak" "$OVERLAY_DISK_BACKUP_PATH"; then
        qemu-img rebase -u -b "$BASE_DISK_PATH" -F qcow2 "$OVERLAY_DISK_BACKUP_PATH" \
          || echo "WARNING: Could not repoint $OVERLAY_DISK_BACKUP_PATH at the new base (try with sudo)."
      else
        echo "WARNING: Could not rename $old_overlay_bak"
      fi
    fi
    echo "Migration complete."
    return 0
  done
}

create_and_use_disk_file() \
{
  # Create base qcow2 image instead of raw to support read only base + overlay
  echo "Creating base QCOW2 disk $BASE_DISK_PATH ($DISK_SIZE)..."
  qemu-img create -f qcow2 "$BASE_DISK_PATH" "$DISK_SIZE"

  # Use base disk directly for installation
  QEMU_ARGS+=( -drive "file=${BASE_DISK_PATH},if=virtio,format=qcow2,cache=${DISK_CACHE_MODE}" )
}

# Create or reuse overlay if it already exists.
# Pass "interactive" as first arg to prompt the user on leftover overlay detection.
create_or_reuse_overlay() \
{
  local mode="${1:-interactive}"

  if [ -f "$OVERLAY_DISK_PATH" ]; then
    echo "Found existing overlay: $OVERLAY_DISK_PATH. Checking integrity..."
    if qemu-img check "$OVERLAY_DISK_PATH" >/dev/null 2>&1; then
      echo "Overlay OK."
      if [ "$mode" = "interactive" ]; then
        if [ -z "$OVERLAY_CHOICE" ] && [ ! -t 0 ]; then
          echo "ERROR: An uncommitted overlay from a previous session was detected," >&2
          echo "and there is no terminal to ask. Re-run with --overlay commit|reuse|discard." >&2
          exit 1
        fi
        if [ -z "$OVERLAY_CHOICE" ]; then
          echo "An uncommitted overlay from a previous session was detected."
          echo "  [c] Commit to base and start fresh"
          echo "  [r] Reuse as-is (resume from previous state)"
          echo "  [d] Discard and start fresh"
          read -rp "Choice [c/r/d]: " OVERLAY_CHOICE
        fi
        case "$OVERLAY_CHOICE" in
          c|C|commit)
            commit_overlay || exit 1
            new_overlay
            ;;
          d|D|discard)
            echo "Discarding overlay..."
            rm -f "$OVERLAY_DISK_PATH"
            new_overlay
            ;;
          *)
            echo "Reusing existing overlay."
            ;;
        esac
      else
        # Non-interactive (launchd): save one rolling backup, then start fresh
        echo "WARNING: Uncommitted overlay detected from a previous session. Saving backup and discarding."
        mv -f "$OVERLAY_DISK_PATH" "$OVERLAY_DISK_BACKUP_PATH" 2>/dev/null \
          || { echo "WARNING: Could not save backup; discarding overlay."; rm -f "$OVERLAY_DISK_PATH"; }
        new_overlay
      fi
    else
      echo "Overlay corrupted. Saving backup and creating new overlay."
      mv -f "$OVERLAY_DISK_PATH" "$OVERLAY_DISK_BACKUP_PATH" 2>/dev/null \
        || { echo "WARNING: Could not save backup; discarding overlay."; rm -f "$OVERLAY_DISK_PATH"; }
      new_overlay
    fi
  else
    echo "Creating new overlay for this session..."
    new_overlay
  fi

  # Add to QEMU_ARGS dynamically
  QEMU_ARGS+=( -drive "file=${OVERLAY_DISK_PATH},if=virtio,format=qcow2,cache=${DISK_CACHE_MODE}" )
}

add_iso_file() \
{
  # Only use the ISO matching ISO_URL so a leftover ISO from an older release isn't picked up
  ISO_FILE="$SCRIPTPATH/$ISO_NAME"
  if [ ! -f "$ISO_FILE" ]; then
    echo "No Ubuntu ISO found locally. Attempting to download..."
    echo "  $ISO_URL"
    # check if URL is reachable
    if curl -sfI "$ISO_URL" >/dev/null; then
      curl -L -o "$ISO_FILE" "$ISO_URL"
    else
      echo "ERROR: ISO not reachable at $ISO_URL" >&2
      exit 1
    fi
  fi
  QEMU_ARGS+=( -drive "file=${ISO_FILE},media=cdrom,if=virtio" )
  echo "Using ISO: $ISO_FILE"
}

add_usb_devices() \
{
  echo "Scanning USB devices..."

  # Add all storage devices as "raw"
  EXTERNAL_DISKS=$(diskutil list | grep "(external, physical)" | awk '{print $1}' || true)
  for DISK in $EXTERNAL_DISKS; do
    diskutil unmountDisk force "$DISK" || true
    QEMU_ARGS+=( -drive "file=$DISK,if=virtio,format=raw" )
    echo "Added external storage device: $DISK"
  done

  USB_DEVICES=($(system_profiler SPUSBHostDataType 2>/dev/null | awk '
    BEGIN { RS="(\n){2,}"; FS="\n" }
    {
        vid=""; pid=""

        for (i=1; i<=NF; i++) {
            if ($i ~ /Vendor ID:/) {
                match($i, /0x[0-9a-fA-F]+/)
                vid = substr($i, RSTART, RLENGTH)
            }
            if ($i ~ /Product ID:/) {
                match($i, /0x[0-9a-fA-F]+/)
                pid = substr($i, RSTART, RLENGTH)
            }
        }

        if (vid && pid)
            print vid ":" pid
    }
    ' || true))

  # Add usb controller
  QEMU_ARGS+=( -device qemu-xhci,id=xhci )

  # Add whitelisted non-storage devices
  USB_DEVICES=("${USB_DEVICES[@]:-}")
  for DEV in "${USB_DEVICES[@]}"; do
    for WHITELISTED in "${USB_WHITELIST[@]}"; do
      if [ "$DEV" = "$WHITELISTED" ]; then
        VID=$(echo "$DEV" | cut -d: -f1)
        PID=$(echo "$DEV" | cut -d: -f2)
        QEMU_ARGS+=( -device "usb-host,vendorid=${VID},productid=${PID},bus=xhci.0" )
        echo "Added USB device $VID:$PID"
      fi
    done
  done
}

add_networking() \
{
  # At boot (launchd) the interface may not exist yet; QEMU fails without it
  local waited=0
  until ifconfig "$ETH_IFACE" >/dev/null 2>&1; do
    if [ "$waited" -ge "$ETH_WAIT_S" ]; then
      echo "WARNING: $ETH_IFACE still missing after ${ETH_WAIT_S}s; starting anyway." >&2
      break
    fi
    [ "$waited" -eq 0 ] && echo "Waiting for $ETH_IFACE..."
    sleep 1
    waited=$((waited + 1))
  done

  # Always bridge the ethernet interface so the VM is visible on the LAN
  QEMU_ARGS+=( -netdev "vmnet-bridged,id=net0,ifname=$ETH_IFACE" )
  QEMU_ARGS+=( -device "virtio-net-pci,netdev=net0,mac=$MAC_BRIDGE" )

  # Always add a host-only interface for direct host<->VM SSH
  QEMU_ARGS+=( -netdev "vmnet-host,id=net1" )
  QEMU_ARGS+=( -device "virtio-net-pci,netdev=net1,mac=$MAC_HOST" )

  # Optionally add vmnet-shared for internet access over WiFi
  if [ "$NET_MODE" = "wifi" ]; then
    QEMU_ARGS+=( -netdev "vmnet-shared,id=net2" )
    QEMU_ARGS+=( -device "virtio-net-pci,netdev=net2,mac=$MAC_WIFI" )
  fi
}

copy_with_progress() \
{
  local src="$1" dst="$2"
  if command -v pv >/dev/null 2>&1; then
    pv "$src" > "$dst"
  else
    rsync --progress "$src" "$dst"
  fi
}

backup_base() \
{
  verify_not_running
  echo "Backing up base disk to $BASE_DISK_BACKUP_PATH..."
  copy_with_progress "$BASE_DISK_PATH" "$BASE_DISK_BACKUP_PATH"
  echo "Backup complete."
}

restore_base() \
{
  verify_not_running
  if [ ! -f "$BASE_DISK_BACKUP_PATH" ]; then
    echo "ERROR: No backup found at $BASE_DISK_BACKUP_PATH" >&2
    exit 1
  fi
  echo "Restoring base disk from backup..."
  copy_with_progress "$BASE_DISK_BACKUP_PATH" "$BASE_DISK_PATH"
  rm -f "$OVERLAY_DISK_PATH" "$UNCLEAN_MARKER"
  echo "Restore complete. Previous overlay discarded."
}

# Returns 1 if the commit fails (the overlay is kept for manual recovery).
commit_overlay() \
{
  [ -f "$OVERLAY_DISK_PATH" ] || return 0
  if [ -f "$UNCLEAN_MARKER" ]; then
    echo "WARNING: this overlay is from a VM that was force-stopped: the guest"
    echo "didn't shut down, so files written just before may be incomplete."
  fi
  echo "Committing overlay to base..."
  local status=0
  # Files made by an older root-run start aren't writable by us: commit as root
  if [ -w "$OVERLAY_DISK_PATH" ] && [ -w "$BASE_DISK_PATH" ]; then
    qemu-img commit "$OVERLAY_DISK_PATH" || status=$?
  else
    echo "The disk files aren't writable by $(id -un): committing as root."
    as_root qemu-img commit "$OVERLAY_DISK_PATH" || status=$?
  fi
  if [ "$status" -eq 0 ]; then
    echo "Overlay committed successfully."
    rm -f "$OVERLAY_DISK_PATH" "$UNCLEAN_MARKER"
  else
    echo "ERROR: commit failed; the overlay is kept for manual recovery." >&2
    return 1
  fi
}

qemu_pids() \
{
  ps aux | grep '[q]emu-system-aarch64' | awk '{print $2}' || true
}

# QEMU runs as root, so killing it takes root too.
killall() \
{
  PIDS=$(qemu_pids)
  if [ -z "$PIDS" ]; then
    echo "No VM processes detected."
    exit 1
  fi
  echo "Killing PID(s):" $PIDS
  as_root kill -9 $PIDS || true
  sleep 1
  if [ -n "$(qemu_pids)" ]; then
    echo "ERROR: the VM is still running: could not kill it as root" >&2
    echo "(passwordless sudo is needed without a terminal)." >&2
    exit 1
  fi
  echo "VM killed."
  if [ -f "$OVERLAY_DISK_PATH" ]; then
    touch "$UNCLEAN_MARKER"
    give_to_owner "$UNCLEAN_MARKER"
    echo "Its overlay is marked unclean: the guest didn't shut down, so check"
    echo "the VM before committing it (or discard it)."
  fi
  exit 0
}


# --- Execution Modes ----------------------------------------------------------
run_terminal() \
{
  QEMU_ARGS+=(-nographic -serial "mon:stdio")

  echo "--- RUNNING QEMU (TERMINAL) ---"
  echo "qemu-system-aarch64 ${QEMU_ARGS[@]}"
  echo "--------------------"
  
  sudo qemu-system-aarch64 "${QEMU_ARGS[@]}"

  commit_overlay || exit 1
}

# Without a terminal, sudo can't ask for a password: fail clearly instead of
# leaving a background sudo waiting forever.
check_sudo() \
{
  if [ -t 0 ]; then
    sudo -v
  elif ! sudo -n -l "$(command -v qemu-system-aarch64)" >/dev/null 2>&1; then
    echo "ERROR: passwordless sudo for qemu-system-aarch64 is needed when there is no terminal." >&2
    exit 1
  fi
}

run_daemon() \
{
  QEMU_ARGS+=(-display none -serial "unix:${SERIAL_SOCKET},server,nowait")

  echo "--- RUNNING QEMU (DAEMON) ---"
  echo "nohup qemu-system-aarch64 ${QEMU_ARGS[@]} >$QEMU_LOG 2>&1 &"
  echo "-----------------------------"
  check_sudo
  nohup sudo qemu-system-aarch64 "${QEMU_ARGS[@]}" >"$QEMU_LOG" 2>&1 &
  give_to_owner "$QEMU_LOG"

  # QEMU fails fast on bad arguments or missing permissions: report it.
  sleep 3
  if pgrep -f "qemu-system-aarch64.*${OVERLAY_DISK_PATH}" >/dev/null; then
    echo "VM started. Serial console: ${SERIAL_SOCKET}"
  else
    echo "ERROR: QEMU exited right away. Its output ($QEMU_LOG):" >&2
    # (without the libusb warnings QEMU prints for every passed-through device)
    grep -v "libusb_kernel_driver_active" "$QEMU_LOG" | tail -n 20 >&2 || true
    # An overlay made by this start holds nothing yet: don't leave it behind
    if [ "$CREATED_OVERLAY" -eq 1 ]; then
      rm -f "$OVERLAY_DISK_PATH"
      echo "Removed the empty overlay this start created." >&2
    fi
    exit 1
  fi
}

run_launchd() \
{
  QEMU_ARGS+=(-display none -serial "unix:${SERIAL_SOCKET},server,nowait")

  echo "--- RUNNING QEMU (LAUNCHD) ---"
  echo "qemu-system-aarch64 ${QEMU_ARGS[@]}"
  echo "------------------------------"

  qemu-system-aarch64 "${QEMU_ARGS[@]}"

  commit_overlay || exit 1
}

# Press the guest's power button, wait (at most STOP_TIMEOUT_S) for it to power
# off, then commit its overlay. Exits 2 on a timeout: the VM is still running.
run_shutdown() \
{
  if ! pgrep -f "qemu-system-aarch64.*${OVERLAY_DISK_PATH}" >/dev/null; then
    echo "The VM isn't running."
    return 0
  fi
  if [ ! -S "$MONITOR_SOCKET" ]; then
    echo "ERROR: the VM is running but its monitor socket ($MONITOR_SOCKET) is" >&2
    echo "missing, so it can't be shut down cleanly. Force it with --fkilld." >&2
    exit 1
  fi
  echo "Pressing the VM's power button..."
  if ! echo "system_powerdown" | as_root socat - UNIX-CONNECT:"$MONITOR_SOCKET" >/dev/null; then
    echo "ERROR: could not reach the VM's monitor (as root: passwordless sudo is" >&2
    echo "needed without a terminal)." >&2
    exit 1
  fi

  echo "Waiting up to ${STOP_TIMEOUT_S}s for the guest to power off..."
  local waited=0
  while pgrep -f "qemu-system-aarch64.*${OVERLAY_DISK_PATH}" >/dev/null; do
    if [ "$waited" -ge "$STOP_TIMEOUT_S" ]; then
      echo "ERROR: the guest didn't power off within ${STOP_TIMEOUT_S}s: it may be hung" >&2
      echo "or ignoring the power button. Shut it down from inside (sudo poweroff)," >&2
      echo "or force it with --fkilld." >&2
      exit 2
    fi
    sleep 1
    waited=$((waited + 1))
    if [ $((waited % 15)) -eq 0 ]; then
      echo "  still running after ${waited}s..."
    fi
  done
  echo "VM powered off after ${waited}s."

  commit_overlay || exit 1
}


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
    "\nIf no install is detected, a terminal session will be spawned"\
    "\nto setup the VM regardless of the provided flags."
  exit 0
}

verify_not_running() \
{
  # Safety check: refuse to commit if VM appears to be running
  if pgrep -f "qemu-system-aarch64.*${OVERLAY_DISK_PATH}" >/dev/null; then
    echo "ERROR: VM appears to be running. Stop it first before committing overlays." >&2
    exit 1
  fi
}

MODE="default"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --term | --startd | --stopd | --restartd | --fkilld | --clean | --launchd | --backup | --restore | --status) MODE="$1"; shift ;;
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
      # Start daemon
      add_networking
      add_usb_devices
      create_or_reuse_overlay interactive
      run_daemon
      ;;
    --stopd)
      # Call shutdown command
      run_shutdown
      ;;
    --restartd)
      # Call shutdown then start daemon (run_shutdown exits if it times out)
      run_shutdown
      add_networking
      add_usb_devices
      create_or_reuse_overlay interactive
      run_daemon
      ;;
    --term)
      # Run terminal session
      add_networking
      add_usb_devices
      create_or_reuse_overlay interactive
      run_terminal
      ;;
    --launchd)
      add_networking
      add_usb_devices
      create_or_reuse_overlay non-interactive
      run_launchd
      ;;
    --fkilld)
      # Kill all VM processes
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
    --status)
      PIDS=$(ps aux | grep '[q]emu-system-aarch64' | awk '{print $2}' || true)
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