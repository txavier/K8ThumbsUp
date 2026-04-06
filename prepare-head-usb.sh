#!/usr/bin/env bash
# prepare-head-usb.sh — Prepares a bootable USB for a Kubernetes HEAD (control-plane) node.
#                        Use this to quickly rebuild the master if it goes down.
# Usage: sudo WIFI_SSID="your-ssid" WIFI_PASSWORD="your-pw" bash prepare-head-usb.sh /dev/sdX
#        or put credentials in secrets.env (see secrets.env.example)
#
# This script will:
#   1. Extract the Ubuntu Server ISO
#   2. Inject autoinstall config (WiFi creds, SSH key, kubeadm init, Calico CNI)
#   3. Repack as a new ISO with xorriso
#   4. Write the ISO to the USB with dd
#   5. Create a CIDATA partition for the cloud-init NoCloud datasource
#
# On first boot the head node will:
#   - kubeadm init with the configured pod CIDR
#   - Install Calico CNI
#   - Set up kubectl for the kube user
#   - Accept worker auto-join via the node-join SSH key
#
# Prerequisites:
#   - Ubuntu Server 24.04 ISO in this directory (or set UBUNTU_ISO env var)
#   - xorriso (apt install xorriso)
#   - keys/node-join SSH keypair (ssh-keygen -t ed25519 -f keys/node-join -N '' -C k8s-node-auto-join)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/usb-helpers.sh"

UBUNTU_ISO="${UBUNTU_ISO:-}"
WORK_DIR="/tmp/iso-repack-head"
CIDATA_MOUNT="/mnt/cidata"

cleanup() {
  umount "$CIDATA_MOUNT" 2>/dev/null || true
}
trap cleanup EXIT

# --- Validation ---
validate_root
validate_command xorriso "sudo apt install xorriso"

