# Saved overlays: sessions that didn't shut down (a power cut, an e-stop),
# kept so they can be recovered, and kept intact when another overlay is
# committed into the base disk under them. Sourced by run-vm.sh after its
# configuration.
# shellcheck shell=bash

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
