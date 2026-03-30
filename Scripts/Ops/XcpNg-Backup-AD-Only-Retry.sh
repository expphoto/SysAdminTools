#!/usr/bin/env bash
set -euo pipefail

# Safe retry script: AD-only, no metadata export, no OpenSSL layer.
# Uses existing background runner script if present.

TARGET_SCRIPT="/var/tmp/xcpng-backup-run/backup-runner.sh"
if [[ ! -f "$TARGET_SCRIPT" ]]; then
  TARGET_SCRIPT="/root/XcpNg-Backup-ToHetzner.sh"
fi

if [[ ! -f "$TARGET_SCRIPT" ]]; then
  echo "ERROR: backup script not found at $TARGET_SCRIPT or /root/XcpNg-Backup-ToHetzner.sh"
  exit 1
fi

cp "$TARGET_SCRIPT" "${TARGET_SCRIPT}.bak.$(date +%Y%m%d-%H%M%S)"

sed -i \
  -e 's/^INCLUDE_HOST_METADATA=.*/INCLUDE_HOST_METADATA="false"/' \
  -e 's/^BACKUP_ENCRYPTION_PASSWORD=.*/BACKUP_ENCRYPTION_PASSWORD=""/' \
  -e 's/^MODE=.*/MODE="selected"/' \
  "$TARGET_SCRIPT"

awk '
BEGIN{in_vm=0}
{
  if ($0 ~ /^VM_NAMES=\(/) {
    print "VM_NAMES=("
    print "  \"AD Server\""
    print ")"
    in_vm=1
    next
  }
  if (in_vm==1) {
    if ($0 ~ /^\)/) { in_vm=0 }
    next
  }
  print
}
' "$TARGET_SCRIPT" > "${TARGET_SCRIPT}.tmp"

mv "${TARGET_SCRIPT}.tmp" "$TARGET_SCRIPT"
chmod 700 "$TARGET_SCRIPT"

mkdir -p /var/tmp/xcpng-backup-run
: > /var/tmp/xcpng-backup-run/backup.log
echo "starting" > /var/tmp/xcpng-backup-run/backup.state

nohup bash "$TARGET_SCRIPT" ACTION=run >> /var/tmp/xcpng-backup-run/backup.log 2>&1 &
PID=$!
echo "$PID" > /var/tmp/xcpng-backup-run/backup.pid

echo "Started AD-only retry backup"
echo "PID: $PID"
echo "Log: /var/tmp/xcpng-backup-run/backup.log"
echo "State: /var/tmp/xcpng-backup-run/backup.state"

