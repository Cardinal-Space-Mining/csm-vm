# The ways of running the VM (in a terminal, as a daemon, under launchd) and of
# stopping it (its power button, or a force kill). Sourced by run-vm.sh after
# its configuration.
# shellcheck shell=bash

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
  if vm_is_running; then
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
  if vm_is_running; then
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
  if ! vm_is_running; then
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
  while vm_is_running; do
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
