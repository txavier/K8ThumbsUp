#!/usr/bin/env bash
# Fully automated end-to-end smoke test of the K8ThumbsUp autoinstall ISO.
#
# What it does:
#   1. Builds a TEST_MODE=1 ISO (GRUB auto-selects "WIPE & install" with 5s
#      timeout instead of defaulting to "Boot from disk").
#   2. Spins up a KubeVirt VM that boots the ISO from a CDI HTTP DataVolume.
#   3. Records the set of cluster nodes before the install runs.
#   4. Polls the API server for a brand-new node (anything not in the
#      baseline) and waits for it to reach Ready.
#   5. Prints PASS / FAIL, then tears the VM down.
#
# Caveats this does NOT cover vs real hardware:
#   - WiFi netplan + RTL8812AU DKMS path (virtio NIC instead).
#   - Real-disk Rook/Ceph OSD partitioning (60 GiB virtio disk only).
#   - BIOS/UEFI quirks on actual laptops.
#
# Usage:
#   bash k8s/test-vm-e2e.sh                 # full build + run + verify + teardown
#   SKIP_BUILD=1 bash k8s/test-vm-e2e.sh    # reuse existing /tmp/iso-repack ISO
#   KEEP_VM=1   bash k8s/test-vm-e2e.sh    # leave the VM (and joined node) running
#   TIMEOUT_MIN=30 bash k8s/test-vm-e2e.sh  # override the node-Ready wait
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ISO="${ISO:-/tmp/iso-repack/ubuntu-autoinstall.iso}"
TIMEOUT_MIN="${TIMEOUT_MIN:-25}"
SKIP_BUILD="${SKIP_BUILD:-0}"
KEEP_VM="${KEEP_VM:-0}"

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
command -v virtctl >/dev/null || { echo "virtctl not found" >&2; exit 1; }

# ───────────────────────────── 1. Build ──────────────────────────────────
if [[ "$SKIP_BUILD" == "1" ]]; then
  [[ -f "$ISO" ]] || { echo "SKIP_BUILD=1 but $ISO is missing" >&2; exit 1; }
  echo "=== [1/4] SKIP_BUILD=1 — reusing $ISO ==="
else
  echo "=== [1/4] Building TEST_MODE ISO (GRUB auto-selects install) ==="
  ( cd "$REPO_ROOT" && sudo env TEST_MODE=1 BUILD_ISO_ONLY=1 bash prepare-usb.sh )
  [[ -f "$ISO" ]] || { echo "ISO build did not produce $ISO" >&2; exit 1; }
  # prepare-usb.sh runs as root, so make the ISO readable by the HTTP server
  sudo chmod a+r "$ISO"
fi

# ────────────────────────── 2. Baseline nodes ────────────────────────────
echo "=== [2/4] Recording baseline node set ==="
BASELINE_FILE="$(mktemp)"
trap 'rm -f "$BASELINE_FILE"' EXIT
kubectl get nodes -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' \
  | sort > "$BASELINE_FILE"
BASELINE_COUNT=$(wc -l < "$BASELINE_FILE")
echo "  $BASELINE_COUNT existing nodes recorded"

# ──────────────────────────── 3. Bring up VM ─────────────────────────────
echo "=== [3/4] Bringing up KubeVirt smoke-test VM ==="
FORCE_REIMPORT=1 bash "$SCRIPT_DIR/test-vm-up.sh"

# ────────────────────────── 4. Wait for join ─────────────────────────────
echo "=== [4/4] Waiting up to ${TIMEOUT_MIN}m for a new node to reach Ready ==="
END_TS=$(( $(date +%s) + TIMEOUT_MIN*60 ))
NEW_NODE=""
LAST_LOG=0
while (( $(date +%s) < END_TS )); do
  current=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | sort)
  # Names in current but not in baseline
  candidate=$(comm -23 <(echo "$current") "$BASELINE_FILE" | head -1)
  if [[ -n "$candidate" ]]; then
    NEW_NODE="$candidate"
    ready=$(kubectl get node "$NEW_NODE" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    if [[ "$ready" == "True" ]]; then
      echo "  $NEW_NODE: Ready"
      break
    fi
    now=$(date +%s)
    if (( now - LAST_LOG >= 30 )); then
      echo "  $(date +%H:%M:%S) joined node=$NEW_NODE ready=$ready (still waiting)"
      LAST_LOG=$now
    fi
  else
    now=$(date +%s)
    if (( now - LAST_LOG >= 30 )); then
      vmi_phase=$(kubectl -n k8thumbsup-test get vmi k8thumbsup-worker \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "?")
      echo "  $(date +%H:%M:%S) no new node yet (vmi=$vmi_phase)"
      LAST_LOG=$now
    fi
  fi
  sleep 10
done

# ─────────────────────────── Result + cleanup ────────────────────────────
status="FAIL"
if [[ -n "$NEW_NODE" ]]; then
  ready=$(kubectl get node "$NEW_NODE" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  [[ "$ready" == "True" ]] && status="PASS"
fi

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  E2E result: $status"
echo "  New node  : ${NEW_NODE:-<none>}"
[[ -n "$NEW_NODE" ]] && kubectl get node "$NEW_NODE" -o wide || true
echo "════════════════════════════════════════════════════════════"

if [[ "$KEEP_VM" == "1" ]]; then
  echo "KEEP_VM=1 — leaving VM and (if joined) node in place."
else
  echo "=== Tearing down ==="
  bash "$SCRIPT_DIR/test-vm-down.sh" || true
fi

[[ "$status" == "PASS" ]] || exit 1
