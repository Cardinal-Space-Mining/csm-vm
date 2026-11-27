# The VM's disks. It boots an overlay on the read-only base disk; a clean
# shutdown commits the overlay into the base, and the overlay of a session
# that didn't shut down is kept (saved.sh). Sourced by run-vm.sh after its
# configuration.
# shellcheck shell=bash

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
