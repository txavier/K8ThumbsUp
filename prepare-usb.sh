#!/usr/bin/env bash
# prepare-usb.sh — Prepares a Ventoy USB drive with Ubuntu autoinstall for Kubernetes nodes.
# Usage: sudo bash prepare-usb.sh /dev/sdX
#
# This script will:
#   1. Install Ventoy on the USB drive (ERASES ALL DATA)
#   2. Copy the Ubuntu Server ISO
#   3. Copy autoinstall config + Ventoy config
#
# Prerequisites:
#   - Ubuntu Server 24.04 ISO in this directory (or set UBUNTU_ISO env var)
#   - Internet access (to download Ventoy if not already present)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENTOY_VERSION="1.1.05"
UBUNTU_ISO="${UBUNTU_ISO:-}"
MOUNT_POINT="/mnt/ventoy_usb"

# --- Helpers ---
die() { echo "Error: $1" >&2; exit 1; }

cleanup() {
  if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    umount "$MOUNT_POINT" 2>/dev/null || true
  fi
  rmdir "$MOUNT_POINT" 2>/dev/null || true
}
trap cleanup EXIT

# --- Validation ---
[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0 /dev/sdX"
[[ $# -ge 1 ]]    || die "Usage: sudo bash $0 /dev/sdX"

USB_DEV="$1"
[[ -b "$USB_DEV" ]] || die "$USB_DEV is not a block device"

# Safety check — refuse to target the boot disk
ROOT_DISK="$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null || true)"
if [[ -n "$ROOT_DISK" && "$USB_DEV" == "/dev/$ROOT_DISK" ]]; then
  die "$USB_DEV appears to be your boot disk. Refusing to continue."
fi

# Find Ubuntu ISO
if [[ -z "$UBUNTU_ISO" ]]; then
  UBUNTU_ISO="$(find "$SCRIPT_DIR" -maxdepth 1 -name 'ubuntu-24.04*-live-server-amd64.iso' -print -quit 2>/dev/null || true)"
fi
[[ -n "$UBUNTU_ISO" && -f "$UBUNTU_ISO" ]] || die "Ubuntu Server ISO not found.
  Download it from https://ubuntu.com/download/server and place it in $SCRIPT_DIR
  or set UBUNTU_ISO=/path/to/file.iso"

echo "============================================"
echo "  Kubernetes Node USB Prep"
echo "============================================"
echo "  USB device : $USB_DEV"
echo "  Ubuntu ISO : $(basename "$UBUNTU_ISO")"
echo "============================================"
echo ""
echo "WARNING: This will ERASE ALL DATA on $USB_DEV"
read -r -p "Continue? (y/N): " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted."

# --- Step 1: Download and install Ventoy ---
echo ""
echo "=== [1/4] Installing Ventoy on $USB_DEV ==="
VENTOY_DIR="/tmp/ventoy-${VENTOY_VERSION}"
if [[ ! -d "$VENTOY_DIR" ]]; then
  VENTOY_TAR="ventoy-${VENTOY_VERSION}-linux.tar.gz"
  VENTOY_URL="https://github.com/ventoy/Ventoy/releases/download/v${VENTOY_VERSION}/${VENTOY_TAR}"
  echo "Downloading Ventoy v${VENTOY_VERSION}..."
  curl -fSL -o "/tmp/${VENTOY_TAR}" "$VENTOY_URL"
  tar xzf "/tmp/${VENTOY_TAR}" -C /tmp
  rm -f "/tmp/${VENTOY_TAR}"
fi

# Install Ventoy non-interactively
echo "Writing Ventoy to $USB_DEV..."
bash "${VENTOY_DIR}/Ventoy2Disk.sh" -i -g "$USB_DEV"

# Wait for partitions to appear
echo "Waiting for partitions..."
sleep 3
partprobe "$USB_DEV" 2>/dev/null || true
sleep 2

# --- Step 2: Mount the data partition ---
echo ""
echo "=== [2/4] Mounting USB data partition ==="
# Ventoy data partition is partition 1
USB_PART="${USB_DEV}1"
[[ -b "$USB_PART" ]] || USB_PART="${USB_DEV}p1"
[[ -b "$USB_PART" ]] || die "Cannot find data partition on $USB_DEV"

mkdir -p "$MOUNT_POINT"
mount "$USB_PART" "$MOUNT_POINT"

# --- Step 3: Copy Ubuntu ISO ---
echo ""
echo "=== [3/4] Copying Ubuntu ISO (this may take a few minutes) ==="
ISO_NAME="$(basename "$UBUNTU_ISO")"
cp -v "$UBUNTU_ISO" "${MOUNT_POINT}/${ISO_NAME}"

# --- Step 4: Copy autoinstall + Ventoy config ---
echo ""
echo "=== [4/4] Copying autoinstall and Ventoy config ==="
mkdir -p "${MOUNT_POINT}/ventoy/autoinstall"

# Inject the SSH private key into user-data (replaces placeholder)
NODE_KEY="$SCRIPT_DIR/keys/node-join"
[[ -f "$NODE_KEY" ]] || die "SSH key not found at $NODE_KEY — run: ssh-keygen -t ed25519 -f $NODE_KEY -N '' -C k8s-node-auto-join"

KEY_CONTENT=$(sed 's/^/      /' "$NODE_KEY")
sed "s|      __NODE_JOIN_KEY_PLACEHOLDER__|${KEY_CONTENT//$'\n'/\\n}|" \
  "$SCRIPT_DIR/autoinstall/user-data" > "${MOUNT_POINT}/ventoy/autoinstall/user-data"
echo "  user-data (with key injected)"

cp -v "$SCRIPT_DIR/autoinstall/meta-data" "${MOUNT_POINT}/ventoy/autoinstall/meta-data"

# Write ventoy.json, matching the actual ISO filename
cat > "${MOUNT_POINT}/ventoy/ventoy.json" <<EOF
{
    "control": [
        {
            "VTOY_DEFAULT_SEARCH_ROOT": "/ventoy"
        }
    ],
    "auto_install": [
        {
            "image": "/${ISO_NAME}",
            "template": "/ventoy/autoinstall/user-data"
        }
    ]
}
EOF

# Also copy node-setup.sh as a backup option
if [[ -f "$SCRIPT_DIR/node-setup.sh" ]]; then
  cp -v "$SCRIPT_DIR/node-setup.sh" "${MOUNT_POINT}/node-setup.sh"
fi

sync
umount "$MOUNT_POINT"

echo ""
echo "============================================"
echo "  USB drive is ready!"
echo "============================================"
echo ""
echo "  Boot any machine from this USB to install"
echo "  Ubuntu + Kubernetes node prerequisites"
echo "  automatically."
echo ""
echo "  After install, SSH in and join the cluster:"
echo "    ssh kube@<node-ip>"
echo "    sudo kubeadm join REDACTED_IP:6443 \\"
echo "      --token <token> \\"
echo "      --discovery-token-ca-cert-hash sha256:<hash>"
echo ""
echo "  Get the join command from the master:"
echo "    kubeadm token create --print-join-command"
echo ""
