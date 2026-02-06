#!/usr/bin/env bash

set -euo pipefail
trap 'echo "Error: Script failed at line $LINENO."; exit 1;' ERR

SCRIPT=$(readlink -f "$0")
SCRIPTPATH=$(dirname "$SCRIPT")

# --- Configuration ------------------------------------------------------------
# The installer ISO
ISO_URL="https://cdimage.ubuntu.com/ubuntu/releases/24.04/release/ubuntu-24.04.3-live-server-arm64.iso"
ISO_NAME="$(basename "$ISO_URL")"
# The VM storage disk (file)
BASE_DISK_FILE="ubuntu24-aarch64-base.qcow2"
OVERLAY_DISK_FILE="ubuntu24-aarch64-overlay.qcow2"
BASE_DISK_PATH="$SCRIPTPATH/$BASE_DISK_FILE"
OVERLAY_DISK_PATH="$SCRIPTPATH/$OVERLAY_DISK_FILE"
DISK_SIZE="64G"
DISK_CACHE_MODE="none"
# Hardware configuration
CPUS=6
RAM=12G
NET_MODE="bridged"
ETH_IFACE="en0"
MAC="52:54:00:12:34:56"
# Socket for calling shutdown
MONITOR_SOCKET="/tmp/qemu-monitor.sock"
# USB Whitelist: Non-storage USB devices must be whitelisted here to be passed to QEMU.
# Use `system_profiler SPUSBHostDataType` to list devices and find vendor/product id.
# Format: "vendorid:productid"
USB_WHITELIST=(
  "0x16d0:0x117e"   # CANable2
  "0x045e:0x0b12"   # Xbox controller
  "0x0bda:0x8153"   # Realtek ethernet adapter
  "0x0e8d:0x7961"   # Brostrend AXE3000
)
# QEMU base args
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
create_and_use_disk_file() \
{
  # Create base qcow2 image instead of raw to support read only base + overlay
  echo "Creating base QCOW2 disk $BASE_DISK_PATH ($DISK_SIZE)..."
  qemu-img create -f qcow2 "$BASE_DISK_PATH" "$DISK_SIZE"

  # Use base disk directly for installation
  QEMU_ARGS+=( -drive "file=${BASE_DISK_PATH},if=virtio,format=qcow2,cache=${DISK_CACHE_MODE}" )
}

# Create or reuse overlay if it already exists
create_or_reuse_overlay() \
{
  if [ -f "$OVERLAY_DISK_PATH" ]; then
    echo "Found existing overlay: $OVERLAY_DISK_PATH. Checking integrity..."
    if qemu-img check "$OVERLAY_DISK_PATH" >/dev/null 2>&1; then
      echo "Overlay OK. Reusing."
    else
      echo "Overlay corrupted. Removing and creating new overlay."
      rm -f "$OVERLAY_DISK_PATH"
      qemu-img create -f qcow2 -b "$BASE_DISK_PATH" -F qcow2 "$OVERLAY_DISK_PATH"
    fi
  else
    echo "Creating new overlay for this session..."
    qemu-img create -f qcow2 -b "$BASE_DISK_PATH" -F qcow2 "$OVERLAY_DISK_PATH"
  fi

  # Add to QEMU_ARGS dynamically
  QEMU_ARGS+=( -drive "file=${OVERLAY_DISK_PATH},if=virtio,format=qcow2,cache=${DISK_CACHE_MODE}" )
}

