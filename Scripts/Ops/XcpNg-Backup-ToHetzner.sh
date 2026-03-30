#!/usr/bin/env bash
set -euo pipefail

# XCP-ng/Citrix Hypervisor VM backup to Hetzner Storage Box via SSH/rsync.
# Designed for TacticalRMM script execution on the hypervisor host.

############################
# Required configuration
############################
HETZNER_HOST="u317918.your-storagebox.de"
HETZNER_USER="u317918-sub6"
HETZNER_PORT="23"
HETZNER_REMOTE_BASE="backups/citrix-horizon"
AUTH_MODE="key"  # key | password
SSH_KEY_PATH="/root/.ssh/storagebox_backup_ed25519"
STORAGEBOX_PASSWORD="S7#qP@%WQZ§WFPZ"
BACKUP_ENCRYPTION_PASSWORD="o.!76u3LUFWUpfRKzedbN!p9orPX*aWN2*dotcvv!uJYMfwxW6k2ry2DJE_KohprtVh-kCqYVEnaN2rmbrohTAWT.qiHVqtKs.QU"

############################
# Backup scope
############################
# MODE:
# - selected: only VMs in VM_NAMES
# - all: all non-template/non-snapshot/non-control-domain VMs
MODE="selected"
VM_NAMES=(
  "AD Server"
  "Windows 10 (64-bit) (1)"
)

# Soft cap to avoid accidental multi-terabyte runs when MODE=all.
# Set to 0 to disable cap.
MAX_TOTAL_GIB="1500"

# Include hypervisor metadata backups (small files).
INCLUDE_HOST_METADATA="true"

############################
# Runtime tuning
############################
LOCAL_STAGING="/var/tmp/xcpng-backup-staging"
RETENTION_DAYS="30"
DRY_RUN="false"
ENABLE_RETENTION_PRUNE="false"

# Execution control for TacticalRMM
ACTION="start"    # start | run | status | stop
RUN_DIR="/var/tmp/xcpng-backup-run"
PID_FILE="$RUN_DIR/backup.pid"
LOG_FILE="$RUN_DIR/backup.log"
STATE_FILE="$RUN_DIR/backup.state"

############################
# Helpers
############################
log() { printf "%s %s\n" "$(date -Iseconds)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

log_to_file() {
  mkdir -p "$RUN_DIR"
  printf "%s %s\n" "$(date -Iseconds)" "$*" >> "$LOG_FILE"
}

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
    echo "LOG: $LOG_FILE"
    echo "STATE: $(cat "$STATE_FILE" 2>/dev/null || echo unknown)"
    echo "--- recent log ---"
    tail -n 25 "$LOG_FILE" 2>/dev/null || true
    return 0
  fi

  echo "STATUS: not running"
  echo "STATE: $(cat "$STATE_FILE" 2>/dev/null || idle)"
  echo "LOG: $LOG_FILE"
  echo "--- recent log ---"
  tail -n 25 "$LOG_FILE" 2>/dev/null || true
  return 0
}

bytes_to_gib() {
  local bytes="${1:-0}"
  awk -v b="$bytes" 'BEGIN { printf "%.2f", (b/1024/1024/1024) }'
}

sanitize_name() {
  echo "$1" | tr '[:space:]/' '__' | tr -cd '[:alnum:]_.-'
}

run_cmd() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY-RUN: $*"
  else
    eval "$@"
  fi
}

