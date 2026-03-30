#!/usr/bin/env bash
set -euo pipefail

# Health check for FIFO streaming backup workflow.

HETZNER_HOST="u317918.your-storagebox.de"
HETZNER_USER="u317918-sub6"
HETZNER_PORT="23"
SSH_KEY_PATH="/root/.ssh/storagebox_backup_ed25519"
REMOTE_BASE="backups/citrix-horizon-stream"

RUN_DIR="/var/tmp/xcpng-stream-run"
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

echo "=== XCP-ng Stream Backup Health Check ==="
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
  [[ "$(cat "$STATE_FILE" 2>/dev/null || true)" == "completed" ]] || status_code=1
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
echo "=== Remote Stream Path ==="
if rsync -az --list-only -e "$rsync_ssh_cmd" "$HETZNER_USER@$HETZNER_HOST:./$REMOTE_BASE/" >/tmp/xcp_stream_root.txt 2>/tmp/xcp_stream_root.err; then
  echo "OK: Remote stream base reachable: ./$REMOTE_BASE/"
  cat /tmp/xcp_stream_root.txt
else
  echo "ERROR: Cannot access remote stream base ./$REMOTE_BASE/"
  cat /tmp/xcp_stream_root.err
  status_code=2
fi

echo
echo "=== Remote Stream Daily ==="
if rsync -az --list-only -e "$rsync_ssh_cmd" "$HETZNER_USER@$HETZNER_HOST:./$REMOTE_BASE/daily/" >/tmp/xcp_stream_daily.txt 2>/tmp/xcp_stream_daily.err; then
  echo "OK: Remote stream daily path reachable"
  cat /tmp/xcp_stream_daily.txt
else
  echo "WARN: Cannot access remote stream daily path"
  cat /tmp/xcp_stream_daily.err
  [[ $status_code -lt 2 ]] && status_code=1
fi

rm -f /tmp/xcp_stream_root.txt /tmp/xcp_stream_root.err /tmp/xcp_stream_daily.txt /tmp/xcp_stream_daily.err

exit "$status_code"

