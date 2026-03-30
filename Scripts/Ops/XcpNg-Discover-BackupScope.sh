#!/usr/bin/env bash
set -euo pipefail

# Discovery-only script for XCP-ng/Citrix Hypervisor hosts.
# Safe to run from TacticalRMM as a Script Check or ad-hoc task.

bytes_to_gib() {
  local bytes="${1:-0}"
  awk -v b="$bytes" 'BEGIN { printf "%.2f", (b/1024/1024/1024) }'
}

echo "=== XCP-ng Backup Scope Discovery ==="
echo "Timestamp: $(date -Iseconds)"
echo "Host: $(hostname)"
echo

if ! command -v xe >/dev/null 2>&1; then
  echo "ERROR: 'xe' CLI not found. Run this on an XCP-ng/Citrix hypervisor host." >&2
  exit 2
fi

echo "=== Storage Repositories ==="
printf "%-36s  %-24s  %-8s  %-8s  %-8s\n" "SR UUID" "Name" "TotalGB" "UsedGB" "FreeGB"

sr_list="$(xe sr-list params=uuid --minimal 2>/dev/null || true)"
declare -a sr_uuids=()
IFS=',' read -r -a sr_uuids <<< "$sr_list"
for sr_uuid in "${sr_uuids[@]}"; do
  [[ -z "$sr_uuid" ]] && continue
  sr_name="$(xe sr-param-get uuid="$sr_uuid" param-name=name-label 2>/dev/null || echo "unknown")"
  size_bytes="$(xe sr-param-get uuid="$sr_uuid" param-name=physical-size 2>/dev/null || echo 0)"
  used_bytes="$(xe sr-param-get uuid="$sr_uuid" param-name=physical-utilisation 2>/dev/null || echo 0)"
  free_bytes=$((size_bytes - used_bytes))
  printf "%-36s  %-24s  %-8s  %-8s  %-8s\n" \
    "$sr_uuid" \
    "${sr_name:0:24}" \
    "$(bytes_to_gib "$size_bytes")" \
    "$(bytes_to_gib "$used_bytes")" \
    "$(bytes_to_gib "$free_bytes")"
done

echo
echo "=== VM Inventory (non-template, non-control-domain) ==="
printf "%-36s  %-28s  %-10s  %-10s\n" "VM UUID" "VM Name" "Power" "DiskGiB"

vm_list="$(xe vm-list is-control-domain=false is-a-template=false params=uuid --minimal 2>/dev/null || true)"
declare -a vm_uuids=()
IFS=',' read -r -a vm_uuids <<< "$vm_list"

total_bytes=0
for vm_uuid in "${vm_uuids[@]}"; do
  [[ -z "$vm_uuid" ]] && continue

  vm_name="$(xe vm-param-get uuid="$vm_uuid" param-name=name-label 2>/dev/null || echo "unknown")"
  power_state="$(xe vm-param-get uuid="$vm_uuid" param-name=power-state 2>/dev/null || echo "unknown")"

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

  printf "%-36s  %-28s  %-10s  %-10s\n" \
    "$vm_uuid" \
    "${vm_name:0:28}" \
    "$power_state" \
    "$(bytes_to_gib "$vm_bytes")"
done

echo
echo "Estimated total VM disk footprint (virtual): $(bytes_to_gib "$total_bytes") GiB"
echo "Discovery completed successfully."
