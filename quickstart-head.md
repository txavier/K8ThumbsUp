# prepare-head-usb.sh — Quickstart

Flash a USB that rebuilds the Kubernetes head (control-plane) node from scratch.

## Prerequisites

- Ubuntu Server 24.04 ISO in the repo directory ([download](https://ubuntu.com/download/server))
- `sudo apt install xorriso`
- SSH keypair: `ssh-keygen -t ed25519 -f keys/node-join -N '' -C k8s-node-auto-join`

## Usage

```bash
# Option A — secrets.env (recommended)
cp secrets.env.example secrets.env   # fill in WIFI_SSID, WIFI_PASSWORD, PASSWORD_HASH
sudo bash prepare-head-usb.sh        # auto-detects USB

# Option B — inline
sudo WIFI_SSID="my-ssid" WIFI_PASSWORD="my-pw" bash prepare-head-usb.sh /dev/sdX
```

The script extracts the ISO, injects autoinstall config, repacks, writes to USB, and creates a CIDATA partition. Override pod CIDR with `POD_CIDR=10.244.0.0/16` if needed (default: `192.172.0.0/16`).

## Boot

Plug USB into the target machine and boot from it. Select **"WIPE DISK & Install Kubernetes HEAD Node"** from GRUB (30 s timeout, default is safe boot-from-disk). Walk away — fully automated from here.

## Verify

```bash
ssh kube@<head-ip>
kubectl get nodes        # k8s-head Ready
kubectl get pods -A      # calico + coredns Running
```

Workers auto-join once they can reach this IP. If the IP changed, re-burn worker USBs with the new `MASTER_IP`.
