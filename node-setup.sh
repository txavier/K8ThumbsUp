#!/usr/bin/env bash
# node-setup.sh — Prepares a fresh Ubuntu 24.04 machine to join the Kubernetes cluster.
# Usage: sudo bash node-setup.sh
#
# After this script completes, run the kubeadm join command from the master:
#   kubeadm token create --print-join-command   (run on master to get it)

set -euo pipefail

KUBE_VERSION="1.35"
# Set MASTER_IP env var before running, or edit this line
MASTER_IP="${MASTER_IP:?Set MASTER_IP — e.g. export MASTER_IP=10.0.0.1}"

if [[ $EUID -ne 0 ]]; then
  echo "Error: run this script as root (sudo bash node-setup.sh)"
  exit 1
fi

echo "=== [1/9] Keeping system awake with lid closed ==="
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/lid.conf <<EOF
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF
systemctl restart systemd-logind

echo "=== [2/9] Disabling swap ==="
swapoff -a
sed -i '/\sswap\s/s/^/#/' /etc/fstab

echo "=== [3/9] Loading kernel modules ==="
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

echo "=== [4/9] Setting sysctl params ==="
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null 2>&1

echo "=== [5/9] Installing containerd ==="
apt-get update -qq
apt-get install -y -qq containerd >/dev/null
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
# Enable systemd cgroup driver
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

echo "=== [6/9] Adding Kubernetes apt repo ==="
apt-get install -y -qq apt-transport-https ca-certificates curl gpg >/dev/null
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg 2>/dev/null
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

echo "=== [7/9] Installing kubeadm, kubelet, kubectl ==="
apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl >/dev/null
apt-mark hold kubelet kubeadm kubectl

echo "=== [8/9] Installing and enabling SSH ==="
apt-get install -y -qq openssh-server >/dev/null
systemctl enable ssh
systemctl start ssh

echo "=== [9/9] Enabling kubelet ==="
systemctl enable kubelet

echo ""
echo "============================================"
echo "  Node is ready to join the cluster!"
echo "============================================"
echo ""
echo "Run the join command from the master. To get it, run on the master:"
echo "  kubeadm token create --print-join-command"
echo ""
echo "Then paste and run the output here, e.g.:"
echo "  sudo kubeadm join ${MASTER_IP}:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>"
echo ""
