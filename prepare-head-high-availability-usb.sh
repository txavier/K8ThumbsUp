#!/usr/bin/env bash
# prepare-head-high-availability-usb.sh — Prepares a bootable USB for a Kubernetes
#                                          HA control-plane node that joins an existing cluster.
# Usage: sudo bash prepare-head-high-availability-usb.sh [/dev/sdX]
#        Credentials come from secrets.env (see secrets.env.example)
#
# This script will:
#   1. Generate an HA-join SSH keypair (if not present)
#   2. Install a helper script + authorized key on the existing master via SSH
#   3. Extract the Ubuntu Server ISO
#   4. Inject autoinstall config (WiFi creds, HA join script, SSH key)
#   5. Repack as a new ISO with xorriso
#   6. Write the ISO to the USB with dd
#   7. Create a CIDATA partition for the cloud-init NoCloud datasource
#
# On first boot the HA node will:
#   - SSH to the primary master to get a join token + certificate key
#   - kubeadm join --control-plane to become a secondary control-plane node
#   - Set up kubectl for the kube user
#
# Prerequisites:
#   - A running primary head node (built with prepare-head-usb.sh)
#   - Ubuntu Server 24.04 ISO in this directory (or set UBUNTU_ISO env var)
#   - xorriso (apt install xorriso)
#   - SSH access to the primary master (password or key-based)
#   - MASTER_IP and MASTER_USER set in secrets.env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/usb-helpers.sh"

UBUNTU_ISO="${UBUNTU_ISO:-}"
WORK_DIR="/tmp/iso-repack-ha-head"
CIDATA_MOUNT="/mnt/cidata"
HA_KEY="$SCRIPT_DIR/keys/ha-join"
HA_KEY_PUB="$SCRIPT_DIR/keys/ha-join.pub"

cleanup() {
  umount "$CIDATA_MOUNT" 2>/dev/null || true
}
trap cleanup EXIT

# --- Validation ---
validate_root
validate_command xorriso "sudo apt install xorriso"
validate_command ssh "sudo apt install openssh-client"