add_iso_file() \
{
  ISO_FILE="$(ls $SCRIPTPATH/ubuntu*.iso 2>/dev/null | head -n 1 || true)"
  if [ -z "${ISO_FILE:-}" ]; then
    echo "No Ubuntu ISO found locally. Attempting to download..."
    echo "  $ISO_URL"
    # check if URL is reachable
    if curl -sfI "$ISO_URL" >/dev/null; then
      curl -L -o "$ISO_NAME" "$ISO_URL"
      ISO_FILE="$SCRIPTPATH/$ISO_NAME"
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
    diskutil unmountDisk force $DISK || true
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

  # Add whitelisted non-storage devices the other way
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
  # Configure netdev based on NET_MODE. The virtio-net-pci device is added
  # here so we can decide whether to pass a bridged interface (Ethernet)
  # or use vmnet-shared (Wi-Fi). When using wifi we must NOT pass the
  # bridged ifname or any host interface.
  if [ "$NET_MODE" = "wifi" ]; then
    QEMU_ARGS+=( -netdev vmnet-shared,id=net0 )
    QEMU_ARGS+=( -device "virtio-net-pci,netdev=net0,mac=$MAC" )
    # Attach virtio-net-pci to the net0 backend
  else
    QEMU_ARGS+=( -netdev "vmnet-bridged,id=net0,ifname=$ETH_IFACE" )
    QEMU_ARGS+=( -device "virtio-net-pci,netdev=net0,mac=$MAC" )
  fi
}

commit_overlay() \
{
  if [ -f "$OVERLAY_DISK_PATH" ]; then
    echo "Committing overlay to base..."
    if qemu-img commit "$OVERLAY_DISK_PATH"; then
      echo "Overlay committed successfully."
      rm -f "$OVERLAY_DISK_PATH"
    else
      echo "Warning: commit failed; overlay preserved for manual recovery."
    fi
  fi
}


# --- Execution Modes ----------------------------------------------------------
run_terminal() \
{
  QEMU_ARGS+=(-nographic -serial "mon:stdio")

  echo "--- RUNNING QEMU (TERMINAL) ---"
  echo "qemu-system-aarch64 ${QEMU_ARGS[@]}"
  echo "--------------------"
  
  sudo qemu-system-aarch64 "${QEMU_ARGS[@]}"

  commit_overlay
}

run_daemon() \
{
  QEMU_ARGS+=(-display none)

  echo "--- RUNNING QEMU (DAEMON) ---"
  echo "nohup qemu-system-aarch64 ${QEMU_ARGS[@]} >/dev/null 2>&1 &"
  echo "-----------------------------"
  sudo -v
  nohup sudo qemu-system-aarch64 "${QEMU_ARGS[@]}" >/dev/null 2>&1 &
}

run_shutdown() \
{
  if [ -S "$MONITOR_SOCKET" ]; then
    echo "system_powerdown" | sudo socat - UNIX-CONNECT:"$MONITOR_SOCKET" || true

    # Wait until QEMU process using this overlay exits
    echo "Waiting for VM to exit..."
    while pgrep -f "qemu-system-aarch64.*${OVERLAY_DISK_PATH}" >/dev/null; do
      sleep 1
    done

    commit_overlay
  else
    echo "No monitor socket found ($MONITOR_SOCKET)"
  fi
}


# --- Main Logic ---------------------------------------------------------------
MODE="${1:-default}"

if [ $MODE = "--help" ]; then
  echo -e "Usage: run-vm.sh <OPTION>"\
    "\nOPTIONS:"\
    "\n --help     : Print this help message."\
    "\n --wifi     : Use Wi-Fi (vmnet-shared) instead of bridged networking."\
    "\n --startd   : Start VM in headless daemon mode."\
    "\n --stopd    : Attempt to shutdown a headless daemon VM."\
    "\n --restartd : Attempt to restart a headless daemon VM."\
    "\nRunning with no options runs the VM with a terminal attached to the current session."
  exit 0
fi

# Handle wifi flag
if [ "$MODE" = "--wifi" ]; then
  NET_MODE="wifi"
  MODE="default"
fi

if [ ! -f "$BASE_DISK_PATH" ]; then
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
      create_or_reuse_overlay
      run_daemon
      ;;
    --stopd)
      # Call shutdown command
      run_shutdown
      ;;
    --restartd)
      # Call shutdown then start daemon
      run_shutdown
      add_networking
      add_usb_devices
      create_or_reuse_overlay
      run_daemon
      ;;
    *)
      # Default behavior -- run terminal session
      add_networking
      add_usb_devices
      create_or_reuse_overlay
      run_terminal
      ;;
  esac
fi
