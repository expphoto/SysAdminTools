#!/usr/bin/env bash
set -euo pipefail

# Stream XCP-ng exports to Hetzner Storage Box via SFTP using a FIFO.
# Avoids large local temp files.

HETZNER_HOST="u317918.your-storagebox.de"
HETZNER_USER="u317918-sub6"
HETZNER_PORT="23"
SSH_KEY_PATH="/root/.ssh/storagebox_backup_ed25519"
REMOTE_BASE="backups/citrix-horizon-stream"

VM_NAMES=(
  "AD Server"
  "Windows 10 (64-bit) (1)"
)

WORK_DIR="/var/tmp/xcpng-stream"
FIFO_PATH="$WORK_DIR/export.pipe"

# Tactical background controls
ACTION="start"   # start | run | status | stop
RUN_DIR="/var/tmp/xcpng-stream-run"
PID_FILE="$RUN_DIR/backup.pid"
LOG_FILE="$RUN_DIR/backup.log"
STATE_FILE="$RUN_DIR/backup.state"

log() { printf "%s %s\n" "$(date -Iseconds)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

set_state() {
  mkdir -p "$RUN_DIR"
  printf "%s\n" "$1" > "$STATE_FILE"
}

is_running() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
  else
    return 1
  fi
}

show_status() {
  if is_running; then
    local pid
    pid="$(cat "$PID_FILE")"
    echo "STATUS: running"
    echo "PID: $pid"
  else
    echo "STATUS: not running"
  fi
  echo "STATE: $(cat "$STATE_FILE" 2>/dev/null || echo idle)"
  echo "LOG: $LOG_FILE"
  echo "--- recent log ---"
  tail -n 120 "$LOG_FILE" 2>/dev/null || true
}

run_stream_backup() {

command -v xe >/dev/null 2>&1 || die "xe not found"
command -v sftp >/dev/null 2>&1 || die "sftp not found"
[[ -f "$SSH_KEY_PATH" ]] || die "SSH key missing: $SSH_KEY_PATH"

mkdir -p "$WORK_DIR"

SFTP_OPTS=(
  -P "$HETZNER_PORT"
  -i "$SSH_KEY_PATH"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
)

# Ensure remote directories exist.
printf "mkdir %s\nmkdir %s/daily\nquit\n" "$REMOTE_BASE" "$REMOTE_BASE" | \
  sftp "${SFTP_OPTS[@]}" "$HETZNER_USER@$HETZNER_HOST" >/dev/null 2>&1 || true

timestamp="$(date +%Y%m%d-%H%M%S)"

for vm_name in "${VM_NAMES[@]}"; do
  vm_uuid="$(xe vm-list name-label="$vm_name" is-control-domain=false is-a-template=false params=uuid --minimal 2>/dev/null | cut -d',' -f1)"
  [[ -n "$vm_uuid" ]] || die "VM not found: $vm_name"

  safe_name="$(echo "$vm_name" | tr '[:space:]/' '__' | tr -cd '[:alnum:]_.-')"
  remote_file="$REMOTE_BASE/daily/${safe_name}-${timestamp}.xva"

  log "Snapshot + stream export starting: $vm_name ($vm_uuid)"
  snap_uuid="$(xe vm-snapshot vm="$vm_uuid" new-name-label="${vm_name}-backup-${timestamp}")"

  cleanup_snapshot() {
    local s_uuid="$1"
    [[ -n "$s_uuid" ]] && xe snapshot-uninstall uuid="$s_uuid" force=true >/dev/null 2>&1 || true
  }

  rm -f "$FIFO_PATH"
  mkfifo "$FIFO_PATH"

  # Start uploader first: reads FIFO and uploads without local temp file.
  (
    printf "put %s %s\nquit\n" "$FIFO_PATH" "$remote_file" | \
      sftp "${SFTP_OPTS[@]}" "$HETZNER_USER@$HETZNER_HOST"
  ) &
  sftp_pid=$!

  xe template-param-set is-a-template=false uuid="$snap_uuid" >/dev/null

  # Export writes directly into FIFO.
  if ! xe vm-export vm="$snap_uuid" filename="$FIFO_PATH" compress=true; then
    kill "$sftp_pid" 2>/dev/null || true
    wait "$sftp_pid" 2>/dev/null || true
    cleanup_snapshot "$snap_uuid"
    rm -f "$FIFO_PATH"
    die "vm-export failed for $vm_name"
  fi

  wait "$sftp_pid" || {
    cleanup_snapshot "$snap_uuid"
    rm -f "$FIFO_PATH"
    die "sftp upload failed for $vm_name"
  }

  cleanup_snapshot "$snap_uuid"
  rm -f "$FIFO_PATH"
  log "Completed stream backup for: $vm_name"
done

log "Stream backup workflow complete"
}

start_background() {
  mkdir -p "$RUN_DIR" "$WORK_DIR"

  if is_running; then
    echo "Backup already running (PID: $(cat "$PID_FILE"))"
    exit 0
  fi

  local runner_script
  runner_script="$RUN_DIR/backup-stream-runner.sh"
  cp "$0" "$runner_script"
  chmod 700 "$runner_script"

  : > "$LOG_FILE"
  set_state "starting"

  nohup bash "$runner_script" ACTION=run >> "$LOG_FILE" 2>&1 &
  local pid=$!
  echo "$pid" > "$PID_FILE"

  echo "Started background stream backup"
  echo "PID: $pid"
  echo "Log: $LOG_FILE"
}

stop_background() {
  if ! is_running; then
    echo "No running stream backup process found"
    rm -f "$PID_FILE"
    set_state "stopped"
    exit 0
  fi

  local pid
  pid="$(cat "$PID_FILE")"
  kill "$pid" 2>/dev/null || true
  sleep 2
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
  fi

  rm -f "$PID_FILE"
  rm -f "$FIFO_PATH" 2>/dev/null || true
  set_state "stopped"
  echo "Stopped stream backup process (PID: $pid)"
}

if [[ "${1:-}" == ACTION=* ]]; then
  ACTION="${1#ACTION=}"
fi

case "$ACTION" in
  start)
    start_background
    ;;
  run)
    trap 'rm -f "$PID_FILE" "$FIFO_PATH"; set_state "failed"' ERR
    set_state "running"
    run_stream_backup
    rm -f "$PID_FILE" "$FIFO_PATH"
    set_state "completed"
    ;;
  status)
    show_status
    ;;
  stop)
    stop_background
    ;;
  *)
    echo "Unsupported ACTION: $ACTION"
    echo "Use ACTION=start|run|status|stop"
    exit 2
    ;;
esac
