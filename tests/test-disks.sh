#!/usr/bin/env bash
# Tests run-vm.sh's disk handling (commits, saved sessions, recovery, the
# commit lock) on small synthetic disk images. No VM is started and the real
# disks are never touched: each test runs a copy of run-vm.sh and lib/ in a
# temporary directory, so this is safe while the VM runs.
#
#   ./tests/test-disks.sh          (needs qemu-img and qemu-io: brew install qemu)

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
MIB=$((1024 * 1024))
NUM_PASSED=0
NUM_FAILED=0
VM="$WORK/vm"
BASE="$VM/ubuntu-aarch64-base.qcow2"
OVERLAY="$VM/ubuntu-aarch64-overlay.qcow2"


# --- Helpers ------------------------------------------------------------------
check() \
{
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    NUM_PASSED=$((NUM_PASSED + 1))
  else
    NUM_FAILED=$((NUM_FAILED + 1))
    echo "FAIL: $label"
  fi
}

# A fresh copy of the scripts, with a 16 MiB base disk holding 0x11 everywhere.
fresh() \
{
  rm -rf "$VM"
  mkdir -p "$VM/lib"
  cp "$REPO/run-vm.sh" "$VM/"
  cp "$REPO"/lib/*.sh "$VM/lib/"
  qemu-img create -q -f qcow2 "$BASE" 16M
  fill "$BASE" 0x11 0 16
}

# An empty overlay (or another file) on the base disk.
overlay() \
{
  qemu-img create -q -f qcow2 -b "$BASE" -F qcow2 "${1:-$OVERLAY}"
}

# fill IMAGE PATTERN START_MIB LENGTH_MIB (pattern 0 writes zeroes, as TRIM does)
fill() \
{
  if [ "$2" = 0 ]; then
    qemu-io -f qcow2 -c "write -q -z $(($3 * MIB)) $(($4 * MIB))" "$1"
  else
    qemu-io -f qcow2 -c "write -q -P $2 $(($3 * MIB)) $(($4 * MIB))" "$1"
  fi
}

# holds IMAGE PATTERN START_MIB LENGTH_MIB: the image reads that pattern there
holds() \
{
  qemu-io -f qcow2 -r -c "read -q -P $2 $(($3 * MIB)) $(($4 * MIB))" "$1" \
    >/dev/null 2>&1
}

run_vm() \
{
  "$VM/run-vm.sh" "$@" </dev/null
}

# Run a command with run-vm.sh's configuration and libraries loaded, as its
# main logic would (for functions there's no option for).
with_libs() \
{
  (
    cd "$VM"
    SCRIPTPATH="$VM"
    eval "$(sed '/^# --- Libraries/,$d; /^SCRIPT=/d; /^SCRIPTPATH=/d' run-vm.sh)"
    BASE_DISK_PATH="$BASE"
    OVERLAY_DISK_PATH="$OVERLAY"
    UNCLEAN_MARKER="$OVERLAY.unclean"
    COMMIT_LOCK="$OVERLAY.lock"
    RECOVERED_MARKER="$OVERLAY.recovered"
    for lib in common overlay saved qemu modes; do
      source "lib/$lib.sh"
    done
    "$@"
  )
}

saved_names() \
{
  ls "$VM" | grep '\.saved-' || true
}


# --- Committing ---------------------------------------------------------------
fresh
overlay
fill "$OVERLAY" 0x33 0 3
run_vm --clean >/dev/null
check "--clean commits the overlay into the base" holds "$BASE" 0x33 0 3
check "--clean leaves the rest of the base alone" holds "$BASE" 0x11 3 13
check "--clean removes the overlay" test ! -e "$OVERLAY"
check "--clean with nothing to commit succeeds" run_vm --clean


# --- Saved overlays stay intact when another overlay is committed -------------
fresh
# Session A wrote [1, 2) and trimmed [2, 3); session B wrote nothing.
overlay "$VM/ubuntu-aarch64-overlay.saved-20260101-000000.qcow2"
overlay "$VM/ubuntu-aarch64-overlay.saved-20260102-000000.qcow2"
A="$VM/ubuntu-aarch64-overlay.saved-20260101-000000.qcow2"
B="$VM/ubuntu-aarch64-overlay.saved-20260102-000000.qcow2"
fill "$A" 0x22 1 1
fill "$A" 0 2 1
# The current session writes [0, 4) and [8, 9), and is committed
overlay
fill "$OVERLAY" 0x33 0 4
fill "$OVERLAY" 0x33 8 1
run_vm --clean >/dev/null
check "the base has the commit" holds "$BASE" 0x33 0 4
check "a saved session keeps the base as it was under it" holds "$A" 0x11 0 1
check "a saved session keeps what it wrote" holds "$A" 0x22 1 1
check "a saved session keeps what it trimmed" holds "$A" 0x00 2 1
check "a saved session keeps the base past its own data" holds "$A" 0x11 3 1
check "a saved session keeps a separate committed range" holds "$A" 0x11 8 1
check "a saved session keeps what the commit didn't touch" holds "$A" 0x11 9 7
check "an empty saved session keeps the old base" holds "$B" 0x11 0 16

# More than 256 MiB of changes is copied in chunks
fresh
qemu-img resize -q "$BASE" 600M
overlay "$A"
overlay
fill "$OVERLAY" 0x44 0 520
run_vm --clean >/dev/null
check "a commit over the chunk size keeps the saved session" holds "$A" 0x11 0 16
check "...to the end of the commit" holds "$A" 0x00 516 4
check "...and the base has the commit" holds "$BASE" 0x44 0 520


# --- Range arithmetic ---------------------------------------------------------
ranges_test() \
{
  printf '%s\n' $1 | paste -d' ' - - >"$WORK/from"
  printf '%s\n' $2 | paste -d' ' - - >"$WORK/cuts"
  [ "$(with_libs subtract_ranges "$WORK/from" "$WORK/cuts" | tr '\n' ' ')" = "$3" ]
}
: >"$WORK/empty"
check "subtract nothing" ranges_test "0 100" "" "0 100 "
check "subtract the middle" ranges_test "0 100" "10 20" "0 10 30 70 "
check "subtract the start" ranges_test "0 100" "0 10" "10 90 "
check "subtract the end" ranges_test "0 100" "90 10" "0 90 "
check "subtract everything" ranges_test "0 100" "0 100" ""
check "subtract more than everything" ranges_test "10 10" "0 100" ""
check "subtract two" ranges_test "0 100" "10 10 50 10" "0 10 20 30 60 40 "
check "subtract from two" ranges_test "0 10 20 10" "5 20" "0 5 25 5 "


# --- Sessions that didn't shut down -------------------------------------------
fresh
overlay
fill "$OVERLAY" 0x55 0 1
echo "qemu-system-aarch64: terminating on signal 15" >"$VM/qemu.log"
run_vm --list-saved >/dev/null
check "an overlay QEMU logged a signal for is marked unclean" test -e "$OVERLAY.unclean"

fresh
overlay
echo "nothing: the power was cut" >"$VM/qemu.log"
run_vm --list-saved >/dev/null
check "an overlay without QEMU's exit logged is marked unclean" test -e "$OVERLAY.unclean"

fresh
overlay
echo "--- QEMU exited with status 0 at 2026-01-01 00:00:00 ---" >"$VM/qemu.log"
run_vm --list-saved >/dev/null
check "an overlay whose VM exited cleanly isn't marked" test ! -e "$OVERLAY.unclean"

# Autostart (launchd) saves a leftover overlay and boots a fresh one
fresh
overlay
fill "$OVERLAY" 0x55 0 1
with_libs create_or_reuse_overlay non-interactive >/dev/null
check "autostart saves the leftover overlay" test "$(saved_names | wc -l)" -eq 1
check "...with its data" holds "$VM/$(saved_names)" 0x55 0 1
check "...and boots a fresh overlay" holds "$OVERLAY" 0x11 0 1
check "the base isn't changed" holds "$BASE" 0x11 0 16

# Only the newest SAVED_OVERLAYS_KEPT are kept
fresh
for day in 01 02 03; do
  overlay "$VM/ubuntu-aarch64-overlay.saved-202601${day}-000000.qcow2"
  touch -t "202601${day}0000" "$VM/ubuntu-aarch64-overlay.saved-202601${day}-000000.qcow2"
done
with_libs eval 'SAVED_OVERLAYS_KEPT=2; prune_saved_overlays' >/dev/null
check "pruning deletes the oldest saved overlay" \
  test "$(saved_names | tr '\n' ' ')" = \
  "ubuntu-aarch64-overlay.saved-20260102-000000.qcow2 ubuntu-aarch64-overlay.saved-20260103-000000.qcow2 "


# --- Recovering and forgetting ------------------------------------------------
fresh
overlay "$A"
fill "$A" 0x66 0 1
overlay
fill "$OVERLAY" 0x77 0 1
check "--recover of a missing session fails" eval '! run_vm --recover nope.qcow2'
run_vm --recover "$(basename "$A")" >/dev/null
check "--recover makes the session the overlay" holds "$OVERLAY" 0x66 0 1
check "...and saves the overlay that was there" \
  test "$(saved_names | wc -l)" -eq 1
check "...with its data" holds "$VM/$(saved_names)" 0x77 0 1
check "...and marks it recovered" test -e "$OVERLAY.recovered"
with_libs auto_commit >/dev/null
check "a recovered session isn't committed at shutdown" holds "$BASE" 0x11 0 1
check "...and stays" test -e "$OVERLAY"
cp "$BASE" "$VM/ubuntu-aarch64-base.backup.qcow2"
check "--restore refuses while sessions are saved" eval '! run_vm --restore'
run_vm --forget "$(saved_names)" >/dev/null
check "--forget deletes a saved session" test -z "$(saved_names)"
run_vm --clean >/dev/null
check "--clean commits a recovered session" holds "$BASE" 0x66 0 1
check "...and clears its marks" test ! -e "$OVERLAY.recovered"


# --- The commit lock ----------------------------------------------------------
fresh
overlay
mkdir "$OVERLAY.lock"
echo 999999 >"$OVERLAY.lock/pid"  # a commit that was killed
check "a stale lock is taken over" run_vm --clean
check "...and released" test ! -e "$OVERLAY.lock"

fresh
overlay
fill "$OVERLAY" 0x88 0 1
sleep 3 &
holder=$!
mkdir "$OVERLAY.lock"
echo "$holder" >"$OVERLAY.lock/pid"
( sleep 2; rm -rf "$OVERLAY.lock" ) &
started_s=$(date +%s)
run_vm --clean >/dev/null
check "a commit waits for one in progress" test $(($(date +%s) - started_s)) -ge 2
check "...then commits" holds "$BASE" 0x88 0 1
wait


# --- Summary ------------------------------------------------------------------
echo "$NUM_PASSED passed, $NUM_FAILED failed"
[ "$NUM_FAILED" -eq 0 ]
