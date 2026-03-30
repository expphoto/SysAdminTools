#!/usr/bin/env bash
set -euo pipefail

echo "=== Free space cleanup for XCP backup ==="
echo "Timestamp: $(date -Iseconds)"
echo "Host: $(hostname)"
echo

echo "--- Before ---"
df -h / /var /var/tmp || true
du -sh /var/tmp/xcpng-backup-staging 2>/dev/null || true
du -sh /var/tmp/xcpng-backup-run 2>/dev/null || true
echo

if [[ -f /var/tmp/xcpng-backup-run/backup.pid ]]; then
  PID="$(cat /var/tmp/xcpng-backup-run/backup.pid || true)"
  if [[ -n "${PID:-}" ]] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" || true
    sleep 2
    kill -9 "$PID" 2>/dev/null || true
  fi
fi

rm -f /var/tmp/xcpng-backup-run/backup.pid || true
find /var/tmp/xcpng-backup-run -maxdepth 1 -type f -name 'backup-runner.sh.bak.*' -delete 2>/dev/null || true

find /var/tmp/xcpng-backup-staging -type f \( -name '*.xva' -o -name '*.enc' -o -name 'manifest-*.txt' -o -name 'pool-database-*.xml*' -o -name 'host-backup-*.tgz*' \) -delete 2>/dev/null || true
find /var/tmp/xcpng-backup-staging -type d -empty -delete 2>/dev/null || true

find /var/tmp -maxdepth 1 -type f -name 'xcpng-backup-*' -mtime +14 -delete 2>/dev/null || true

echo "--- After ---"
df -h / /var /var/tmp || true
du -sh /var/tmp/xcpng-backup-staging 2>/dev/null || true
du -sh /var/tmp/xcpng-backup-run 2>/dev/null || true
echo "Cleanup complete."

