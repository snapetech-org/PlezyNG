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

vulkan_inventory() {
  awk -v target="$1" '
    function value_after_equals(line) {
      sub(/^[^=]*=[[:space:]]*/, "", line)
      gsub(/^"|"$/, "", line)
      return line
    }
    function emit() {
      if (name != "" && index(name, target) > 0) {
        matches++
        selected = vendor "|" device
      }
    }
    /^GPU[0-9]+:$/ {
      emit()
      name = ""
      vendor = ""
      device = ""
      next
    }
    /^[[:space:]]*deviceName[[:space:]]*=/ { name = value_after_equals($0); next }
    /^[[:space:]]*vendorID[[:space:]]*=/ { vendor = value_after_equals($0); next }
    /^[[:space:]]*deviceID[[:space:]]*=/ { device = value_after_equals($0); next }
    END {
      emit()
      if (matches != 1 || vendor == "" || device == "") exit 1
      print selected
    }
  '
}

configure_runtime_loader_paths() {
  local runtime_dir="${PLEZY_PME_RUNTIME_DIR:-}"
  local extra_library_paths="${PLEZY_PME_LIBRARY_PATH:-}"
  local current_library_path="${LD_LIBRARY_PATH:-}"
  local directory
  local prefix=""
  local -a library_directories=()
  local -a extra_directories=()

  if [[ -n "$runtime_dir" ]]; then
    if [[ ! -d "$runtime_dir" ]]; then
      printf 'PLEZY_PME_RUNTIME_DIR is not a directory: %s\n' "$runtime_dir" >&2
      return 1
    fi
    library_directories+=("$runtime_dir")
    if [[ -d "$runtime_dir/migraphx/lib" ]]; then
      library_directories+=("$runtime_dir/migraphx/lib")
    fi
  fi

  if [[ -n "$extra_library_paths" ]]; then
    IFS=: read -r -a extra_directories <<<"$extra_library_paths"
    for directory in "${extra_directories[@]}"; do
      [[ -n "$directory" ]] || continue
      if [[ ! -d "$directory" ]]; then
        printf 'PLEZY_PME_LIBRARY_PATH entry is not a directory: %s\n' "$directory" >&2
        return 1
      fi
      library_directories+=("$directory")
    done
  fi

  for directory in "${library_directories[@]}"; do
    prefix="${prefix:+$prefix:}$directory"
  done
  if [[ -n "$prefix" ]]; then
    export LD_LIBRARY_PATH="$prefix${current_library_path:+:$current_library_path}"
  fi
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

if ! command -v vulkaninfo >/dev/null 2>&1; then
  printf 'vulkaninfo is required to pin WebGPU inference to the RX 7900 XT safely.\n' >&2
  exit 1
fi
if ! webgpu_device=$(vulkaninfo --summary 2>/dev/null | vulkan_inventory "$gpu_name"); then
  printf 'Could not map the RX 7900 XT to one Vulkan hardware ID.\n' >&2
  exit 1
fi
IFS='|' read -r webgpu_vendor_id webgpu_device_id <<<"$webgpu_device"
if [[ ! "$webgpu_vendor_id" =~ ^0x[[:xdigit:]]+$ || ! "$webgpu_device_id" =~ ^0x[[:xdigit:]]+$ ]]; then
  printf 'Vulkan returned unexpected RX 7900 XT vendor/device IDs: %s\n' "$webgpu_device" >&2
  exit 1
fi
if [[ "${webgpu_vendor_id,,}" != "0x1002" ]]; then
  printf 'Vulkan RX 7900 XT mapping returned unexpected vendor ID: %s\n' "$webgpu_vendor_id" >&2
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

configure_runtime_loader_paths || exit 1

# PME's MIGraphX device 0 is now the RX 7900 XT. The Vulkan selector is read
# by the local PME filter patch; MPV's display renderer remains unchanged.
export ROCR_VISIBLE_DEVICES="$gpu_uuid"
export PLEZY_PME_VULKAN_DEVICE="$gpu_name"
export PLEZY_PME_WEBGPU_VENDOR_ID="$webgpu_vendor_id"
export PLEZY_PME_WEBGPU_DEVICE_ID="$webgpu_device_id"

printf 'PME compute pinned to %s (%s, WebGPU ID %s:%s); desktop/output GPU selection unchanged.\n' \
  "$gpu_name" "$gpu_uuid" "$webgpu_vendor_id" "$webgpu_device_id" >&2
exec "$@"
