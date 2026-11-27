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

# --- Saved overlays (sessions that didn't shut down) ---
# The legacy single "backup" slot counts as one too.
saved_overlays() \
{
  local prefix="${OVERLAY_DISK_PATH%.qcow2}"
  ls -1tr "$prefix".saved-*.qcow2 "${prefix}.backup.qcow2" 2>/dev/null || true
}

# Move the current overlay aside as a saved session (newest SAVED_OVERLAYS_KEPT
# are kept). Its name says when it was last written: when that session ended.
save_overlay() \
{
  local stamp target n=1
  stamp=$(stat -f %Sm -t %Y%m%d-%H%M%S "$OVERLAY_DISK_PATH")
  target="${OVERLAY_DISK_PATH%.qcow2}.saved-${stamp}.qcow2"
  while [ -e "$target" ]; do
    target="${OVERLAY_DISK_PATH%.qcow2}.saved-${stamp}-${n}.qcow2"
    n=$((n + 1))
  done
  mv "$OVERLAY_DISK_PATH" "$target"
  rm -f "$UNCLEAN_MARKER" "$RECOVERED_MARKER"
  give_to_owner "$target"
  echo "Saved the previous session's overlay as $(basename "$target")" \
    "($(du -h "$target" | cut -f1)): recover it with --recover $(basename "$target")."
}

prune_saved_overlays() \
{
  local all count
  all=$(saved_overlays)
  count=$(printf '%s\n' "$all" | grep -c . || true)
  while [ "$count" -gt "$SAVED_OVERLAYS_KEPT" ]; do
    local oldest
    oldest=$(printf '%s\n' "$all" | head -1)
    rm -f "$oldest"
    echo "Deleted the oldest saved overlay, $(basename "$oldest") (keeping $SAVED_OVERLAYS_KEPT)."
    all=$(printf '%s\n' "$all" | tail -n +2)
    count=$((count - 1))
  done
}

# Ranges an image holds itself, not its backing file ("start length" in bytes,
# one per line): what its session wrote, and what it zeroed (TRIM) as well.
own_ranges() \
{
  qemu-img map -f qcow2 --output=json "$1" \
    | sed -n 's/.*"start": *\([0-9]*\), *"length": *\([0-9]*\), *"depth": *0,.*/\1 \2/p'
}

# Ranges of $1 ("start length" lines) not covered by those of $2.
subtract_ranges() \
{
  # (FILENAME, not NR == FNR: the cuts file may be empty)
  awk 'BEGIN { n = 0 }
       FILENAME == ARGV[1] { cut_start[n] = $1; cut_end[n] = $1 + $2; n++; next }
       { start = $1; end = $1 + $2
         for (i = 0; i < n && start < end; i++) {
           if (cut_end[i] <= start || cut_start[i] >= end) continue
           if (cut_start[i] > start) print start, cut_start[i] - start
           start = cut_end[i]
         }
         if (start < end) print start, end - start }' "$2" "$1"
}

# A saved overlay only holds what its session changed; the rest it reads from
# the base disk. Committing another overlay changes the base under it, so
# first copy into each saved overlay the base data the commit will replace
# (where the saved overlay doesn't hold its own). Costs about what the commit
# itself does. A failure halfway is harmless: what was copied is what the
# saved overlay read from the base anyway.
protect_saved_overlays() \
{
  local saved work changed
  [ -n "$(saved_overlays)" ] || return 0
  work=$(mktemp -d)
  own_ranges "$OVERLAY_DISK_PATH" >"$work/changed"
  for saved in $(saved_overlays); do
    echo "Keeping saved overlay $(basename "$saved") intact..."
    own_ranges "$saved" >"$work/saved"
    subtract_ranges "$work/changed" "$work/saved" >"$work/copy"
    if ! copy_base_ranges "$saved" "$work/copy" "$work/chunk"; then
      echo "ERROR: could not protect $(basename "$saved"); not committing." >&2
      rm -rf "$work"
      return 1
    fi
  done
  rm -rf "$work"
}

