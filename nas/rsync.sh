#!/bin/sh
set -eu

########################################
# Arguments with defaults
########################################
NAMESPACE="$1"
REMOTE_HOST="$2"

########################################
# Identify local host
########################################
HOST="$(hostname)"

########################################
# STRICT tuple validation
########################################
case "$NAMESPACE:$REMOTE_HOST:$HOST" in
  Rex:ts-flashstor-offsite:FS6712X-251D) ;;
  YingTing:ts-flashstor:FS6712X-87BC) ;;
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
DST="rsync://$REMOTE_HOST:/dropbox/$NAMESPACE/"

PARTIAL_DIR="/home/rex/tmp/rsync-partial"
LOG_DIR="/home/rex/logs/rsync"

mkdir -p "$PARTIAL_DIR" "$LOG_DIR"

########################################
# Info banner (for logs)
########################################
echo "===================================="
echo "NAS → NAS backup starting"
echo "Namespace   : $NAMESPACE"
echo "Local host  : $HOST"
echo "Remote host : $REMOTE_HOST"
echo "Source      : $SRC"
echo "Destination : $DST"
echo "===================================="

########################################
# rsync
########################################
rsync -av --ignore-existing --partial \
  --partial-dir="$PARTIAL_DIR" \
  --info=stats2 \
  --numeric-ids \
  --omit-dir-times \
  --exclude='.DS_Store' \
  --exclude='._*' \
  --exclude='Thumbs.db' \
  --exclude='ehthumbs*.db' \
  --exclude='Desktop.ini' \
  --exclude='.Trash-*' \
  --exclude='.trash*' \
  --exclude='.nfs*' \
  "$SRC" \
  "$DST" \
  --log-file="$LOG_DIR/rsync-$(date +%F).log" \
  --password-file=/volume1/home/rex/.rsync_pass

echo "Backup completed successfully."
