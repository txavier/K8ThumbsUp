# Kubernetes Cluster Quickstart (Calico CNI)

Master: **REDACTED_IP** (`REDACTED_HOSTNAME`)
Pod CIDR: **192.172.0.0/16** (avoids overlap with WiFi subnet `REDACTED_SUBNET/24`)

---

## Master Node Setup

### 1. Initialize the cluster

```bash
sudo kubeadm init \
  --apiserver-advertise-address=REDACTED_IP \
  --pod-network-cidr=192.172.0.0/16 \
  --node-name=REDACTED_HOSTNAME
```

### Join command
```bash
kubeadm join REDACTED_IP:6443 --token REDACTED_TOKEN --discovery-token-ca-cert-hash sha256:REDACTED_HASH 
```

### 2. Set up kubeconfig

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### 3. Install the Tigera Calico operator

```bash
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.2/manifests/tigera-operator.yaml
```

### 4. Install Calico CNI

```bash
kubectl apply -f calico.yaml
```

---

## Worker Node Setup

Each worker needs `kubeadm`, `kubelet`, `kubectl`, and a container runtime (containerd) installed.

After `kubeadm init` succeeds on the master, it prints a join command. Run it on each worker:

```bash
sudo kubeadm join REDACTED_IP:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

To regenerate the join command on the master:

```bash
kubeadm token create --print-join-command
```

---

## Notes

- The pod CIDR is **192.172.0.0/16** instead of Calico's default `192.168.0.0/16` to avoid conflicts with the WiFi LAN (`REDACTED_SUBNET/24`).
- The Calico config is in `calico.yaml` alongside this file.
