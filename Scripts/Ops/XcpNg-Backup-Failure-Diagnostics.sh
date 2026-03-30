#!/usr/bin/env bash
set -euo pipefail

# Collects XAPI/task/export diagnostics after backup failures.

OUT="/var/tmp/xcpng-backup-failure-$(date +%Y%m%d-%H%M%S).log"

{
  echo "=== XCP-ng Backup Failure Diagnostics ==="
  echo "Timestamp: $(date -Iseconds)"
  echo "Host: $(hostname)"
  echo

  echo "=== Backup Runtime Files ==="
  echo "State: $(cat /var/tmp/xcpng-backup-run/backup.state 2>/dev/null || echo missing)"
  echo "PID: $(cat /var/tmp/xcpng-backup-run/backup.pid 2>/dev/null || echo missing)"
  echo

  echo "=== Backup Log Tail ==="
  tail -n 200 /var/tmp/xcpng-backup-run/backup.log 2>/dev/null || true
  echo

  echo "=== XAPI Tasks (recent) ==="
  xe task-list params=uuid,name-label,status,progress,error-info 2>/dev/null | sed -n '1,220p'
  echo

  echo "=== AD Backup Snapshots ==="
  xe vm-list is-snapshot=true name-label~="AD Server-backup-" params=uuid,name-label,power-state,snapshot-of 2>/dev/null
  echo

  echo "=== AD VM and VDIs ==="
  AD_UUID="$(xe vm-list name-label="AD Server" is-control-domain=false params=uuid --minimal | cut -d',' -f1)"
  echo "AD_UUID=$AD_UUID"
  xe vbd-list vm-uuid="$AD_UUID" type=Disk empty=false params=uuid,vdi-uuid,device 2>/dev/null
  echo

  echo "=== Local staging usage ==="
  df -h /var/tmp || true
  du -sh /var/tmp/xcpng-backup-staging 2>/dev/null || true
  ls -lah /var/tmp/xcpng-backup-staging 2>/dev/null || true
} | tee "$OUT"

echo
echo "Saved diagnostics to: $OUT"

