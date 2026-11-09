#!/bin/ash
set -eu

########################################
# Help
########################################
usage() {
  cat <<'EOF'
Usage:
  push.sh [NAMESPACE [REMOTE_HOST [OPTION]]]
  push.sh [-h|--help]

Options:
  -h, --help       Show this help message
  -n, --dry-run    Preview changes without applying them

Authorized configurations:
  Source: FS6712X-251D
    Namespace: Rex
    Remote:    ts-flashstor-offsite
    Owner:     rex

  Source: FS6712X-87BC
    Namespace: YingTing
    Remote:    ts-flashstor
    Owner:     acht

Behavior:
  - Source NAS is the single source of truth.
  - New and modified files are synchronized.
  - Destination-only files are permanently deleted.
  - Excluded files are deleted from the destination.
  - Ownership is mapped between NAS devices.
  - Group, permissions, and modification times are preserved.
  - Interrupted transfers retain resumable partial files.
  - No trash bin, backups, or version retention.

Examples:
  push.sh
  push.sh Rex ts-flashstor-offsite
  push.sh Rex ts-flashstor-offsite --dry-run
  push.sh YingTing ts-flashstor -n

EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

########################################
# Arguments with defaults
########################################
NAMESPACE="$1"
REMOTE_HOST="$2"

if [ "$#" -gt 3 ]; then
  echo "ERROR: Too many arguments"
  exit 1
fi

case "${3:-}" in
  --dry-run|-n)
    set -- --dry-run
    echo "DRY RUN MODE ENABLED"
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  "")
    set --
    ;;
  *)
    echo "ERROR: Unknown argument: $3"
    exit 1
    ;;
esac

########################################
# Identify local host
########################################
HOST="$(uname -n)"

########################################
# STRICT tuple validation
#
# UID mappings:
#   FS6712X-251D (ts-flashstor)
#     1000 = rex
#     1001 = acht
#
#   FS6712X-87BC (ts-flashstor-offsite)
#     1001 = rex
#     1002 = acht
#
#   GID 100 = users (both NAS devices)
########################################
case "$NAMESPACE:$REMOTE_HOST:$HOST" in
  Rex:ts-flashstor-offsite:FS6712X-251D)
    OWNER_MAP="1000:1001"  # rex → rex
    ;;
  YingTing:ts-flashstor:FS6712X-87BC)
    OWNER_MAP="1002:1001"  # acht → acht
    ;;
  *)
    echo "ERROR: Invalid configuration"
    echo
    echo "  NAMESPACE   = $NAMESPACE"
    echo "  REMOTE_HOST = $REMOTE_HOST"
    echo "  LOCAL HOST  = $HOST"
    echo
    echo "Allowed combinations:"
    echo "  Rex      ts-flashstor-offsite FS6712X-251D"
    echo "  YingTing ts-flashstor         FS6712X-87BC"
    exit 1
    ;;
esac

########################################
# PID lock (robust on NAS / BusyBox)
########################################
LOCKFILE="/home/rex/rsync.pid"

if [ -f "$LOCKFILE" ]; then
  OLD_PID="$(cat "$LOCKFILE" 2>/dev/null || true)"
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Backup already running for $NAMESPACE (PID $OLD_PID)."
    exit 0
  fi
fi

echo "$$" > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT INT TERM

########################################
# Paths
########################################
SRC="/volume1/shared/dropbox/$NAMESPACE/"
DST="rsync://$REMOTE_HOST/dropbox/$NAMESPACE/"

LOG_DIR="/home/rex/logs/rsync"
mkdir -p "$LOG_DIR"

########################################
# Source safety checks
########################################
if [ ! -d "$SRC" ]; then
  echo "ERROR: Source directory does not exist: $SRC"
  exit 1
fi

if [ -z "$(find "$SRC" -mindepth 1 -print -quit)" ]; then
  echo "ERROR: Source directory is empty."
  echo "Refusing to synchronize deletions."
  exit 1
fi

########################################
# Info banner (for logs)
########################################
echo "===================================="
echo "NAS → NAS synchronization starting"
echo "Namespace   : $NAMESPACE"
echo "Local host  : $HOST"
echo "Remote host : $REMOTE_HOST"
echo "Source      : $SRC"
echo "Destination : $DST"
echo "Owner map   : $OWNER_MAP"
echo "===================================="

########################################
# rsync
########################################
rsync -av "$@" \
  --delete-delay \
  --delete-excluded \
  --partial-dir='.rsync-partial' \
  --filter='H .rsync-partial/' \
  --filter='P .rsync-partial/' \
  --info=stats2 \
  --itemize-changes \
  --numeric-ids \
  --usermap="$OWNER_MAP" \
  --omit-dir-times \
  --exclude='.DS_Store' \
  --exclude='._*' \
  --exclude='Thumbs.db' \
  --exclude='ehthumbs*.db' \
  --exclude='Desktop.ini' \
  --exclude='.Trash-*' \
  --exclude='.trash*' \
  --exclude='.nfs*' \
  --log-file="$LOG_DIR/rsync-$(date +%Y-%m-%d).log" \
  --password-file=/volume1/home/rex/.rsync_pass \
  "$SRC" \
  "$DST"

echo "Synchronization completed successfully."
