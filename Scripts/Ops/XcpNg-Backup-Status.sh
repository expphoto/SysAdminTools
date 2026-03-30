#!/usr/bin/env bash
set -euo pipefail

# Tactical-friendly status script for XCP-ng backup background jobs.

RUN_DIR="/var/tmp/xcpng-backup-run"
PID_FILE="$RUN_DIR/backup.pid"
LOG_FILE="$RUN_DIR/backup.log"
STATE_FILE="$RUN_DIR/backup.state"
TAIL_LINES="${TAIL_LINES:-120}"

is_running() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
  else
    return 1
  fi
}

echo "=== XCP-ng Backup Status ==="
echo "Timestamp: $(date -Iseconds)"
echo "Host: $(hostname)"
echo

echo "State: $(cat "$STATE_FILE" 2>/dev/null || echo idle)"
if [[ -f "$PID_FILE" ]]; then
  echo "PID file: present ($(cat "$PID_FILE" 2>/dev/null || echo unknown))"
else
  echo "PID file: missing"
fi

if is_running; then
  echo "Process: running"
  status_code=0
else
  echo "Process: not running"
  status_code=1
fi

echo
echo "--- Log Tail (${TAIL_LINES} lines) ---"
if [[ -f "$LOG_FILE" ]]; then
  tail -n "$TAIL_LINES" "$LOG_FILE"
else
  echo "No log file found at $LOG_FILE"
fi

exit "$status_code"

