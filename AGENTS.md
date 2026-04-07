# K8ThumbsUp — Project Guidelines

## Security

- **Never commit PII (personally identifiable information) to this public repository.** This includes passwords, password hashes, SSH private keys, WiFi credentials, IP addresses, and usernames. All secrets go in `secrets.env` (gitignored).
- SSH keys live in `keys/` (gitignored). The auto-join key is restricted to a single forced command on the master (`kubeadm token create --print-join-command`).
- Autoinstall templates use `__PLACEHOLDER__` tokens (e.g. `__WIFI_SSID__`, `__PASSWORD_HASH__`) that are substituted at build time by `prepare-usb.sh`. Never replace placeholders with real values in tracked files.

## What This Project Does

Automated Kubernetes cluster provisioning via bootable USB. Insert a USB drive into any laptop, boot it, walk away — Ubuntu 24.04 installs, containerd + kubeadm are configured, and the node auto-joins the cluster. Zero interaction required after the USB is prepared.

## Architecture

- **Master node**: set up manually (`kubeadm init`, Calico CNI, SSH forced-command key)
- **Worker nodes**: provisioned automatically via USB autoinstall + first-boot auto-join
- **Monitoring**: optional Prometheus + Grafana stack via Helm (`deploy-monitoring.sh`)
- **Storage**: Rook/Ceph OSD partitioning on nodes with >100G disks (45G root LV, rest for Ceph)

## Key Components

| Script / File | Purpose |
|---|---|
| `prepare-usb.sh` | Build bootable USB: extract ISO, inject config, repack, write to drive |
| `prepare-head-usb.sh` | Same as above but for the head/master node |
| `node-setup.sh` | Manual alternative — run on a fresh Ubuntu 24.04 box to prepare it as a worker |
| `auto-join.sh` | First-boot script: SSH to master for join token, run `kubeadm join` |
| `deploy-monitoring.sh` | Deploy kube-prometheus-stack (Grafana on NodePort 30300) |
| `autoinstall/user-data` | Cloud-init autoinstall template for worker nodes |
| `autoinstall/head-user-data` | Cloud-init autoinstall template for head/master node |
| `lib/usb-helpers.sh` | Shared helper functions for USB preparation scripts |
| `calico.yaml` | Calico CNI manifest (pod CIDR: 192.172.0.0/16) |

## Secrets Management

| File | Tracked | Contains |
|---|---|---|
| `secrets.env.example` | Yes | Template showing required variables |
| `secrets.env` | **No** (gitignored) | Real WiFi creds, master IP/user, password hash |
| `keys/` | **No** (gitignored) | ED25519 SSH keypair for auto-join |

## Build & Test

```bash
# Prepare a worker USB (auto-detects USB drive)
sudo bash prepare-usb.sh

# Prepare a head/master USB
sudo bash prepare-head-usb.sh

# Manual node setup (if not using USB autoinstall)
sudo MASTER_IP=10.0.0.1 bash node-setup.sh

# Run unit tests for USB helper functions
bats tests/usb-helpers.bats

# Deploy monitoring
bash deploy-monitoring.sh
```

## Conventions

- **Kubernetes 1.35** on **Ubuntu 24.04 LTS** with **containerd** as the runtime
- Shell scripts use `set -euo pipefail` and are written for bash
- Autoinstall late-commands: file-write operations come first (before chroot/apt), because subiquity stops on failure
- Laptop lid close is set to `ignore` (nodes stay awake on battery) via `logind.conf.d/lid.conf`
- Hostnames auto-generate as `k8s-node-<MAC_SUFFIX>` unless `NODE_HOSTNAME` is set in user-data
- The GRUB menu defaults to "Boot from disk (no changes)" with a 30-second timeout — the install option must be explicitly selected to avoid accidental wipes
- Branches: `main` is the primary branch (matches `origin/main`)

## Documentation

| File | Content |
|---|---|
| `README.md` | Architecture, quick start, troubleshooting |
| `README-HEAD.md` | Head/master node documentation |
| `quickstart.md` | Detailed step-by-step worker provisioning guide |
| `quickstart-head.md` | Step-by-step head node setup guide |
| `grafana-readme.md` | Grafana dashboards, access, redeployment |