# Copy the base disk's data for the ranges in file $2 into image $1, in chunks
# of at most 256 MiB (via the temporary file $3). A range of the base is read
# through the raw driver's offset/size window (qemu-img dd can't seek: it
# refuses a skip past count * bs).
copy_base_ranges() \
{
  local saved="$1" ranges="$2" chunk="$3" start length size
  local max=$((256 * 1024 * 1024))
  while read -r start length; do
    while [ "$length" -gt 0 ]; do
      size=$length
      [ "$size" -gt "$max" ] && size=$max
      rm -f "$chunk"
      qemu-img convert -O raw --image-opts \
        "driver=raw,offset=$start,size=$size,file.driver=qcow2,file.file.filename=$BASE_DISK_PATH" \
        "$chunk" || return 1
      if [ -w "$saved" ]; then
        qemu-io -f qcow2 -c "write -q -s $chunk $start $size" "$saved" || return 1
      else
        as_root qemu-io -f qcow2 -c "write -q -s $chunk $start $size" "$saved" || return 1
      fi
      start=$((start + size))
      length=$((length - size))
    done
  done <"$ranges"
}

# Make a saved overlay the VM's overlay again (the current one, if any, is saved
# first), so the next start with --overlay reuse boots that session.
recover_saved() \
{
  local name="$1" path
  path="$SCRIPTPATH/$(basename "$name")"
  if ! saved_overlays | grep -qxF "$path"; then
    echo "ERROR: no saved overlay $name. Saved: $(saved_overlays | xargs -n1 basename 2>/dev/null | tr '\n' ' ')" >&2
    exit 1
  fi
  verify_not_running
  lock_commit
  if [ -f "$OVERLAY_DISK_PATH" ]; then
    save_overlay
  fi
  mv "$path" "$OVERLAY_DISK_PATH"
  # A session that didn't shut down, recovered (for its logs, say): stopping it
  # won't commit it (auto_commit); --clean does
  touch "$UNCLEAN_MARKER" "$RECOVERED_MARKER"
  give_to_owner "$UNCLEAN_MARKER" "$RECOVERED_MARKER"
  unlock_commit
  prune_saved_overlays
  echo "Recovered $(basename "$path"): start the VM with --overlay reuse to boot that session."
  echo "Stopping it won't commit it: commit it with --clean if you want it, or discard it."
}

forget_saved() \
{
  local name="$1" path
  path="$SCRIPTPATH/$(basename "$name")"
  if ! saved_overlays | grep -qxF "$path"; then
    echo "ERROR: no saved overlay $name." >&2
    exit 1
  fi
  rm -f "$path"
  echo "Deleted $(basename "$path")."
}

# A fresh, empty overlay on the base disk. CREATED_OVERLAY tells run_daemon it
# may remove it again if QEMU fails to start (it holds nothing yet).
CREATED_OVERLAY=0
new_overlay() \
{
  rm -f "$UNCLEAN_MARKER" "$RECOVERED_MARKER"
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

  # The overlay may be being committed (the VM just powered itself off)
  lock_commit
  unlock_commit

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
            rm -f "$OVERLAY_DISK_PATH" "$RECOVERED_MARKER"
            new_overlay
            ;;
          *)
            echo "Reusing existing overlay."
            ;;
        esac
      elif [ "$LAUNCHD_OVERLAY" = reuse ]; then
        echo "Reusing the previous session's overlay (LAUNCHD_OVERLAY=reuse)."
      else
        # Non-interactive (launchd): keep the session, boot the base disk
        echo "An overlay from a previous session is here (it didn't shut down)."
        save_overlay
        prune_saved_overlays
        new_overlay
      fi
    else
      echo "Overlay corrupted (qemu-img check failed): saving it anyway, creating a new one."
      save_overlay
      prune_saved_overlays
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
  if [ -n "$(saved_overlays)" ]; then
    echo "ERROR: saved overlays depend on the current base disk and would be unreadable" >&2
    echo "after a restore. Recover what you need from them, then delete them (--forget):" >&2
    saved_overlays | xargs -n1 basename >&2
    exit 1
  fi
  if [ ! -f "$BASE_DISK_BACKUP_PATH" ]; then
    echo "ERROR: No backup found at $BASE_DISK_BACKUP_PATH" >&2
    exit 1
  fi
  echo "Restoring base disk from backup..."
  copy_with_progress "$BASE_DISK_BACKUP_PATH" "$BASE_DISK_PATH"
  rm -f "$OVERLAY_DISK_PATH" "$UNCLEAN_MARKER" "$RECOVERED_MARKER"
  echo "Restore complete. Previous overlay discarded."
}

