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

### Option A: Fully Automated (Autoinstall) — recommended

Ubuntu + Kubernetes installed in one shot, no interaction needed.

#### Prepare the USB drive

1. **Download the Ubuntu Server 24.04 ISO** into this directory:
   https://ubuntu.com/download/server

2. **Run the prep script** (downloads Ventoy, formats USB, copies everything):
   ```bash
   sudo bash prepare-usb.sh /dev/sdX   # replace sdX with your USB device (check with lsblk)
   ```

3. **Edit `user-data`** before first use (optional):
   - Default login: `kube` / `changeme`
   - To change the password, generate a new hash: `mkpasswd --method=SHA-512 yourpassword`
   - Update the `password` field in `autoinstall/user-data`, then re-run `prepare-usb.sh`

#### For each new machine

1. **Plug in USB, boot from it** — select the Ubuntu ISO
2. **Walk away** — Ubuntu installs, sets up containerd + kubeadm automatically
3. **After reboot, SSH in** from the master and join the cluster:
   ```bash
   # On the master — get the join command:
   kubeadm token create --print-join-command

   # SSH into the new node and run it:
   ssh kube@<node-ip>
   sudo kubeadm join REDACTED_IP:6443 --token <token> \
     --discovery-token-ca-cert-hash sha256:<hash>
   ```
4. **Unplug the USB** and move to the next machine.

---

### Option B: Manual (node-setup.sh)

If you prefer to install Ubuntu manually, or already have Ubuntu running on a machine.

#### What you need on the thumb drive

1. **Ubuntu Server 24.04 LTS ISO** — download from https://ubuntu.com/download/server
2. **`node-setup.sh`** — the script in this repo that installs containerd + kubeadm

Use Ventoy so the USB can hold both the ISO and the script:

```bash
sudo bash Ventoy2Disk.sh -i /dev/sdX
```

Then copy onto the USB drive:
- The Ubuntu Server 24.04 ISO
- `node-setup.sh` from this repo

#### For each new machine

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

#### Alternative: run the script over the network

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
