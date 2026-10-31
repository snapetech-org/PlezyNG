#!/usr/bin/env bash
set -euo pipefail

if (($# == 0)); then
  printf 'Usage: %s <PlezyNG executable> [arguments...]\n' "$0" >&2
  exit 2
fi

if ! command -v rocminfo >/dev/null 2>&1; then
  printf 'rocminfo is required to identify the RX 7900 XT safely.\n' >&2
  exit 1
fi

gpu_inventory() {
  awk '
    function emit() {
      gsub(/[[:space:]]+$/, "", marketing)
      if (vendor == "AMD" && marketing ~ /^AMD Radeon RX /) {
        print marketing "|" architecture "|" uuid
      }
    }
    /^Agent[[:space:]]+[0-9]+[[:space:]]*$/ {
      emit()
      vendor = ""
      marketing = ""
      architecture = ""
      uuid = ""
      next
    }
    /^[[:space:]]*Vendor Name:/ { vendor = $3; next }
    /^[[:space:]]*Marketing Name:/ {
      sub(/^[[:space:]]*Marketing Name:[[:space:]]*/, "")
      marketing = $0
      gsub(/[[:space:]]+$/, "", marketing)
      next
    }
    /^[[:space:]]*Name:/ { architecture = $2; next }
    /^[[:space:]]*Uuid:/ { uuid = $2; next }
    END { emit() }
  '
}

if ! host_gpus=$(rocminfo | gpu_inventory); then
  printf 'Could not enumerate ROCm GPUs.\n' >&2
  exit 1
fi

if ! target=$(printf '%s\n' "$host_gpus" | awk -F '|' '
  $1 == "AMD Radeon RX 7900 XT" && $2 ~ /gfx11/ { count++; selected = $0 }
  END { if (count != 1) exit 1; print selected }
'); then
  printf 'Expected exactly one AMD Radeon RX 7900 XT (gfx11); found:\n%s\n' "$host_gpus" >&2
  exit 1
fi

IFS='|' read -r gpu_name gpu_arch gpu_uuid <<<"$target"
if [[ ! "$gpu_uuid" =~ ^GPU- ]]; then
  printf 'ROCm returned an unexpected RX 7900 XT UUID: %s\n' "$gpu_uuid" >&2
  exit 1
fi

if ! visible_gpus=$(ROCR_VISIBLE_DEVICES="$gpu_uuid" rocminfo | gpu_inventory); then
  printf 'Could not verify the RX 7900 XT process-visible ROCm device set.\n' >&2
  exit 1
fi
if [[ "$visible_gpus" != "$target" ]]; then
  printf 'Refusing to launch: ROCm visibility did not isolate the RX 7900 XT.\nExpected: %s\nVisible: %s\n' \
    "$target" "$visible_gpus" >&2
  exit 1
fi

# PME's MIGraphX device 0 is now the RX 7900 XT. The Vulkan selector is read
# by the local PME filter patch; MPV's display renderer remains unchanged.
export ROCR_VISIBLE_DEVICES="$gpu_uuid"
export PLEZY_PME_VULKAN_DEVICE="$gpu_name"

printf 'PME compute pinned to %s (%s); desktop/output GPU selection unchanged.\n' "$gpu_name" "$gpu_uuid" >&2
exec "$@"