# One commit at a time: when the VM exits, both the watcher (run_daemon) and
# --stopd commit, and a start must not open an overlay being committed. The
# lock is a directory (mkdir is atomic) holding its owner's PID; one left by a
# commit that was killed is taken over.
lock_commit() \
{
  local me holder waited=0
  me=$(sh -c 'echo $PPID')  # this (sub)shell's PID: bash 3.2 has no BASHPID
  until mkdir "$COMMIT_LOCK" 2>/dev/null; do
    holder=$(cat "$COMMIT_LOCK/pid" 2>/dev/null || true)
    if [ -n "$holder" ] && ! ps -p "$holder" >/dev/null 2>&1; then
      rm -rf "$COMMIT_LOCK"
      continue
    fi
    if [ "$waited" -eq 0 ]; then
      echo "Waiting for a commit of the overlay to finish..."
    fi
    sleep 1
    waited=$((waited + 1))
  done
  echo "$me" > "$COMMIT_LOCK/pid"
  give_to_owner "$COMMIT_LOCK" "$COMMIT_LOCK/pid"
}

unlock_commit() \
{
  rm -rf "$COMMIT_LOCK"
}

# The commit after a clean shutdown, except for a recovered session (it's
# committed only on request, with --clean).
auto_commit() \
{
  if [ -f "$RECOVERED_MARKER" ]; then
    echo "Not committing: this overlay is a recovered session. Commit it with --clean,"
    echo "or discard it when you start the VM next."
    return 0
  fi
  commit_overlay
}

# Returns 1 if the commit fails (the overlay is kept for manual recovery).
commit_overlay() \
{
  [ -f "$OVERLAY_DISK_PATH" ] || return 0
  lock_commit
  if [ ! -f "$OVERLAY_DISK_PATH" ]; then
    unlock_commit
    echo "The overlay was already committed."
    return 0
  fi
  if [ -f "$UNCLEAN_MARKER" ]; then
    echo "WARNING: this overlay is from a VM that was force-stopped: the guest"
    echo "didn't shut down, so files written just before may be incomplete."
  fi
  if ! protect_saved_overlays; then
    unlock_commit
    return 1
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
    rm -f "$OVERLAY_DISK_PATH" "$UNCLEAN_MARKER" "$RECOVERED_MARKER"
    unlock_commit
  else
    unlock_commit
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
  
  : >"$QEMU_LOG"
  local status=0
  sudo qemu-system-aarch64 "${QEMU_ARGS[@]}" || status=$?
  echo "--- QEMU exited with status $status at $(date '+%Y-%m-%d %H:%M:%S') ---" >>"$QEMU_LOG"

  auto_commit || exit 1
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
  : >"$QEMU_LOG"
  give_to_owner "$QEMU_LOG"
  # A watcher runs QEMU and handles its exit (qemu_exited). Like nohup it
  # ignores only SIGHUP: QEMU inherits ignored signals, and must still stop
  # on SIGTERM when macOS shuts down.
  (
    trap '' HUP
    status=0
    sudo qemu-system-aarch64 "${QEMU_ARGS[@]}" || status=$?
    qemu_exited "$status"
  ) </dev/null >>"$QEMU_LOG" 2>&1 &
  local watcher=$!

  # QEMU fails fast on bad arguments or missing permissions: report it.
  sleep 3
  if pgrep -f "qemu-system-aarch64.*${OVERLAY_DISK_PATH}" >/dev/null; then
    echo "VM started. Serial console: ${SERIAL_SOCKET}"
  else
    echo "ERROR: QEMU exited right away. Its output ($QEMU_LOG):" >&2
    # (without the libusb warnings QEMU prints for every passed-through device)
    grep -v "libusb_kernel_driver_active" "$QEMU_LOG" | tail -n 20 >&2 || true
    # The guest never ran: the watcher's "unclean" mark doesn't apply
    wait "$watcher" || true
    rm -f "$UNCLEAN_MARKER"
    # An overlay made by this start holds nothing yet: don't leave it behind
    if [ "$CREATED_OVERLAY" -eq 1 ]; then
      rm -f "$OVERLAY_DISK_PATH"
      echo "Removed the empty overlay this start created." >&2
    fi
    exit 1
  fi
}