encrypt_file_if_enabled() {
  local src_file="$1"

  if [[ -z "$BACKUP_ENCRYPTION_PASSWORD" || "$BACKUP_ENCRYPTION_PASSWORD" == "replace-with-strong-passphrase" ]]; then
    echo "$src_file"
    return 0
  fi

  local out_file="${src_file}.enc"
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY-RUN: openssl enc -aes-256-cbc -salt -pbkdf2 -iter 250000 -in '$src_file' -out '$out_file'"
    echo "$out_file"
    return 0
  fi

  # Older OpenSSL builds on some XCP-ng/CentOS hosts do not support -pbkdf2.
  if openssl enc -help 2>&1 | grep -q -- '-pbkdf2'; then
    BACKUP_ENCRYPTION_PASSWORD="$BACKUP_ENCRYPTION_PASSWORD" \
      openssl enc -aes-256-cbc -salt -pbkdf2 -iter 250000 \
        -in "$src_file" -out "$out_file" -pass env:BACKUP_ENCRYPTION_PASSWORD || {
          die "OpenSSL encryption failed for $src_file"
        }
  else
    BACKUP_ENCRYPTION_PASSWORD="$BACKUP_ENCRYPTION_PASSWORD" \
      openssl enc -aes-256-cbc -salt -md sha256 \
        -in "$src_file" -out "$out_file" -pass env:BACKUP_ENCRYPTION_PASSWORD || {
          die "OpenSSL encryption failed for $src_file (legacy mode)"
        }
  fi

  rm -f "$src_file"
  echo "$out_file"
}

