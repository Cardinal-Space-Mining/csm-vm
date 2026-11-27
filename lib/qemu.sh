# QEMU's arguments: the machine, the installer ISO, USB devices and networking.
# Sourced by run-vm.sh after its configuration (QEMU_ARGS uses it).
# shellcheck shell=bash

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
