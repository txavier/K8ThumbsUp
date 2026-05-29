#!/usr/bin/env bash
# auto-join.sh — Automatically joins this node to the Kubernetes cluster.
# Runs on first boot via systemd. SSHs to the master to get a fresh join token.

set -euo pipefail

# Set these before running, or source secrets.env
MASTER_IP="${MASTER_IP:?Set MASTER_IP}"
MASTER_USER="${MASTER_USER:?Set MASTER_USER}"
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

# Wait for network (up to 10 min — WiFi DKMS firstboot may be slow)
echo "[$(date)] auto-join: waiting for network..."
for i in $(seq 1 120); do
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

# Bootstrap k8s packages if the installer deferred install (no DNS at install time)
if ! command -v kubeadm >/dev/null 2>&1 || ! command -v containerd >/dev/null 2>&1; then
  echo "[$(date)] auto-join: kubeadm/containerd missing, installing now..."
  mkdir -p /etc/apt/keyrings
  if [[ ! -s /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]]; then
    curl -fsSL --max-time 30 https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key \
      | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  fi
  if [[ ! -f /etc/apt/sources.list.d/kubernetes.list ]]; then
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /" \
      > /etc/apt/sources.list.d/kubernetes.list
  fi
  mkdir -p /etc/apt/preferences.d
  printf 'Package: containerd\nPin: version 1.7.28*\nPin-Priority: 1001\n' \
    > /etc/apt/preferences.d/containerd-pin
  apt-get update -qq
  apt-get install -y -qq containerd kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl
  mkdir -p /etc/containerd
  containerd config default > /etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  systemctl enable --now containerd
  systemctl enable kubelet
  echo "[$(date)] auto-join: k8s packages installed"
fi

# Verify kubeadm is actually installed (autoinstall sometimes fails to install it)
if ! command -v kubeadm >/dev/null 2>&1; then
  echo "[$(date)] auto-join: ERROR — kubeadm not installed; cannot join cluster"
  exit 1
fi

# Get join command from master.  The SSH forced-command on the master is
# the k8s-print-join-command.sh wrapper; it reads our hostname from
# $SSH_ORIGINAL_COMMAND and deletes any stale Node object before printing
# a fresh join command.  This makes reimaging a node hands-off.
echo "[$(date)] auto-join: requesting join command from master (hostname=$(hostname))..."
JOIN_CMD=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
  "${MASTER_USER}@${MASTER_IP}" "$(hostname)" 2>/dev/null)

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
