#!/usr/bin/env bash
set -eu
umask 077

########################################
# Platform safeguard: macOS only
########################################
if [ "$(uname -s)" != "Darwin" ]; then
  echo "ERROR: This script is macOS-only."
  echo "Refusing to run on: $(uname -s)"
  exit 1
fi

########################################
# Resolve disk root (script location)
########################################
DISK_ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$DISK_ROOT/pull.conf"

NAS="flashstor"
DATE="$(date +%F)"
TRASH_BASE="$DISK_ROOT/trash/$DATE"

########################################
# Logging (per run)
########################################
LOGDIR="$DISK_ROOT/logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/pull-$(date +%F-%H%M%S).log"

# Tee stdout+stderr to log file
exec > >(tee -a "$LOGFILE") 2>&1

########################################
# Partial transfer handling
########################################
PARTIAL_DIR="$DISK_ROOT/.rsync-partial"
mkdir -p "$PARTIAL_DIR"

########################################
# Safety checks
########################################
case "$DISK_ROOT" in
  /Volumes/*) ;;
  *)
    echo "ERROR: Script must be run from an external volume"
    exit 1
    ;;
esac

if [ ! -f "$CONFIG" ]; then
  echo "ERROR: Missing pull.conf on disk root"
  exit 1
fi

########################################
# Lock (per disk)
########################################
LOCKFILE="$DISK_ROOT/.pull.lock.pid"

if [ -f "$LOCKFILE" ]; then
  OLD_PID="$(cat "$LOCKFILE" 2>/dev/null || true)"
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Pull already running for this disk"
    exit 0
  fi
fi

echo "$$" > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT INT TERM

########################################
# rsync options
########################################
RSYNC_OPTS=(
-r
-l
-h
--info=stats2
--iconv=utf-8-mac,utf-8
--size-only
--omit-dir-times
--no-perms
--no-owner
--no-group
--partial
--partial-dir="$PARTIAL_DIR"
--delete-delay
--delete-excluded
--backup
--exclude=.DS_Store
--exclude=._*
--exclude=.Spotlight-V100
--exclude=.Trashes
--exclude=.TemporaryItems
--exclude=.fseventsd
)

#######################################
# Dry-run normalization
#######################################
DRY_RUN=0

# Environment variable variants
if [ "${DRY_RUN:-}" = "1" ] || [ "${DRYRUN:-}" = "1" ] || [ "${DRYRUN:-}" = "true" ]; then
  DRY_RUN=1
fi

# CLI flag variants
for arg in "$@"; do
  case "$arg" in
    --dry-run|--dryrun|--dry_run|-n)
      DRY_RUN=1
      ;;
  esac
done

########################################
# Dry-run support
########################################
if [ "$DRY_RUN" -eq 1 ]; then
  RSYNC_OPTS+=( -n )
  echo "DRY RUN MODE ENABLED"
fi

########################################
# Prepare trash root
########################################
mkdir -p "$TRASH_BASE"

########################################
# Process pull config
########################################
while IFS='|' read -r SRC DST; do
  # Trim whitespace
  SRC="$(echo "$SRC" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  DST="$(echo "$DST" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  # Skip comments / blank lines
  [ -z "$SRC" ] && continue
  case "$SRC" in \#*) continue ;; esac

  SRC_PATH="$NAS:$SRC/"
  DST_PATH="$DISK_ROOT/$DST/"
  TRASH_PATH="$TRASH_BASE/$DST"

  echo "------------------------------------------------------------"
  echo "Pulling:"
  echo "  FROM $SRC_PATH"
  echo "    TO $DST_PATH"

  mkdir -p "$DST_PATH" "$TRASH_PATH"

  rsync "${RSYNC_OPTS[@]}" \
    --backup-dir="$TRASH_PATH" \
    "$SRC_PATH" \
    "$DST_PATH"

  echo ""

done < "$CONFIG"

echo "Pull completed successfully on:"
echo "  $DISK_ROOT"

