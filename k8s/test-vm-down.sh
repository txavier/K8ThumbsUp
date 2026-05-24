#!/usr/bin/env bash
# Tear down the K8ThumbsUp smoke-test VM and its PVCs.
#
# Also attempts to clean up the corresponding node entry from the cluster
# (the joined VM registers itself with hostname "k8s-node-<MAC_SUFFIX>").
set -euo pipefail

NS="k8thumbsup-test"

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }

if kubectl get namespace "$NS" >/dev/null 2>&1; then
  echo "=== Deleting VM + DataVolumes ==="
  kubectl -n "$NS" delete vm  k8thumbsup-worker --ignore-not-found
  kubectl -n "$NS" delete dv  k8thumbsup-iso k8thumbsup-disk --ignore-not-found
  kubectl -n "$NS" delete pvc k8thumbsup-iso k8thumbsup-disk --ignore-not-found
  kubectl delete namespace "$NS" --ignore-not-found
else
  echo "Namespace $NS does not exist — nothing to delete."
fi

# Best-effort: scrub the joined node entry.  The VM hostname is derived from
# its MAC suffix so we match any k8s-node-* node whose InternalIP starts with
# 10.0.2 (KubeVirt pod-network masquerade subnet).
echo "=== Removing any cluster node registered from the test VM ==="
while IFS=$'\t' read -r name ip; do
  [[ "$ip" == 10.0.2.* ]] || continue
  echo "  draining + deleting $name (ip=$ip)"
  kubectl drain "$name" --ignore-daemonsets --delete-emptydir-data --force --timeout=30s 2>/dev/null || true
  kubectl delete node "$name" 2>/dev/null || true
done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}')

echo "Done."
