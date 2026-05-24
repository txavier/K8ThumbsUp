#!/usr/bin/env bash
# Spin up a KubeVirt smoke-test VM that boots the freshly built
# /tmp/iso-repack/ubuntu-autoinstall.iso and runs the full subiquity
# autoinstall against a blank virtio disk.
#
# Prerequisites:
#   - KubeVirt + CDI installed on the target cluster
#   - kubectl + virtctl on PATH, pointing at the test cluster
#   - ISO at /tmp/iso-repack/ubuntu-autoinstall.iso (run prepare-usb.sh first)
#
# Usage:
#   bash k8s/test-vm-up.sh
#   virtctl vnc -n k8thumbsup-test k8thumbsup-worker
#   # In VNC: select "Install Kubernetes Node" within 30s
#   # Wait ~5-10 min for install, VM reboots automatically.
#   virtctl console -n k8thumbsup-test k8thumbsup-worker
#   # Watch /var/log/k8s-auto-join.log on the installed system.
#
# Tear down:
#   bash k8s/test-vm-down.sh
set -euo pipefail

NS="k8thumbsup-test"
ISO="${ISO:-/tmp/iso-repack/ubuntu-autoinstall.iso}"
MANIFEST_SRC="$(cd "$(dirname "$0")" && pwd)/test-vm.yaml"

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
command -v virtctl >/dev/null || { echo "virtctl not found — install from https://kubevirt.io/quickstart_kind/#install-virtctl" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 required to serve the ISO" >&2; exit 1; }
[[ -f "$ISO" ]] || { echo "ISO not found at $ISO — run prepare-usb.sh first" >&2; exit 1; }

# --- Discover an IP reachable from the cluster ---------------------------
# Route to the master gives us the local source IP on the right NIC.
MASTER_IP_DEFAULT="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' \
  | sed -E 's#https?://##; s#:[0-9]+##')"
MASTER_IP="${MASTER_IP:-$MASTER_IP_DEFAULT}"
HOST_IP="${HOST_IP:-$(ip -4 route get "$MASTER_IP" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')}"
[[ -n "$HOST_IP" ]] || { echo "could not auto-detect host IP reachable from cluster; set HOST_IP=..." >&2; exit 1; }
PORT="${PORT:-8765}"
ISO_URL="http://${HOST_IP}:${PORT}/$(basename "$ISO")"

# If UFW is active on this host, briefly open the serving port to the local
# subnet so the CDI importer pod can reach us.  Best-effort: requires passwordless
# sudo; skipped silently otherwise (with a hint).  We never block on a prompt.
if command -v ufw >/dev/null && sudo -n ufw status 2>/dev/null | grep -q '^Status: active'; then
  SUBNET="$(ip -4 -o addr show | awk -v ip="$HOST_IP" '$4 ~ ip"/" {print $4; exit}')"
  if [[ -n "$SUBNET" ]]; then
    NET="$(python3 -c "import ipaddress; print(ipaddress.ip_network('$SUBNET', strict=False))")"
    # Skip the add if an equivalent rule is already in place
    if sudo -n ufw status 2>/dev/null | grep -qE "^${PORT}/tcp\s+ALLOW\s+IN\s+${NET//./\.}"; then
      :  # rule already exists, nothing to do
    elif sudo -n true 2>/dev/null; then
      sudo -n ufw allow from "$NET" to any port "$PORT" proto tcp \
        comment 'k8thumbsup test-vm-up.sh (transient)' >/dev/null || true
      UFW_RULE_ADDED=1
      cleanup_fw() { [[ -n "${UFW_RULE_ADDED:-}" ]] && sudo -n ufw delete allow from "$NET" to any port "$PORT" proto tcp >/dev/null 2>&1 || true; }
    else
      echo "  NOTE: ufw is active and no rule for port $PORT from $NET exists."
      echo "        If CDI import stalls at 0%, run manually:"
      echo "          sudo ufw allow from $NET to any port $PORT proto tcp"
    fi
  fi
fi

# --- Start a local HTTP server serving the ISO ---------------------------
SERVE_DIR="$(dirname "$ISO")"
echo "=== Serving $SERVE_DIR on ${HOST_IP}:${PORT} ==="
( cd "$SERVE_DIR" && exec python3 -m http.server "$PORT" --bind 0.0.0.0 ) \
  >/tmp/k8thumbsup-iso-server.log 2>&1 &
HTTP_PID=$!
cleanup() {
  kill "$HTTP_PID" 2>/dev/null || true
  type cleanup_fw >/dev/null 2>&1 && cleanup_fw || true
}
trap cleanup EXIT
# Wait until it's accepting connections
for _ in $(seq 1 20); do
  (echo > /dev/tcp/127.0.0.1/"$PORT") 2>/dev/null && break
  sleep 0.25
done

# --- Render manifest with the computed ISO_URL ---------------------------
MANIFEST="$(mktemp --suffix=.yaml)"
trap 'cleanup; rm -f "$MANIFEST"' EXIT
sed "s#__ISO_URL__#${ISO_URL}#g" "$MANIFEST_SRC" > "$MANIFEST"

# If a pre-existing ISO DV is in any state other than Succeeded (e.g. stuck
# in ImportInProgress, or using a different source/storage class than the
# current manifest), recreate it from scratch.  Also recreate when the URL
# has changed (host IP differs between runs) or when FORCE_REIMPORT=1, so a
# rebuilt ISO actually gets re-fetched.
existing_phase="$(kubectl -n "$NS" get dv k8thumbsup-iso -o jsonpath='{.status.phase}' 2>/dev/null || true)"
existing_url="$(kubectl -n "$NS" get dv k8thumbsup-iso -o jsonpath='{.spec.source.http.url}' 2>/dev/null || true)"
recreate=0
[[ -n "$existing_phase" && "$existing_phase" != "Succeeded" ]] && recreate=1
[[ -n "$existing_url" && "$existing_url" != "$ISO_URL" ]] && recreate=1
[[ "${FORCE_REIMPORT:-0}" == "1" ]] && recreate=1
if (( recreate )); then
  echo "=== Recreating k8thumbsup-iso DV (phase=$existing_phase url=$existing_url) ==="
  # Delete the VMI FIRST — while it's running it holds the cdrom PVC and the
  # PVC delete blocks indefinitely.  The VM's runStrategy=RerunOnFailure will
  # bring a fresh VMI back once the new DV is ready.
  kubectl -n "$NS" delete vmi k8thumbsup-worker --ignore-not-found --wait=true --timeout=60s || true
  kubectl -n "$NS" delete dv k8thumbsup-iso --wait=true --ignore-not-found || true
  kubectl -n "$NS" delete pvc k8thumbsup-iso --ignore-not-found --wait=true || true
  # Also nuke any leftover prime/scratch PVCs from the previous attempt
  kubectl -n "$NS" get pvc -o name 2>/dev/null | grep -E 'prime-|scratch' | \
    xargs -r kubectl -n "$NS" delete --ignore-not-found --wait=true || true
fi

echo "=== Applying namespace + DataVolumes + VM manifest ==="
kubectl apply -f "$MANIFEST"

echo "=== Waiting for ISO DataVolume to import from $ISO_URL ==="
# CDI's importer pod will GET the ISO from our HTTP server.
# Poll phase + progress so the user can see it move.
last_progress=""
for _ in $(seq 1 1800); do
  phase=$(kubectl -n "$NS" get dv k8thumbsup-iso -o jsonpath='{.status.phase}' 2>/dev/null || true)
  progress=$(kubectl -n "$NS" get dv k8thumbsup-iso -o jsonpath='{.status.progress}' 2>/dev/null || true)
  if [[ "$progress" != "$last_progress" || "$phase" != "ImportInProgress" ]]; then
    echo "  phase=$phase progress=$progress"
    last_progress="$progress"
  fi
  [[ "$phase" == "Succeeded" ]] && break
  [[ "$phase" == "Failed" ]] && { echo "DataVolume import failed" >&2; exit 1; }
  sleep 2
done
[[ "$phase" == "Succeeded" ]] || { echo "Timed out waiting for ISO import (phase=$phase)" >&2; exit 1; }

echo "=== Waiting for VM to start ==="
kubectl -n "$NS" wait --for=condition=Ready vmi/k8thumbsup-worker --timeout=180s || true
kubectl -n "$NS" get vmi k8thumbsup-worker -o wide

cat <<EOF

VM is up.  Next steps:

  # 1. Open the console and pick "Install Kubernetes Node" within 30s:
  virtctl vnc -n $NS k8thumbsup-worker

  # 2. Watch the installer (or, after reboot, the auto-join service):
  virtctl console -n $NS k8thumbsup-worker

  # 3. Verify the node joined the cluster:
  kubectl get nodes -o wide | grep k8thumbsup

  # Tear down when finished:
  bash k8s/test-vm-down.sh
EOF
