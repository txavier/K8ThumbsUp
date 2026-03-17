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

## Worker Node Setup (USB Thumb Drive)

### What you need on the thumb drive

1. **Ubuntu Server 24.04 LTS ISO** — download from https://ubuntu.com/download/server
2. **`node-setup.sh`** — the script in this repo that installs containerd + kubeadm

Use a tool like [Ventoy](https://www.ventoy.net/) on the USB drive. Ventoy lets you boot ISOs
directly and still store extra files on the same drive:

```bash
# On the master, install Ventoy to the USB (e.g. /dev/sdb — check with lsblk)
# Download Ventoy from https://www.ventoy.net/en/download.html
tar xzf ventoy-*-linux.tar.gz
cd ventoy-*
sudo bash Ventoy2Disk.sh -i /dev/sdX   # replace sdX with your USB device
```

Then copy onto the USB drive:
- The Ubuntu Server 24.04 ISO
- `node-setup.sh` from this repo

### For each new machine

1. **Boot from the USB drive** and select the Ubuntu Server ISO
2. **Install Ubuntu Server 24.04** (minimal install is fine, enable SSH)
3. **After install, reboot and mount the USB** to get the script:
   ```bash
   sudo mount /dev/sdb1 /mnt   # or wherever the Ventoy data partition is
   sudo bash /mnt/node-setup.sh
   sudo umount /mnt
   ```
4. **Join the cluster** — on the master, get the join command:
   ```bash
   kubeadm token create --print-join-command
   ```
   Then run the output on the new node:
   ```bash
   sudo kubeadm join REDACTED_IP:6443 --token <token> \
     --discovery-token-ca-cert-hash sha256:<hash>
   ```
5. **Unplug the USB** and move to the next machine. Repeat steps 1–4.

### Alternative: run the script over the network

If the new node is already on WiFi, you can skip the USB for the script:

```bash
# From the new node (after Ubuntu is installed):
scp theo@REDACTED_IP:~/dev/kubernetes/node-setup.sh .
sudo bash node-setup.sh
```

### Regenerate join command

Tokens expire after 24h. To get a fresh one, run on the master:

```bash
kubeadm token create --print-join-command
```

---

## Notes

- The pod CIDR is **192.172.0.0/16** instead of Calico's default `192.168.0.0/16` to avoid conflicts with the WiFi LAN (`REDACTED_SUBNET/24`).
- The Calico config is in `calico.yaml` alongside this file.
- `node-setup.sh` can be reused on any number of machines — it installs containerd, kubeadm, kubelet, kubectl, and configures the kernel.
