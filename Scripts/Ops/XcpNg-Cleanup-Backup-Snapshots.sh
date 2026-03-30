#!/usr/bin/env bash
set -euo pipefail

# Cleans stale snapshots created by prior backup runs.

echo "=== Cleanup stale backup snapshots ==="
echo "Timestamp: $(date -Iseconds)"
echo "Host: $(hostname)"
echo

if [[ -f /var/tmp/xcpng-backup-run/backup.pid ]]; then
  PID="$(cat /var/tmp/xcpng-backup-run/backup.pid || true)"
  if [[ -n "${PID:-}" ]] && kill -0 "$PID" 2>/dev/null; then
    echo "Stopping running backup PID: $PID"
    kill "$PID" || true
    sleep 2
    kill -9 "$PID" 2>/dev/null || true
  fi
fi

rm -f /var/tmp/xcpng-backup-run/backup.pid
mkdir -p /var/tmp/xcpng-backup-run
echo "stopped" > /var/tmp/xcpng-backup-run/backup.state

mapfile -t SNAP_UUIDS < <(xe vm-list is-snapshot=true name-label~="-backup-" params=uuid --minimal 2>/dev/null | tr ',' '\n' | sed '/^$/d')

if [[ ${#SNAP_UUIDS[@]} -eq 0 ]]; then
  echo "No backup snapshots found."
  exit 0
fi

echo "Found ${#SNAP_UUIDS[@]} snapshot(s). Removing..."
for S in "${SNAP_UUIDS[@]}"; do
  NAME="$(xe vm-param-get uuid="$S" param-name=name-label 2>/dev/null || echo unknown)"
  echo "Removing snapshot: $S ($NAME)"
  xe snapshot-uninstall uuid="$S" force=true || echo "WARN: failed to remove $S"
done

echo
echo "Remaining backup snapshots:"
xe vm-list is-snapshot=true name-label~="-backup-" params=uuid,name-label 2>/dev/null || true
echo "Cleanup complete."