############################
# Main backup workflow
############################
run_backup() {
command -v xe >/dev/null 2>&1 || die "'xe' CLI not found"
command -v rsync >/dev/null 2>&1 || die "'rsync' is required"
command -v ssh >/dev/null 2>&1 || die "'ssh' is required"
command -v openssl >/dev/null 2>&1 || die "'openssl' is required"

[[ -n "$HETZNER_HOST" && -n "$HETZNER_USER" ]] || die "Set Hetzner host/user configuration"

if [[ "$AUTH_MODE" == "password" ]]; then
  command -v sshpass >/dev/null 2>&1 || die "'sshpass' is required for password-based Storage Box auth"
  [[ -n "$STORAGEBOX_PASSWORD" && "$STORAGEBOX_PASSWORD" != "replace-with-storage-box-password" ]] || die "Set STORAGEBOX_PASSWORD"
  export SSHPASS="$STORAGEBOX_PASSWORD"
elif [[ "$AUTH_MODE" == "key" ]]; then
  [[ -f "$SSH_KEY_PATH" ]] || die "SSH key not found: $SSH_KEY_PATH"
else
  die "AUTH_MODE must be 'key' or 'password'"
fi

mkdir -p "$LOCAL_STAGING"
timestamp="$(date +%Y%m%d-%H%M%S)"
daily_remote="$HETZNER_REMOTE_BASE/daily"
meta_remote="$HETZNER_REMOTE_BASE/metadata"

ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $HETZNER_PORT"
if [[ "$AUTH_MODE" == "key" ]]; then
  ssh_opts="$ssh_opts -i $SSH_KEY_PATH -o PubkeyAuthentication=yes -o PreferredAuthentications=publickey"
  ssh_cmd="ssh $ssh_opts"
  rsync_ssh_cmd="ssh $ssh_opts"
else
  ssh_opts="$ssh_opts -o PubkeyAuthentication=no -o PreferredAuthentications=password"
  ssh_cmd="sshpass -e ssh $ssh_opts"
  rsync_ssh_cmd="sshpass -e ssh $ssh_opts"
fi

log "Testing remote connectivity to Hetzner Storage Box"
if ! rsync -az --list-only -e "$rsync_ssh_cmd" "$HETZNER_USER@$HETZNER_HOST:./$HETZNER_REMOTE_BASE/" >/dev/null 2>&1; then
  die "Unable to connect/authenticate to Hetzner Storage Box via rsync"
fi
log "NOTE: Ensure remote dirs exist before run: $daily_remote and $meta_remote"

############################
# Build VM target list
############################
declare -a target_vm_uuids
declare -a target_vm_names

if [[ "$MODE" == "all" ]]; then
  vm_list="$(xe vm-list is-control-domain=false is-a-template=false params=uuid --minimal 2>/dev/null || true)"
  declare -a all_uuids=()
  IFS=',' read -r -a all_uuids <<< "$vm_list"
  for vm_uuid in "${all_uuids[@]}"; do
    [[ -z "$vm_uuid" ]] && continue
    target_vm_uuids+=("$vm_uuid")
    target_vm_names+=("$(xe vm-param-get uuid="$vm_uuid" param-name=name-label)")
  done
else
  for vm_name in "${VM_NAMES[@]}"; do
    vm_uuid="$(xe vm-list name-label="$vm_name" is-control-domain=false is-a-template=false params=uuid --minimal 2>/dev/null | cut -d',' -f1)"
    [[ -n "$vm_uuid" ]] || die "VM not found: $vm_name"
    target_vm_uuids+=("$vm_uuid")
    target_vm_names+=("$vm_name")
  done
fi

[[ ${#target_vm_uuids[@]} -gt 0 ]] || die "No VM targets resolved"

############################
# Estimate total size
############################
total_bytes=0
for vm_uuid in "${target_vm_uuids[@]}"; do
  vm_bytes=0
  vbd_list="$(xe vbd-list vm-uuid="$vm_uuid" type=Disk empty=false params=uuid --minimal 2>/dev/null || true)"
  declare -a vbd_uuids=()
  IFS=',' read -r -a vbd_uuids <<< "$vbd_list"
  for vbd_uuid in "${vbd_uuids[@]}"; do
    [[ -z "$vbd_uuid" ]] && continue
    vdi_uuid="$(xe vbd-param-get uuid="$vbd_uuid" param-name=vdi-uuid 2>/dev/null || true)"
    [[ -z "$vdi_uuid" ]] && continue
    vdi_size="$(xe vdi-param-get uuid="$vdi_uuid" param-name=virtual-size 2>/dev/null || echo 0)"
    vm_bytes=$((vm_bytes + vdi_size))
  done
  total_bytes=$((total_bytes + vm_bytes))
done

estimated_gib="$(bytes_to_gib "$total_bytes")"
log "Resolved ${#target_vm_uuids[@]} VM(s); estimated virtual footprint: ${estimated_gib} GiB"

if [[ "$MAX_TOTAL_GIB" != "0" ]]; then
  too_big="$(awk -v t="$estimated_gib" -v m="$MAX_TOTAL_GIB" 'BEGIN { if (t>m) print "yes"; else print "no" }')"
  [[ "$too_big" == "no" ]] || die "Estimated size ${estimated_gib} GiB exceeds MAX_TOTAL_GIB=${MAX_TOTAL_GIB}"
fi

############################
# Optional host metadata backup
############################
if [[ "$INCLUDE_HOST_METADATA" == "true" ]]; then
  db_file="$LOCAL_STAGING/pool-database-${timestamp}.xml"
  host_file="$LOCAL_STAGING/host-backup-${timestamp}.tgz"

  log "Exporting hypervisor metadata"
  run_cmd "xe pool-dump-database file-name='$db_file'"
  run_cmd "xe host-backup file-name='$host_file'"

  db_upload_file="$(encrypt_file_if_enabled "$db_file")"
  host_upload_file="$(encrypt_file_if_enabled "$host_file")"

  run_cmd "rsync -az --partial --inplace -e \"$rsync_ssh_cmd\" '$db_upload_file' '$HETZNER_USER@$HETZNER_HOST:$meta_remote/'"
  run_cmd "rsync -az --partial --inplace -e \"$rsync_ssh_cmd\" '$host_upload_file' '$HETZNER_USER@$HETZNER_HOST:$meta_remote/'"

  run_cmd "rm -f '$db_file' '$host_file' '${db_file}.enc' '${host_file}.enc'"
fi

############################
# VM backups
############################
manifest="$LOCAL_STAGING/manifest-${timestamp}.txt"
: > "$manifest"

for i in "${!target_vm_uuids[@]}"; do
  vm_uuid="${target_vm_uuids[$i]}"
  vm_name="${target_vm_names[$i]}"
  safe_name="$(sanitize_name "$vm_name")"
  export_file="$LOCAL_STAGING/${safe_name}-${timestamp}.xva"

  log "Snapshot + export starting: $vm_name ($vm_uuid)"
  snap_uuid="$(xe vm-snapshot vm="$vm_uuid" new-name-label="${vm_name}-backup-${timestamp}")"

  cleanup_snapshot() {
    local s_uuid="$1"
    if [[ -n "$s_uuid" ]]; then
      xe snapshot-uninstall uuid="$s_uuid" force=true >/dev/null 2>&1 || true
    fi
  }

  trap 'cleanup_snapshot "$snap_uuid"' EXIT

  xe template-param-set is-a-template=false uuid="$snap_uuid" >/dev/null
  run_cmd "xe vm-export vm='$snap_uuid' filename='$export_file' compress=true"

  upload_file="$(encrypt_file_if_enabled "$export_file")"

  if [[ "$DRY_RUN" != "true" ]]; then
    size_bytes="$(stat -c %s "$upload_file" 2>/dev/null || stat -f %z "$upload_file")"
    echo "$vm_name|$vm_uuid|$(basename "$upload_file")|$size_bytes" >> "$manifest"
  else
    echo "$vm_name|$vm_uuid|$(basename "$upload_file")|0" >> "$manifest"
  fi

  run_cmd "rsync -az --partial --inplace -e \"$rsync_ssh_cmd\" '$upload_file' '$HETZNER_USER@$HETZNER_HOST:$daily_remote/'"
  run_cmd "rm -f '$export_file' '${export_file}.enc'"

  cleanup_snapshot "$snap_uuid"
  trap - EXIT

  log "Completed backup for: $vm_name"
done

run_cmd "rsync -az -e \"$rsync_ssh_cmd\" '$manifest' '$HETZNER_USER@$HETZNER_HOST:$daily_remote/'"
run_cmd "rm -f '$manifest'"

############################
# Retention
############################
log "Applying retention: keep files newer than ${RETENTION_DAYS} days"
if [[ "$ENABLE_RETENTION_PRUNE" == "true" ]]; then
  run_cmd "$ssh_cmd '$HETZNER_USER@$HETZNER_HOST' \"find '$daily_remote' -type f -mtime +$RETENTION_DAYS -delete\""
  run_cmd "$ssh_cmd '$HETZNER_USER@$HETZNER_HOST' \"find '$meta_remote' -type f -mtime +$RETENTION_DAYS -delete\""
else
  log "Retention prune skipped (ENABLE_RETENTION_PRUNE=false)."
fi

log "Backup workflow complete"
}

start_background() {
  mkdir -p "$RUN_DIR"

  if is_running; then
    local pid
    pid="$(cat "$PID_FILE")"
    echo "Backup already running (PID: $pid)"
    exit 0
  fi

  : > "$LOG_FILE"
  set_state "starting"

  local runner_script
  runner_script="$RUN_DIR/backup-runner.sh"
  cp "$0" "$runner_script"
  chmod 700 "$runner_script"

  nohup bash "$runner_script" ACTION=run >> "$LOG_FILE" 2>&1 &
  local pid=$!
  echo "$pid" > "$PID_FILE"

  echo "Started background backup"
  echo "PID: $pid"
  echo "Log: $LOG_FILE"
}

stop_background() {
  if ! is_running; then
    echo "No running backup process found"
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
  set_state "stopped"
  echo "Stopped backup process (PID: $pid)"
}

# Support Tactical-style override: ACTION=run as positional env-like arg.
if [[ "${1:-}" == ACTION=* ]]; then
  ACTION="${1#ACTION=}"
fi

case "$ACTION" in
  start)
    start_background
    ;;
  run)
    trap 'rm -f "$PID_FILE"; set_state "failed"' ERR
    set_state "running"
    run_backup
    rm -f "$PID_FILE"
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
