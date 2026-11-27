# run-vm.sh's helpers: running things as root, who owns the disk files, and
# whether the VM is running. Sourced by run-vm.sh after its configuration.
# shellcheck shell=bash

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

qemu_pids() \
{
  ps aux | grep '[q]emu-system-aarch64' | awk '{print $2}' || true
}

# Whether the VM on this directory's overlay is running.
vm_is_running() \
{
  pgrep -f "qemu-system-aarch64.*${OVERLAY_DISK_PATH}" >/dev/null
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
  if vm_is_running; then
    echo "ERROR: VM appears to be running. Stop it first before committing overlays." >&2
    exit 1
  fi
}
