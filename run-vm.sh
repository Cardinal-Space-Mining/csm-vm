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
CPUS=6
RAM=12G
NET_IFACE="en0"
MAC="52:54:00:12:34:56"
# USB Whitelist: Non-storage USB devices must be whitelisted
# here to be passed to QEMU. All storage devices are passed by default.
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


# --- Functionality ------------------------------------------------------------
create_disk_file() \
{
  echo "Creating raw disk $DISK_FILE ($DISK_SIZE)..."
  qemu-img create -f raw $DISK_FILE $DISK_SIZE
}

add_iso_file() \
{
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
  QEMU_ARGS+=( -drive "file=${ISO_FILE},media=cdrom,if=virtio" )
  echo "Using ISO: $ISO_FILE"
}

add_usb_devices() \
{
  EXTERNAL_DISKS=$(diskutil list | grep "(external, physical)" | awk '{print $1}' || true)
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
    }' || true))
  DISK_DEVICES=$(system_profiler SPUSBDataType | awk '
    /Product ID:/ {match($0,/0x[0-9a-fA-F]+/); prod=substr($0,RSTART,RLENGTH)}
    /Vendor ID:/  {match($0,/0x[0-9a-fA-F]+/); vend=substr($0,RSTART,RLENGTH)}
    /BSD Name:/   {if(prod && vend){printf "%s:%s %s\n",vend,prod,$3; prod=""; vend=""}}')

  # Add all storage devices as "raw"
  for DISK in $EXTERNAL_DISKS; do
    diskutil unmountDisk force $DISK || true
    QEMU_ARGS+=( -drive "file=$DISK,if=virtio,format=raw" )
    echo "Added external storage device: $DISK"
  done
  # Add whitelisted non-storage devices the other way
  USB_DEVICES=("${USB_DEVICES[@]:-}")
  for DEV in "${USB_DEVICES[@]}"; do
    if echo "$DISK_DEVICES" | grep -q "^$DEV "; then
      echo "Skipping $DEV as generic USB device (listed as storage)"
      continue
    fi
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

run_qemu() \
{
  echo "--- RUNNING QEMU ---"
  echo "qemu-system-aarch64 ${QEMU_ARGS[@]}"
  echo "--------------------"
  exec sudo qemu-system-aarch64 "${QEMU_ARGS[@]}"
}


# --- Main Logic ---------------------------------------------------------------
if [ ! -f $DISK_FILE ]; then
  # Create disk file
  create_disk_file
  # Find or fetch Ubuntu Server ARM64 ISO and add to VM
  add_iso_file
else
  # Non-init run -- add usb devices
  add_usb_devices
fi

run_qemu
