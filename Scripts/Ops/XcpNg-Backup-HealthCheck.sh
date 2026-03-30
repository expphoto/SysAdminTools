#!/usr/bin/env bash
set -euo pipefail

# Health check for XCP-ng -> Hetzner Storage Box backup workflow.
# Safe read-only diagnostics for TacticalRMM.

HETZNER_HOST="u317918.your-storagebox.de"
HETZNER_USER="u317918-sub6"
HETZNER_PORT="23"
HETZNER_REMOTE_BASE="backups/citrix-horizon"
SSH_KEY_PATH="/root/.ssh/storagebox_backup_ed25519"

RUN_DIR="/var/tmp/xcpng-backup-run"
STATE_FILE="$RUN_DIR/backup.state"
PID_FILE="$RUN_DIR/backup.pid"
LOG_FILE="$RUN_DIR/backup.log"
TAIL_LINES="${TAIL_LINES:-120}"

ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $SSH_KEY_PATH -o PubkeyAuthentication=yes -o PreferredAuthentications=publickey -p $HETZNER_PORT"
rsync_ssh_cmd="ssh $ssh_opts"

status_code=0

is_running() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
  else
    return 1
  fi
}

echo "=== XCP-ng Backup Health Check ==="
echo "Timestamp: $(date -Iseconds)"
echo "Host: $(hostname)"
echo

echo "=== Local Runtime ==="
echo "State: $(cat "$STATE_FILE" 2>/dev/null || echo missing)"
if [[ -f "$PID_FILE" ]]; then
  echo "PID file: present ($(cat "$PID_FILE" 2>/dev/null || echo unknown))"
else
  echo "PID file: missing"
fi

if is_running; then
  echo "Process: running"
else
  echo "Process: not running"
fi

echo
echo "=== Local Log Tail (${TAIL_LINES}) ==="
if [[ -f "$LOG_FILE" ]]; then
  tail -n "$TAIL_LINES" "$LOG_FILE"
else
  echo "No log file found at $LOG_FILE"
  status_code=1
fi

echo
echo "=== Remote Connectivity ==="
if ! [[ -f "$SSH_KEY_PATH" ]]; then
  echo "ERROR: SSH key missing: $SSH_KEY_PATH"
  exit 2
fi

if rsync -az --list-only -e "$rsync_ssh_cmd" "$HETZNER_USER@$HETZNER_HOST:./$HETZNER_REMOTE_BASE/" >/tmp/xcp_hc_root.txt 2>/tmp/xcp_hc_root.err; then
  echo "OK: Remote base reachable: ./$HETZNER_REMOTE_BASE/"
  cat /tmp/xcp_hc_root.txt
else
  echo "ERROR: Cannot access remote base ./$HETZNER_REMOTE_BASE/"
  cat /tmp/xcp_hc_root.err
  status_code=2
fi

echo
echo "=== Remote Daily ==="
if rsync -az --list-only -e "$rsync_ssh_cmd" "$HETZNER_USER@$HETZNER_HOST:./$HETZNER_REMOTE_BASE/daily/" >/tmp/xcp_hc_daily.txt 2>/tmp/xcp_hc_daily.err; then
  echo "OK: Daily path reachable"
  cat /tmp/xcp_hc_daily.txt
else
  echo "WARN: Cannot access daily path"
  cat /tmp/xcp_hc_daily.err
  [[ $status_code -lt 2 ]] && status_code=1
fi

echo
echo "=== Remote Metadata ==="
if rsync -az --list-only -e "$rsync_ssh_cmd" "$HETZNER_USER@$HETZNER_HOST:./$HETZNER_REMOTE_BASE/metadata/" >/tmp/xcp_hc_meta.txt 2>/tmp/xcp_hc_meta.err; then
  echo "OK: Metadata path reachable"
  cat /tmp/xcp_hc_meta.txt
else
  echo "WARN: Cannot access metadata path"
  cat /tmp/xcp_hc_meta.err
  [[ $status_code -lt 2 ]] && status_code=1
fi

rm -f /tmp/xcp_hc_root.txt /tmp/xcp_hc_root.err /tmp/xcp_hc_daily.txt /tmp/xcp_hc_daily.err /tmp/xcp_hc_meta.txt /tmp/xcp_hc_meta.err

exit "$status_code"