# QEMU (daemon mode) exited. A guest that powered itself off (sudo poweroff)
# leaves QEMU's exit code 0: commit its overlay, as --stopd would. QEMU
# killed or crashed: mark the overlay unclean. (A SIGTERM, e.g. macOS shutting
# down, also exits 0, but QEMU logs "terminating on signal".)
qemu_exited() \
{
  local status=$1
  echo "--- QEMU exited with status $status at $(date '+%Y-%m-%d %H:%M:%S') ---"
  [ -f "$OVERLAY_DISK_PATH" ] || return 0
  if [ "$status" -eq 0 ] && ! grep -q "terminating on signal" "$QEMU_LOG"; then
    echo "The guest powered off."
    auto_commit || true
  else
    touch "$UNCLEAN_MARKER"
    give_to_owner "$UNCLEAN_MARKER"
    echo "The guest didn't shut down: its overlay is marked unclean."
  fi
}

# An overlay whose VM didn't shut down is unclean even if nothing marked it:
# a power cut or e-stop (QEMU's exit was never recorded in its log), or the mac
# shutting down with the VM running (QEMU logs "terminating on signal", and the
# watcher died with it).
note_unclean_leftover() \
{
  [ -f "$OVERLAY_DISK_PATH" ] && [ ! -f "$UNCLEAN_MARKER" ] && [ -f "$QEMU_LOG" ] \
    || return 0
  if pgrep -f "qemu-system-aarch64.*${OVERLAY_DISK_PATH}" >/dev/null; then
    return 0
  fi
  if grep -q "terminating on signal" "$QEMU_LOG" \
      || ! grep -q "^--- QEMU exited" "$QEMU_LOG"; then
    touch "$UNCLEAN_MARKER"
    give_to_owner "$UNCLEAN_MARKER"
    echo "Note: the VM didn't shut down last time (power cut, e-stop, the mac shutting"
    echo "down with it running, or a kill): its overlay is marked unclean."
  fi
}

run_launchd() \
{
  QEMU_ARGS+=(-display none -serial "unix:${SERIAL_SOCKET},server,nowait")

  echo "--- RUNNING QEMU (LAUNCHD) ---"
  echo "qemu-system-aarch64 ${QEMU_ARGS[@]} >>$QEMU_LOG 2>&1"
  echo "------------------------------"

  : >"$QEMU_LOG"
  give_to_owner "$QEMU_LOG"
  local status=0
  qemu-system-aarch64 "${QEMU_ARGS[@]}" >>"$QEMU_LOG" 2>&1 || status=$?
  # Commits only if the guest powered off (as in daemon mode)
  qemu_exited "$status" >>"$QEMU_LOG" 2>&1
  tail -n 4 "$QEMU_LOG"
}

press_power_button() \
{
  echo "system_powerdown" | as_root socat - UNIX-CONNECT:"$MONITOR_SOCKET" >/dev/null
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
  if ! press_power_button; then
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
    # A press while the guest boots is lost (nothing listens for the button
    # before systemd-logind starts), so keep pressing.
    if [ $((waited % POWER_PRESS_PERIOD_S)) -eq 0 ]; then
      echo "  still running after ${waited}s: pressing the power button again"
      press_power_button || true
    fi
  done
  echo "VM powered off after ${waited}s."

  auto_commit || exit 1
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
    "\n --list-saved : List saved overlays (sessions that didn't shut down)."\
    "\n --recover F  : Make saved overlay F the VM's overlay (the current one is saved"\
    "\n                first); start with --overlay reuse to boot that session."\
    "\n --forget F   : Delete saved overlay F."\
    "\nIf no install is detected, a terminal session will be spawned"\
    "\nto setup the VM regardless of the provided flags."
  exit 0
}

# Never two VMs at once (autostart and a start from Orca right after boot).
refuse_if_running() \
{
  local pids
  pids=$(qemu_pids)
  if [ -n "$pids" ]; then
    echo "ERROR: a VM is already running (PID $(echo $pids)): stop it first." >&2
    exit 1
  fi
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
      # Start daemon
      refuse_if_running
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
      refuse_if_running
      add_networking
      add_usb_devices
      create_or_reuse_overlay interactive
      run_daemon
      ;;
    --term)
      # Run terminal session
      refuse_if_running
      add_networking
      add_usb_devices
      create_or_reuse_overlay interactive
      run_terminal
      ;;
    --launchd)
      refuse_if_running
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