# Find USB drive — auto-detect if not specified
if [[ $# -ge 1 ]]; then
  USB_DEV="$1"
else
  # Find removable USB block devices (exclude the boot disk)
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

# SSH key for worker auto-join (we need the PUBLIC key to install in authorized_keys)
NODE_KEY_PUB="$SCRIPT_DIR/keys/node-join.pub"
validate_file "$NODE_KEY_PUB" "SSH public key not found at $NODE_KEY_PUB — run: ssh-keygen -t ed25519 -f $SCRIPT_DIR/keys/node-join -N '' -C k8s-node-auto-join"

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

# Pod network CIDR (must match Calico config)
POD_CIDR="${POD_CIDR:-192.172.0.0/16}"

# Get password hash
PASSWORD_HASH="${PASSWORD_HASH:-}"
if [[ -z "$PASSWORD_HASH" ]]; then
  read -r -p "User password (plaintext, will be hashed): " USER_PW
  [[ -n "$USER_PW" ]] || die "Password is required"
  command -v mkpasswd >/dev/null 2>&1 || die "mkpasswd is required: sudo apt install whois"
  PASSWORD_HASH=$(mkpasswd --method=SHA-512 "$USER_PW")
fi

echo "============================================"
echo "  Kubernetes HEAD Node USB Prep"
echo "============================================"
echo "  USB device : $USB_DEV"
echo "  USB size   : $(lsblk -dno SIZE "$USB_DEV" 2>/dev/null | xargs)"
echo "  USB model  : $(lsblk -dno MODEL "$USB_DEV" 2>/dev/null | xargs)"
echo "  Ubuntu ISO : $(basename "$UBUNTU_ISO")"
echo "  Pod CIDR   : $POD_CIDR"
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

# --- Step 1: Extract the original ISO ---
echo ""
echo "=== [1/5] Extracting Ubuntu ISO ==="
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/extract"
xorriso -osirrox on -indev "$UBUNTU_ISO" -extract / "$WORK_DIR/extract" 2>/dev/null
chmod -R u+w "$WORK_DIR/extract"

# Extract MBR and EFI image for hybrid boot
dd if="$UBUNTU_ISO" bs=1 count=432 of="$WORK_DIR/mbr.bin" 2>/dev/null

# Find the EFI partition offset+size from xorriso's el-torito report
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

# --- Step 2: Inject autoinstall config ---
echo ""
echo "=== [2/5] Injecting autoinstall config (head node) ==="

# Create NoCloud datasource directory inside the ISO
mkdir -p "$WORK_DIR/extract/nocloud"

# Build the authorized_keys line — restrict to kubeadm token command only
PUB_KEY=$(cat "$NODE_KEY_PUB")
RESTRICTED_KEY="command=\"kubeadm token create --print-join-command\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding ${PUB_KEY}"

# Escape special chars for sed
SAFE_HASH=$(escape_for_sed "$PASSWORD_HASH")
SAFE_KEY=$(escape_for_sed "$RESTRICTED_KEY")

sed -e "s|__WIFI_SSID__|${WIFI_SSID}|g" \
    -e "s|__WIFI_PASSWORD__|${WIFI_PASSWORD}|g" \
    -e "s|__PASSWORD_HASH__|${SAFE_HASH}|g" \
    -e "s|__POD_CIDR__|${POD_CIDR}|g" \
    -e "s|      __NODE_JOIN_AUTHORIZED_KEY__|      ${SAFE_KEY}|" \
  "$SCRIPT_DIR/autoinstall/head-user-data" > "$WORK_DIR/extract/nocloud/user-data"
echo "  user-data (head node with kubeadm init + Calico + SSH)"

cp "$SCRIPT_DIR/autoinstall/meta-data" "$WORK_DIR/extract/nocloud/meta-data"

# Generate autoinstall.yaml (same as user-data but without the #cloud-config header comments)
sed '1,5d' "$WORK_DIR/extract/nocloud/user-data" > "$WORK_DIR/extract/nocloud/autoinstall.yaml"

# Rewrite GRUB menu: require explicit selection to wipe & install
GRUB_CFG="$WORK_DIR/extract/boot/grub/grub.cfg"
if [[ -f "$GRUB_CFG" ]]; then
  write_grub_cfg "$GRUB_CFG" "Install Kubernetes HEAD Node"
fi

# --- Step 3: Repack the ISO ---
echo ""
echo "=== [3/5] Repacking ISO with xorriso ==="
ISO_OUT="$WORK_DIR/ubuntu-autoinstall-head.iso"
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

# --- Step 4: Write ISO to USB with dd ---
echo ""
echo "=== [4/5] Writing ISO to USB ==="
umount "${USB_DEV}"* 2>/dev/null || true
dd if="$ISO_OUT" of="$USB_DEV" bs=4M status=progress conv=fsync 2>&1

# --- Step 5: Create CIDATA partition ---
echo ""
echo "=== [5/5] Creating CIDATA partition ==="
sgdisk -e "$USB_DEV"

# Find where the existing partitions end
LAST_SECTOR=$(sgdisk -p "$USB_DEV" | awk '/^ *[0-9]/{end=$3} END{print end}')
CIDATA_START=$((LAST_SECTOR + 1))

sgdisk -n 4:"$CIDATA_START":+100M -t 4:0700 -c 4:CIDATA "$USB_DEV"
partprobe "$USB_DEV"
sleep 2

# Determine partition device name
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

echo ""
echo "============================================"
echo "  HEAD node USB drive is ready!"
echo "============================================"
echo ""
echo "  Boot the target machine from this USB — Ubuntu will"
echo "  install, set up containerd + kubeadm, and initialise"
echo "  the Kubernetes control plane with Calico CNI."
echo ""
echo "  After first boot, verify with:"
echo "    ssh kube@<head-node-ip>"
echo "    kubectl get nodes"
echo "    kubectl get pods -A"
echo ""
echo "  Workers with existing USB drives will auto-join"
echo "  once the head node is reachable at its new IP."
echo ""
echo "  NOTE: If the head node IP changes, you will need to"
echo "  re-burn worker USB drives with the new MASTER_IP."
echo ""
