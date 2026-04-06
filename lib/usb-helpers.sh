#!/usr/bin/env bash
# lib/usb-helpers.sh — Shared functions for prepare-usb.sh and prepare-head-usb.sh
# Source this file; do not execute directly.

die() { echo "Error: $1" >&2; exit 1; }

# validate_root — check running as root
validate_root() {
  [[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0 [/dev/sdX]"
}

# validate_command CMD INSTALL_HINT — check a command is available
validate_command() {
  local cmd="$1" hint="$2"
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required: $hint"
}

# validate_block_device DEV — check device exists and is a block device
validate_block_device() {
  local dev="$1"
  [[ -b "$dev" ]] || die "$dev is not a block device"
}

# validate_not_boot_disk DEV — refuse to target the boot disk
validate_not_boot_disk() {
  local dev="$1"
  local root_disk
  root_disk="$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null || true)"
  if [[ -n "$root_disk" && "$dev" == "/dev/$root_disk" ]]; then
    die "$dev appears to be your boot disk. Refusing to continue."
  fi
}

# find_ubuntu_iso SEARCH_DIR — find Ubuntu 24.04 ISO, sets UBUNTU_ISO
find_ubuntu_iso() {
  local search_dir="$1"
  if [[ -z "${UBUNTU_ISO:-}" ]]; then
    UBUNTU_ISO="$(find "$search_dir" -maxdepth 1 -name 'ubuntu-24.04*-live-server-amd64.iso' -print -quit 2>/dev/null || true)"
  fi
  [[ -n "$UBUNTU_ISO" && -f "$UBUNTU_ISO" ]] || die "Ubuntu Server ISO not found.
  Download it from https://ubuntu.com/download/server and place it in $search_dir
  or set UBUNTU_ISO=/path/to/file.iso"
}

# validate_file PATH MESSAGE — check a file exists
validate_file() {
  local path="$1" msg="$2"
  [[ -f "$path" ]] || die "$msg"
}

# validate_not_empty VAR_NAME VALUE — check a value is not empty
validate_not_empty() {
  local name="$1" value="$2"
  [[ -n "$value" ]] || die "$name is required"
}

# load_secrets FILE — source secrets.env if it exists
load_secrets() {
  local file="$1"
  if [[ -f "$file" ]]; then
    # shellcheck disable=SC1090
    source "$file"
  fi
}

# escape_for_sed VALUE — escape &, /, \, $ for use in sed replacement
escape_for_sed() {
  printf '%s' "$1" | sed 's/[&\/\$]/\\&/g'
}

# detect_usb_drives — auto-detect USB drives, prints device paths (one per line)
detect_usb_drives() {
  local root_disk
  root_disk="$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null || true)"
  lsblk -dno NAME,TRAN,RM,TYPE | awk '$2=="usb" && $3=="1" && $4=="disk" {print "/dev/"$1}' \
    | grep -v "/dev/${root_disk:-^$}" || true
}

# render_template TEMPLATE_FILE OUTPUT_FILE PLACEHOLDER=VALUE ...
# Replaces __PLACEHOLDER__ with VALUE in the template and writes to output.
# Usage: render_template in.yaml out.yaml "WIFI_SSID=MyNet" "WIFI_PASSWORD=secret"
render_template() {
  local template="$1" output="$2"
  shift 2

  local sed_args=()
  for pair in "$@"; do
    local key="${pair%%=*}"
    local value="${pair#*=}"
    local safe_value
    safe_value=$(escape_for_sed "$value")
    sed_args+=(-e "s|__${key}__|${safe_value}|g")
  done

  sed "${sed_args[@]}" "$template" > "$output"
}

# write_grub_cfg OUTPUT_FILE MENU_LABEL — write the standard GRUB config
write_grub_cfg() {
  local output="$1" label="$2"
  cat > "$output" <<GRUBEOF
set default=0
set timeout=30

loadfont unicode

set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

menuentry "Boot from disk (no changes)" {
        exit 0
}
menuentry "WIPE DISK & ${label}" {
        set gfxpayload=keep
        linux   /casper/vmlinuz  autoinstall ci.ds=nocloud ---
        initrd  /casper/initrd
}
menuentry "WIPE DISK & ${label} (HWE kernel)" {
        set gfxpayload=keep
        linux   /casper/hwe-vmlinuz  autoinstall ci.ds=nocloud ---
        initrd  /casper/hwe-initrd
}
grub_platform
if [ "\$grub_platform" = "efi" ]; then
menuentry 'UEFI Firmware Settings' {
        fwsetup
}
fi
GRUBEOF
}
