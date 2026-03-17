#!/usr/bin/env bash
# auto-join.sh — Automatically joins this node to the Kubernetes cluster.
# Runs on first boot via systemd. SSHs to the master to get a fresh join token.

set -euo pipefail

MASTER_IP="REDACTED_IP"
MASTER_USER="theo"
SSH_KEY="/etc/kubernetes/node-join-key"
LOG="/var/log/k8s-auto-join.log"
STAMP="/etc/kubernetes/.joined"

exec > >(tee -a "$LOG") 2>&1
echo "[$(date)] auto-join: starting"

# Skip if already joined
if [[ -f "$STAMP" ]]; then
  echo "[$(date)] auto-join: already joined, skipping"
  exit 0
fi

# Wait for network
echo "[$(date)] auto-join: waiting for network..."
for i in $(seq 1 30); do
  if ping -c1 -W2 "$MASTER_IP" >/dev/null 2>&1; then
    echo "[$(date)] auto-join: master reachable"
    break
  fi
  sleep 5
done

if ! ping -c1 -W2 "$MASTER_IP" >/dev/null 2>&1; then
  echo "[$(date)] auto-join: ERROR — cannot reach master at $MASTER_IP"
  exit 1
fi

# Get join command from master (SSH key is restricted to only this command)
echo "[$(date)] auto-join: requesting join command from master..."
JOIN_CMD=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
  "${MASTER_USER}@${MASTER_IP}" 2>/dev/null)

if [[ -z "$JOIN_CMD" || ! "$JOIN_CMD" =~ "kubeadm join" ]]; then
  echo "[$(date)] auto-join: ERROR — did not receive a valid join command"
  exit 1
fi

echo "[$(date)] auto-join: joining cluster..."
$JOIN_CMD

# Mark as joined so we don't run again
mkdir -p /etc/kubernetes
touch "$STAMP"
echo "[$(date)] auto-join: successfully joined the cluster"
