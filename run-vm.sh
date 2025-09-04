#!/usr/bin/env bash
set -euo pipefail
trap 'echo "Error: Script failed at line $LINENO."; exit 1;' ERR

# --- Configuration ------------------------------------------------------------
# The installer ISO
ISO_URL="https://cdimage.ubuntu.com/ubuntu/releases/24.04/release/ubuntu-24.04.3-live-server-arm64.iso"
ISO_NAME="$(basename "$ISO_URL")"
# The VM storage disk (file)
DISK_FILE="ubuntu24-aarch64.raw"
DISK_SIZE="64G"
# Hardware configuration
CPUS=4
RAM=10G
NET_IFACE="en0"
MAC="52:54:00:12:34:56"
# USB Whitelist: Only devices here will be passed to QEMU
# Format: "vendorid:productid"
USB_WHITELIST=(
  "0x090c:0x1000"   # Samsung Flash Drive
  "0x16d0:0x117e"   # CANable2
)
# QEMU base args
QEMU_ARGS=(
  -machine virt
  -accel hvf
  -cpu host
  -smp "cpus=${CPUS},sockets=1,cores=${CPUS},threads=1"
  -m "$RAM"
  -drive "if=pflash,format=raw,file=/opt/homebrew/share/qemu/edk2-aarch64-code.fd,readonly=on"
  -drive "file=${DISK_FILE},if=virtio,format=raw"
  -device virtio-net-pci,netdev=net0,mac=$MAC
  -netdev vmnet-bridged,id=net0,ifname=$NET_IFACE
  -nographic
  -serial "mon:stdio"
  -device qemu-xhci,id=xhci
)

# --- Handle disk creation if necessary ----------------------------------------
if [ ! -f $DISK_FILE ]; then
  # Create disk file
  echo "Creating raw disk $DISK_FILE ($DISK_SIZE)..."
  qemu-img create -f raw $DISK_FILE $DISK_SIZE

  # Find or fetch Ubuntu Server ARM64 ISO
  ISO_FILE="$(ls ubuntu*.iso 2>/dev/null | head -n 1 || true)"

  if [ -z "${ISO_FILE:-}" ]; then
    echo "No Ubuntu ISO found locally. Attempting to download:"
    echo "  $ISO_URL"
    # check if URL is reachable
    if curl -sfI "$ISO_URL" >/dev/null; then
      curl -L -o "$ISO_NAME" "$ISO_URL"
      ISO_FILE="$ISO_NAME"
    else
      echo "ERROR: ISO not reachable at $ISO_URL" >&2
      exit 1
    fi
  fi

  # Sets the ISO as the instalation media for the VM
  QEMU_ARGS+=( -drive "file=${ISO_FILE},media=cdrom,if=virtio" )
  echo "Using ISO: $ISO_FILE"
else
  # Parse system_profiler and add only whitelisted USB devices
  USB_DEVICES=($(system_profiler SPUSBDataType 2>/dev/null | awk '
    /^[[:space:]]+[^\t].*:$/ {
      # Device name lines (indented, ending with colon)
      device=$0
      sub(/^[[:space:]]+/, "", device)
      sub(/:$/, "", device)
    }
    /Product ID:/ {
      match($0, /0x[0-9a-fA-F]+/)
      if (RSTART > 0) {
        prod = substr($0, RSTART, RLENGTH)
      }
    }
    /Vendor ID:/ {
      match($0, /0x[0-9a-fA-F]+/)
      if (RSTART > 0) {
        vend = substr($0, RSTART, RLENGTH)
      }
      if (device != "" && prod != "" && vend != "") {
        printf "%s:%s\n", vend, prod
        device=""; prod=""; vend=""
      }
    }'))
  for DEV in "${USB_DEVICES[@]}"; do
    for WHITELISTED in "${USB_WHITELIST[@]}"; do
      if [ "$DEV" = "$WHITELISTED" ]; then
          VID=$(echo "$DEV" | cut -d: -f1)
          PID=$(echo "$DEV" | cut -d: -f2)
          QEMU_ARGS+=( -device "usb-host,vendorid=${VID},productid=${PID},bus=xhci.0" )
          # echo "Added USB device $VID:$PID"
      fi
    done
  done
fi

echo "--- RUNNING QEMU ---"
echo "qemu-system-aarch64 ${QEMU_ARGS[@]}"
echo "--------------------"
exec qemu-system-aarch64 "${QEMU_ARGS[@]}"
