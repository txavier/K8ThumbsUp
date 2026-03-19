# Kubernetes Cluster Quickstart (Calico CNI)

Master: **`<master-ip>`** (`<master-hostname>`)
Pod CIDR: **192.172.0.0/16** (avoids overlap with your LAN subnet)

---

## Master Node Setup

### 1. Initialize the cluster

```bash
sudo kubeadm init \
  --apiserver-advertise-address=<master-ip> \
  --pod-network-cidr=192.172.0.0/16 \
  --node-name=<master-hostname>
```

### Join command
```bash
# Run on master to get a fresh join command:
kubeadm token create --print-join-command
# Output looks like:
# kubeadm join <master-ip>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
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

2. **Install xorriso** (ISO repacking tool):
   ```bash
   sudo apt install xorriso
   ```

3. **Set up secrets** (WiFi credentials + user password):
   ```bash
   cp secrets.env.example secrets.env
   # Edit secrets.env with your WiFi SSID, password, and password hash
   ```
   Or skip this — the script will prompt for anything missing.

4. **Run the prep script** (extracts ISO, injects autoinstall, repacks, writes to USB):
   ```bash
   sudo bash prepare-usb.sh
   ```
   - Auto-detects the USB drive (or specify: `sudo bash prepare-usb.sh /dev/sdX`)
   - Shows drive info and offers to list current contents before erasing
   - Default login: `kube` / whatever password you provide

#### For each new machine

1. **Plug in USB, boot from it** — GRUB auto-starts the installer after 5 seconds
2. **Walk away** — Ubuntu installs, sets up containerd + kubeadm, and **auto-joins the cluster** on first boot
3. **Verify on the master:**
   ```bash
   kubectl get nodes
   ```
4. **Unplug the USB** and move to the next machine.

> **How auto-join works:** Each node has a restricted SSH key that can *only* run
> `kubeadm token create --print-join-command` on the master. A systemd service
> (`k8s-auto-join`) runs once on first boot, SSHs to the master, gets a fresh token,
> and joins. Logs are at `/var/log/k8s-auto-join.log` on the node.
> The key is in `keys/node-join` — if you regenerate it, re-run `prepare-usb.sh`.

#### Boot logs

If the USB is plugged in during boot, a systemd service (`save-boot-logs-usb`)
automatically saves `journalctl --boot`, `dmesg`, and failed service status to the
CIDATA partition under `boot-logs/<hostname>/<timestamp>/`.

To manually save logs from the installed machine's console, plug in the USB and run:
```bash
sudo ~/save-logs.sh
```
This mounts the CIDATA partition, saves all logs, and unmounts automatically.

To read the logs from the master (or any machine with the USB plugged in):
```bash
sudo mount /dev/sdb4 /mnt
ls /mnt/boot-logs/
cat /mnt/boot-logs/<hostname>/<timestamp>/journalctl-boot.log | tail -100
sudo umount /mnt
```

Install logs are also auto-saved at the end of each successful install under `install-logs/`.

#### Troubleshooting a failed install

If the autoinstall fails and drops you to a shell (or press **Alt+F2**), save the logs:

```bash
USB=$(blkid -t LABEL="CIDATA" -o device | head -1)
mkdir -p /tmp/usb && mount "$USB" /tmp/usb
mkdir -p /tmp/usb/install-logs/manual
cp /var/log/installer/*.log /tmp/usb/install-logs/manual/ 2>/dev/null
sync && umount /tmp/usb
```

---

### Option B: Manual (node-setup.sh)

If you prefer to install Ubuntu manually, or already have Ubuntu running on a machine.

#### What you need on the thumb drive

1. **Ubuntu Server 24.04 LTS ISO** — download from https://ubuntu.com/download/server
2. **`node-setup.sh`** — the script in this repo that installs containerd + kubeadm

Write the ISO to USB (this erases the drive):
```bash
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL | grep -v loop
sudo dd if=ubuntu-24.04*-live-server-amd64.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

#### For each new machine

1. **Boot from the USB drive** and select the Ubuntu Server ISO
2. **Install Ubuntu Server 24.04** (minimal install is fine, enable SSH)
3. **After install, reboot and copy the script** from another machine:
   ```bash
   scp <master-user>@<master-ip>:~/dev/kubernetes/node-setup.sh .
   sudo bash node-setup.sh
   ```
4. **Join the cluster** — on the master, get the join command:
   ```bash
   kubeadm token create --print-join-command
   ```
   Then run the output on the new node:
   ```bash
   sudo kubeadm join <master-ip>:6443 --token <token> \
     --discovery-token-ca-cert-hash sha256:<hash>
   ```
5. **Unplug the USB** and move to the next machine. Repeat steps 1–4.

#### Alternative: run the script over the network

If the new node is already on WiFi, you can skip the USB for the script:

```bash
# From the new node (after Ubuntu is installed):
scp <master-user>@<master-ip>:~/dev/kubernetes/node-setup.sh .
sudo bash node-setup.sh
```

### Regenerate join command

Tokens expire after 24h. To get a fresh one, run on the master:

```bash
kubeadm token create --print-join-command
```

---

## Notes

- The pod CIDR is **192.172.0.0/16** instead of Calico's default `192.168.0.0/16` to avoid conflicts with your LAN subnet.
- The Calico config is in `calico.yaml` alongside this file.
- `node-setup.sh` can be reused on any number of machines — it installs containerd, kubeadm, kubelet, kubectl, and configures the kernel.