# Find USB drive — auto-detect if not specified
if [[ $# -ge 1 ]]; then
  USB_DEV="$1"
else
  ROOT_DISK="$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null || true)"
  mapfile -t USB_DEVS < <(
    lsblk -dno NAME,TRAN,RM,TYPE | awk '$2=="usb" && $3=="1" && $4=="disk" {print "/dev/"$1}' \
      | grep -v "/dev/${ROOT_DISK:-^$}" || true
  )
  if [[ ${#USB_DEVS[@]} -eq 0 ]]; then
    die "No USB drives found. Plug one in or specify the device: sudo bash $0 /dev/sdX"
  elif [[ ${#USB_DEVS[@]} -eq 1 ]]; then
    USB_DEV="${USB_DEVS[0]}"
    USB_INFO=$(lsblk -dno NAME,SIZE,MODEL "$USB_DEV" 2>/dev/null | xargs)
    echo "Auto-detected USB drive: $USB_DEV ($USB_INFO)"
  else
    echo "Multiple USB drives found:"
    for dev in "${USB_DEVS[@]}"; do
      info=$(lsblk -dno NAME,SIZE,MODEL "$dev" 2>/dev/null | xargs)
      echo "  $dev  ($info)"
    done
    die "Specify which one: sudo bash $0 /dev/sdX"
  fi
fi

[[ -b "$USB_DEV" ]] || die "$USB_DEV is not a block device"

# Safety check — refuse to target the boot disk
validate_not_boot_disk "$USB_DEV"

# Find Ubuntu ISO
find_ubuntu_iso "$SCRIPT_DIR"

# Load secrets from secrets.env if it exists
load_secrets "$SCRIPT_DIR/secrets.env"

# Get WiFi credentials
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASSWORD="${WIFI_PASSWORD:-}"
if [[ -z "$WIFI_SSID" ]]; then
  read -r -p "WiFi SSID: " WIFI_SSID
fi
if [[ -z "$WIFI_PASSWORD" ]]; then
  read -r -s -p "WiFi password: " WIFI_PASSWORD
  echo ""
fi
[[ -n "$WIFI_SSID" ]] || die "WiFi SSID is required"
[[ -n "$WIFI_PASSWORD" ]] || die "WiFi password is required"

# Get master connection info
MASTER_IP="${MASTER_IP:-}"
MASTER_USER="${MASTER_USER:-}"
if [[ -z "$MASTER_IP" ]]; then
  read -r -p "Primary master IP: " MASTER_IP
fi
if [[ -z "$MASTER_USER" ]]; then
  read -r -p "Primary master SSH user: " MASTER_USER
fi
[[ -n "$MASTER_IP" ]] || die "MASTER_IP is required"
[[ -n "$MASTER_USER" ]] || die "MASTER_USER is required"

# Get password hash
PASSWORD_HASH="${PASSWORD_HASH:-}"
if [[ -z "$PASSWORD_HASH" ]]; then
  read -r -p "User password (plaintext, will be hashed): " USER_PW
  [[ -n "$USER_PW" ]] || die "Password is required"
  command -v mkpasswd >/dev/null 2>&1 || die "mkpasswd is required: sudo apt install whois"
  PASSWORD_HASH=$(mkpasswd --method=SHA-512 "$USER_PW")
fi

# --- Step 0: Generate HA-join SSH keypair ---
echo ""
echo "=== [0/7] Checking HA-join SSH keypair ==="
mkdir -p "$SCRIPT_DIR/keys"
if [[ ! -f "$HA_KEY" ]]; then
  echo "  Generating new ed25519 keypair at $HA_KEY ..."
  ssh-keygen -t ed25519 -f "$HA_KEY" -N '' -C 'k8s-ha-join' >/dev/null 2>&1
  echo "  Done."
else
  echo "  Found existing keypair: $HA_KEY"
fi
validate_file "$HA_KEY" "HA-join private key not found at $HA_KEY"
validate_file "$HA_KEY_PUB" "HA-join public key not found at $HA_KEY_PUB"

echo ""
echo "============================================"
echo "  Kubernetes HA Control-Plane USB Prep"
echo "============================================"
echo "  USB device : $USB_DEV"
echo "  USB size   : $(lsblk -dno SIZE "$USB_DEV" 2>/dev/null | xargs)"
echo "  USB model  : $(lsblk -dno MODEL "$USB_DEV" 2>/dev/null | xargs)"
echo "  Ubuntu ISO : $(basename "$UBUNTU_ISO")"
echo "  Master     : ${MASTER_USER}@${MASTER_IP}"
echo "============================================"
echo ""
echo "WARNING: This will ERASE ALL DATA on $USB_DEV"
read -r -p "List contents before erasing? (y/N): " list_confirm
if [[ "$list_confirm" =~ ^[Yy]$ ]]; then
  echo ""
  for part in "${USB_DEV}"* "${USB_DEV}p"*; do
    [[ -b "$part" && "$part" != "$USB_DEV" ]] || continue
    label=$(lsblk -no LABEL "$part" 2>/dev/null | xargs)
    fstype=$(lsblk -no FSTYPE "$part" 2>/dev/null | xargs)
    size=$(lsblk -no SIZE "$part" 2>/dev/null | xargs)
    mnt=$(mktemp -d "/tmp/usb-preview-XXXX")
    echo "--- $part ($fstype, $size${label:+, label=$label}) ---"
    if mount -o ro "$part" "$mnt" 2>/dev/null; then
      ls -1 "$mnt" 2>/dev/null | head -20
      umount "$mnt" 2>/dev/null || true
    else
      echo "  (could not mount)"
    fi
    rmdir "$mnt" 2>/dev/null || true
  done
  echo ""
fi
read -r -p "Erase and continue? (y/N): " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted."

# --- Step 1: Install HA-join helper on the primary master ---
echo ""
echo "=== [1/7] Installing HA-join helper on primary master ==="
echo "  Connecting to ${MASTER_USER}@${MASTER_IP} ..."
echo "  (You may be prompted for the master's SSH password)"

HA_PUB_KEY=$(cat "$HA_KEY_PUB")
RESTRICTED_HA_KEY="command=\"/usr/local/bin/k8s-ha-join-info.sh\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding ${HA_PUB_KEY}"

# Install the helper script and SSH key on the master in a single SSH session
# Write the helper script content to a temp file, then scp + ssh install
HELPER_TMP=$(mktemp /tmp/k8s-ha-join-info.XXXX)
cat > "$HELPER_TMP" <<'HELPEREOF'
#!/bin/bash
set -euo pipefail
kubeadm token create --print-join-command 2>/dev/null
CERT_KEY=$(kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1)
echo "CERTIFICATE_KEY=$CERT_KEY"
HELPEREOF
chmod 644 "$HELPER_TMP"

# Copy the helper script to the master
scp -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
  "$HELPER_TMP" "${MASTER_USER}@${MASTER_IP}:/tmp/k8s-ha-join-info.sh"
rm -f "$HELPER_TMP"

# Install the helper script and SSH key on the master
ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
  "${MASTER_USER}@${MASTER_IP}" bash -s -- "$RESTRICTED_HA_KEY" <<'REMOTEOF'
set -euo pipefail
HA_AUTH_KEY="$1"

# Install the helper script
sudo mv /tmp/k8s-ha-join-info.sh /usr/local/bin/k8s-ha-join-info.sh
sudo chmod 755 /usr/local/bin/k8s-ha-join-info.sh
sudo chown root:root /usr/local/bin/k8s-ha-join-info.sh

# Add the HA-join public key to authorized_keys (idempotent)
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# Remove any old ha-join key entry, then add the current one
sed -i '/k8s-ha-join/d' ~/.ssh/authorized_keys
echo "$HA_AUTH_KEY" >> ~/.ssh/authorized_keys

echo "HA-join helper installed on master."
REMOTEOF

echo "  Master configured."

# --- Step 2: Extract the original ISO ---
echo ""
echo "=== [2/7] Extracting Ubuntu ISO ==="
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/extract"
xorriso -osirrox on -indev "$UBUNTU_ISO" -extract / "$WORK_DIR/extract" 2>/dev/null
chmod -R u+w "$WORK_DIR/extract"

# Extract MBR and EFI image for hybrid boot
dd if="$UBUNTU_ISO" bs=1 count=432 of="$WORK_DIR/mbr.bin" 2>/dev/null

ELTORITO=$(xorriso -indev "$UBUNTU_ISO" -report_el_torito as_mkisofs 2>/dev/null)
EFI_INTERVAL=$(echo "$ELTORITO" | grep -o 'appended_partition_2.*' | head -1 || true)
if [[ -n "$EFI_INTERVAL" ]]; then
  EFI_LINE=$(echo "$ELTORITO" | grep 'append_partition 2' | head -1)
  EFI_RANGE=$(echo "$EFI_LINE" | grep -oP '\d+d-\d+d' | head -1 || true)
  if [[ -n "$EFI_RANGE" ]]; then
    EFI_S=$(echo "$EFI_RANGE" | cut -dd -f1)
    EFI_E=$(echo "$EFI_RANGE" | cut -d- -f2 | tr -d 'd')
    dd if="$UBUNTU_ISO" bs=512 skip="$EFI_S" count=$((EFI_E - EFI_S + 1)) of="$WORK_DIR/efi.img" 2>/dev/null
  else
    die "Could not parse EFI partition range from ISO"
  fi
else
  die "Could not find EFI partition in ISO"
fi

# --- Step 3: Inject autoinstall config ---
echo ""
echo "=== [3/7] Injecting autoinstall config (HA control-plane) ==="

mkdir -p "$WORK_DIR/extract/nocloud"

# Read the HA-join private key for embedding in user-data
HA_PRIVATE_KEY=$(cat "$HA_KEY")

# Escape special chars for sed
SAFE_HASH=$(escape_for_sed "$PASSWORD_HASH")
SAFE_KEY=$(escape_for_sed "$HA_PRIVATE_KEY")

sed -e "s|__WIFI_SSID__|${WIFI_SSID}|g" \
    -e "s|__WIFI_PASSWORD__|${WIFI_PASSWORD}|g" \
    -e "s|__PASSWORD_HASH__|${SAFE_HASH}|g" \
    -e "s|__MASTER_IP__|${MASTER_IP}|g" \
    -e "s|__MASTER_USER__|${MASTER_USER}|g" \
    -e "s|      __HA_JOIN_KEY_PLACEHOLDER__|${SAFE_KEY}|" \
  "$SCRIPT_DIR/autoinstall/ha-head-user-data" > "$WORK_DIR/extract/nocloud/user-data"
echo "  user-data (HA control-plane with kubeadm join --control-plane)"

cp "$SCRIPT_DIR/autoinstall/meta-data" "$WORK_DIR/extract/nocloud/meta-data"

# Copy crypto scan script into the ISO
cp "$SCRIPT_DIR/scan.sh" "$WORK_DIR/extract/nocloud/scan.sh"
chmod 755 "$WORK_DIR/extract/nocloud/scan.sh"

# Generate autoinstall.yaml (same as user-data but without the #cloud-config header comments)
sed '1,5d' "$WORK_DIR/extract/nocloud/user-data" > "$WORK_DIR/extract/nocloud/autoinstall.yaml"

# Rewrite GRUB menu: require explicit selection to wipe & install
GRUB_CFG="$WORK_DIR/extract/boot/grub/grub.cfg"
if [[ -f "$GRUB_CFG" ]]; then
  write_grub_cfg "$GRUB_CFG" "Install Kubernetes HA Control-Plane Node"
fi

# --- Step 4: Repack the ISO ---
echo ""
echo "=== [4/7] Repacking ISO with xorriso ==="
ISO_OUT="$WORK_DIR/ubuntu-autoinstall-ha-head.iso"
xorriso -as mkisofs \
  -r -V 'Ubuntu-Server 24.04.4 LTS amd64' \
  --grub2-mbr "$WORK_DIR/mbr.bin" \
  -partition_offset 16 \
  --mbr-force-bootable \
  -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b "$WORK_DIR/efi.img" \
  -appended_part_as_gpt \
  -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
  -c '/boot/grub/boot.cat' \
  -b '/boot/grub/i386-pc/eltorito.img' \
  -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
  -eltorito-alt-boot \
  -e '--interval:appended_partition_2:::' \
  -no-emul-boot \
  -o "$ISO_OUT" "$WORK_DIR/extract/" 2>&1 | tail -3
echo "  ISO created: $ISO_OUT"

# --- Step 5: Write ISO to USB with dd ---
echo ""
echo "=== [5/7] Writing ISO to USB ==="
umount "${USB_DEV}"* 2>/dev/null || true
dd if="$ISO_OUT" of="$USB_DEV" bs=4M status=progress conv=fsync 2>&1

# --- Step 6: Create CIDATA partition ---
echo ""
echo "=== [6/7] Creating CIDATA partition ==="
sgdisk -e "$USB_DEV"

LAST_SECTOR=$(sgdisk -p "$USB_DEV" | awk '/^ *[0-9]/{end=$3} END{print end}')
CIDATA_START=$((LAST_SECTOR + 1))

sgdisk -n 4:"$CIDATA_START":+100M -t 4:0700 -c 4:CIDATA "$USB_DEV"
partprobe "$USB_DEV"
sleep 2

CIDATA_PART="${USB_DEV}4"
[[ -b "$CIDATA_PART" ]] || CIDATA_PART="${USB_DEV}p4"
[[ -b "$CIDATA_PART" ]] || die "Cannot find CIDATA partition"

mkfs.vfat -F 16 -n CIDATA "$CIDATA_PART"

mkdir -p "$CIDATA_MOUNT"
mount "$CIDATA_PART" "$CIDATA_MOUNT"
cp "$WORK_DIR/extract/nocloud/user-data" "$CIDATA_MOUNT/user-data"
cp "$WORK_DIR/extract/nocloud/meta-data" "$CIDATA_MOUNT/meta-data"
sync
umount "$CIDATA_MOUNT"

# --- Step 7: Done ---
echo ""
echo "============================================"
echo "  HA Control-Plane USB drive is ready!"
echo "============================================"
echo ""
echo "  Boot the target machine from this USB — Ubuntu will"
echo "  install, set up containerd + kubeadm, and join the"
echo "  existing cluster as a secondary control-plane node."
echo ""
echo "  After first boot, verify with:"
echo "    ssh kube@<ha-node-ip>"
echo "    kubectl get nodes"
echo ""
echo "  You should see both the original head and this node"
echo "  listed as control-plane nodes."
echo ""
echo "  NOTE: For full HA failover, configure a load balancer"
echo "  (e.g. HAProxy, keepalived VIP) in front of all"
echo "  control-plane API servers on port 6443."
echo ""
