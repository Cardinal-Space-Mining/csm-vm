#!/usr/bin/env bash


# Check for dependencies
# 1 qemu
#   brew install qemu
# 2 drive (.raw)
#   make a raw drive
#   first time build build with ISO
#   lauch from raw with qemu presets, changeable from CLI
# 3 iso
#   curl image from internet



set -euo pipefail
trap 'echo "Error: Script failed at line $LINENO."; exit 1;' ERR

# TODO
# Usage: ./csm-qemu-setup.sh <project_name>
# if [ -z "$1" ]; then
#     echo "Usage: $0 <project_name>"
#     exit 1
# fi

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
NET_IFACE="en0"           # change if your primary NIC is different (check with #ifconfig)
MAC="52:54:00:12:34:56"   # static MAC so DHCP always gives the same IP

# Full args list
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
)

# --- Handle disk creation  if necessar ----------------------------------------
if [ ! -f $DISK_FILE ]; then
  echo "Creating raw disk $DISK_FILE ($DISK_SIZE)..."
  qemu-img create -f raw $DISK_FILE $DISK_SIZE

  # --- Find or fetch Ubuntu Server ARM64 ISO ----------------------------------
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

  echo "Using ISO: $ISO_FILE"

  # --- Sets the ISO as the instalation media for the VM
  QEMU_ARGS+=( -drive "file=${ISO_FILE},media=cdrom,if=virtio" )
fi

exec qemu-system-aarch64 "${QEMU_ARGS[@]}"
