#!/usr/bin/env bash
# prepare-usb.sh — Prepares a bootable USB with a repacked Ubuntu autoinstall ISO
#                   for fully automated Kubernetes node provisioning.
# Usage: sudo WIFI_SSID="your-ssid" WIFI_PASSWORD="your-pw" bash prepare-usb.sh /dev/sdX
#        or put credentials in secrets.env (see secrets.env.example)
#
# This script will:
#   1. Extract the Ubuntu Server ISO
#   2. Inject autoinstall config (WiFi creds, SSH key, GRUB kernel cmdline)
#   3. Repack as a new ISO with xorriso
#   4. Write the ISO to the USB with dd
#   5. Create a CIDATA partition for the cloud-init NoCloud datasource
#
# Prerequisites:
#   - Ubuntu Server 24.04 ISO in this directory (or set UBUNTU_ISO env var)
#   - xorriso (apt install xorriso)
#   - keys/node-join SSH keypair (ssh-keygen -t ed25519 -f keys/node-join -N '' -C k8s-node-auto-join)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/usb-helpers.sh"

# Load build config (Ceph storage reservation, LV size, etc.)
if [[ -f "$SCRIPT_DIR/config.env" ]]; then
  source "$SCRIPT_DIR/config.env"
fi
RESERVE_CEPH_STORAGE="${RESERVE_CEPH_STORAGE:-true}"
ROOT_LV_SIZE="${ROOT_LV_SIZE:-45G}"
if [[ "$RESERVE_CEPH_STORAGE" != "true" ]]; then
  ROOT_LV_SIZE="-1"
fi

UBUNTU_ISO="${UBUNTU_ISO:-}"
WORK_DIR="/tmp/iso-repack"
CIDATA_MOUNT="/mnt/cidata"

# --- Helpers ---

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

# SSH key for auto-join
NODE_KEY="$SCRIPT_DIR/keys/node-join"
validate_file "$NODE_KEY" "SSH key not found at $NODE_KEY — run: ssh-keygen -t ed25519 -f $NODE_KEY -N '' -C k8s-node-auto-join"

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

# Get master node info
MASTER_IP="${MASTER_IP:-}"
MASTER_USER="${MASTER_USER:-}"
if [[ -z "$MASTER_IP" ]]; then
  read -r -p "Master node IP: " MASTER_IP
fi
if [[ -z "$MASTER_USER" ]]; then
  read -r -p "Master node SSH user: " MASTER_USER
fi
validate_not_empty "Master IP" "$MASTER_IP"
validate_not_empty "Master SSH user" "$MASTER_USER"

# Get password hash
PASSWORD_HASH="${PASSWORD_HASH:-}"
if [[ -z "$PASSWORD_HASH" ]]; then
  read -r -p "User password (plaintext, will be hashed): " USER_PW
  [[ -n "$USER_PW" ]] || die "Password is required"
  command -v mkpasswd >/dev/null 2>&1 || die "mkpasswd is required: sudo apt install whois"
  PASSWORD_HASH=$(mkpasswd --method=SHA-512 "$USER_PW")
fi

echo "============================================"
echo "  Kubernetes Node USB Prep"
echo "============================================"
echo "  USB device : $USB_DEV"
echo "  USB size   : $(lsblk -dno SIZE "$USB_DEV" 2>/dev/null | xargs)"
echo "  USB model  : $(lsblk -dno MODEL "$USB_DEV" 2>/dev/null | xargs)"
echo "  Ubuntu ISO : $(basename "$UBUNTU_ISO")"
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
# Look for --interval line with appended_partition_2, extract start and end sectors
EFI_INTERVAL=$(echo "$ELTORITO" | grep -o 'appended_partition_2.*' | head -1 || true)
if [[ -n "$EFI_INTERVAL" ]]; then
  # Format is like: appended_partition_2_start_1660121s_size_10160d
  # or in the -append_partition line: 6640484d-6650643d
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
echo "=== [2/5] Injecting autoinstall config ==="

# Create NoCloud datasource directory inside the ISO
mkdir -p "$WORK_DIR/extract/nocloud"

# Build user-data with real credentials injected
KEY_CONTENT=$(sed 's/^/      /' "$NODE_KEY")
SAFE_HASH=$(escape_for_sed "$PASSWORD_HASH")
sed -e "s|      __NODE_JOIN_KEY_PLACEHOLDER__|${KEY_CONTENT//$'\n'/\\n}|" \
    -e "s|__WIFI_SSID__|${WIFI_SSID}|g" \
    -e "s|__WIFI_PASSWORD__|${WIFI_PASSWORD}|g" \
    -e "s|__PASSWORD_HASH__|${SAFE_HASH}|g" \
    -e "s|__MASTER_IP__|${MASTER_IP}|g" \
    -e "s|__MASTER_USER__|${MASTER_USER}|g" \
    -e "s|__ROOT_LV_SIZE__|${ROOT_LV_SIZE}|g" \
  "$SCRIPT_DIR/autoinstall/user-data" > "$WORK_DIR/extract/nocloud/user-data"
echo "  user-data (with key + WiFi injected)"
echo "  Root LV size: $ROOT_LV_SIZE (RESERVE_CEPH_STORAGE=$RESERVE_CEPH_STORAGE)"

cp "$SCRIPT_DIR/autoinstall/meta-data" "$WORK_DIR/extract/nocloud/meta-data"

# Copy crypto scan script into the ISO
cp "$SCRIPT_DIR/scan.sh" "$WORK_DIR/extract/nocloud/scan.sh"
chmod 755 "$WORK_DIR/extract/nocloud/scan.sh"

# Generate autoinstall.yaml (same as user-data but without the #cloud-config header comments)
sed '1,5d' "$WORK_DIR/extract/nocloud/user-data" > "$WORK_DIR/extract/nocloud/autoinstall.yaml"

# Rewrite GRUB menu: require explicit selection to wipe & install
GRUB_CFG="$WORK_DIR/extract/boot/grub/grub.cfg"
if [[ -f "$GRUB_CFG" ]]; then
  write_grub_cfg "$GRUB_CFG" "Install Kubernetes Node"
fi

# --- Step 3: Repack the ISO ---
echo ""
echo "=== [3/5] Repacking ISO with xorriso ==="
ISO_OUT="$WORK_DIR/ubuntu-autoinstall.iso"
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
echo "  USB drive is ready!"
echo "============================================"
echo ""
echo "  Boot any machine from this USB — Ubuntu will"
echo "  install, set up containerd + kubeadm, and auto-join"
echo "  the cluster. No interaction needed."
echo ""
echo "  Verify on the master:"
echo "    kubectl get nodes"
echo ""
echo "  Boot logs are auto-saved to the CIDATA partition"
echo "  if the USB is plugged in during boot."
echo ""
