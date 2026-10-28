#!/bin/sh
set -eu

SYS="${HOST_SYS_PATH:-/host-sys}"
GPU_MEMORY_SIZE="${GPU_MEMORY_SIZE:-16GB}"
TARGET_PCI_BDF="${TARGET_PCI_BDF:-}"
DRY_RUN="${DRY_RUN:-false}"
SLEEP_AFTER="${SLEEP_AFTER:-true}"
MARKER_FILE="${MARKER_FILE:-/host-run/arc-rebar-ready}"

# Map human-readable VRAM size to PCIe ReBAR register exponent (2^(exp+20) bytes)
case "$(echo "$GPU_MEMORY_SIZE" | tr '[:lower:]' '[:upper:]')" in
  2G|2GB)   TARGET_EXP=11; TARGET_TEXT="2G"  ;;
  4G|4GB)   TARGET_EXP=12; TARGET_TEXT="4G"  ;;
  8G|8GB)   TARGET_EXP=13; TARGET_TEXT="8G"  ;;
  16G|16GB) TARGET_EXP=14; TARGET_TEXT="16G" ;;
  32G|32GB) TARGET_EXP=15; TARGET_TEXT="32G" ;;
  *)
    echo "[ERROR] Unsupported GPU_MEMORY_SIZE: $GPU_MEMORY_SIZE (use 2GB, 4GB, 8GB, 16GB, or 32GB)"
    exit 1
    ;;
esac

 finish() {
  if [ -n "$MARKER_FILE" ] && [ -d "$(dirname "$MARKER_FILE")" ]; then
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "$MARKER_FILE"
  fi
  if [ "$SLEEP_AFTER" = "true" ]; then
    echo "[arc-rebar] Complete. Sleeping infinity to keep DaemonSet pod alive..."
    exec sleep infinity
  fi
  exit 0
}

echo "[arc-rebar] Target BAR size: $GPU_MEMORY_SIZE (Exponent: $TARGET_EXP)"

# 1. Discover discrete Intel Arc GPU (Vendor 8086, Display class 0300/0380, non-bus-00)
if [ -n "$TARGET_PCI_BDF" ]; then
  GPU="$TARGET_PCI_BDF"
else
  GPU=$(lspci -D -d 8086::0300 | awk '$1 !~ /^0000:00:/ {print $1; exit}')
  if [ -z "$GPU" ]; then
    GPU=$(lspci -D -d 8086::0380 | awk '$1 !~ /^0000:00:/ {print $1; exit}')
  fi
fi

if [ -z "$GPU" ]; then
  echo "[arc-rebar] No discrete Intel Arc GPU found outside bus 0000:00."
  finish
fi

# 2. Check if BAR is already at target size
if lspci -vv -s "$GPU" 2>/dev/null | grep -q "size=${TARGET_TEXT}"; then
  echo "[arc-rebar] GPU $GPU is already at size=${TARGET_TEXT}. Nothing to do."
  finish
fi

# 3. Walk up sysfs to find the top-level PCIe Root Port (parent is pci0000:XX)
if [ ! -e "$SYS/bus/pci/devices/$GPU" ]; then
  echo "[ERROR] Cannot find $SYS/bus/pci/devices/$GPU"
  exit 1
fi

dev=$(readlink -f "$SYS/bus/pci/devices/$GPU")
parent=$(dirname "$dev")
while :; do
  case "$(basename "$parent")" in
    pci0000:*) break ;;
  esac
  dev="$parent"
  parent=$(dirname "$dev")
done
ROOT_PORT=$(basename "$dev")

echo "[arc-rebar] Found GPU: $GPU behind Root Port: $ROOT_PORT"

if [ "$DRY_RUN" = "true" ]; then
  echo "[DRY-RUN] Would unbind driver on $GPU, set ECAP_REBAR+0x08.l exponent=$TARGET_EXP, remove $ROOT_PORT, and rescan."
  finish
fi

# 4. Unbind xe or i915 driver if bound
if [ -L "$SYS/bus/pci/devices/$GPU/driver" ]; then
  DRIVER_NAME=$(basename "$(readlink -f "$SYS/bus/pci/devices/$GPU/driver")")
  echo "[arc-rebar] Unbinding driver ($DRIVER_NAME) from $GPU..."
  echo "$GPU" > "$SYS/bus/pci/devices/$GPU/driver/unbind"
fi

# 5. Program the PCIe Resizable BAR control register (ECAP_REBAR+0x08.l)
echo "[arc-rebar] Programming ECAP_REBAR+0x08.l on $GPU to exponent $TARGET_EXP ($GPU_MEMORY_SIZE)..."
setpci -s "$GPU" COMMAND=0000
old=$(setpci -s "$GPU" ECAP_REBAR+0x08.l)
new=$(printf '%08x' $(( (0x$old & 0xFFFFE0FF) | (TARGET_EXP << 8) )))
setpci -s "$GPU" ECAP_REBAR+0x08.l="$new"

# 6. Remove Root Port and rescan PCI bus so Linux reallocates the bridge window
echo "[arc-rebar] Removing Root Port $ROOT_PORT..."
echo 1 > "$SYS/bus/pci/devices/$ROOT_PORT/remove"
sleep 1

echo "[arc-rebar] Triggering PCIe bus rescan..."
echo 1 > "$SYS/bus/pci/rescan"
sleep 2

echo "[arc-rebar] New BAR layout for $GPU:"
lspci -vv -s "$GPU" | grep -E "Region [02]:" || true

finish
