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

# write_grub_cfg OUTPUT_FILE MENU_LABEL — write the standard GRUB config.
# When TEST_MODE=1 is set in the environment, the GRUB menu auto-selects
# "WIPE DISK & <label>" with a 5s timeout so VM-based smoke tests can run
# unattended.  Production builds (TEST_MODE unset) default to "Boot from
# disk" with a 30s timeout so a USB left plugged in never wipes anything.
write_grub_cfg() {
  local output="$1" label="$2"
  local default_entry=0 timeout=30
  if [[ "${TEST_MODE:-0}" == "1" ]]; then
    default_entry=1
    timeout=5
  fi
  cat > "$output" <<GRUBEOF
set default=${default_entry}
set timeout=${timeout}

# Serial console (ttyS0 @ 115200) so headless QEMU VMs can log boot output
# via -serial file:... .  Harmless on real hardware: GRUB also keeps the
# graphical console active because we list "console" in terminal_*.
serial --unit=0 --speed=115200
terminal_input  serial console
terminal_output serial console

loadfont unicode

set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

menuentry "Boot from disk (no changes)" {
        exit 0
}
menuentry "WIPE DISK & ${label}" {
        set gfxpayload=keep
        linux   /casper/vmlinuz  autoinstall ci.ds=nocloud console=ttyS0,115200 ---
        initrd  /casper/initrd
}
menuentry "SCAN FOR CRYPTO then WIPE & ${label}" {
        set gfxpayload=keep
        linux   /casper/vmlinuz  autoinstall ci.ds=nocloud k8s.crypto-scan=1 console=ttyS0,115200 ---
        initrd  /casper/initrd
}
menuentry "WIPE DISK & ${label} (HWE kernel)" {
        set gfxpayload=keep
        linux   /casper/hwe-vmlinuz  autoinstall ci.ds=nocloud console=ttyS0,115200 ---
        initrd  /casper/hwe-initrd
}
menuentry "SCAN FOR CRYPTO then WIPE & ${label} (HWE)" {
        set gfxpayload=keep
        linux   /casper/hwe-vmlinuz  autoinstall ci.ds=nocloud k8s.crypto-scan=1 console=ttyS0,115200 ---
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

# download_offline_packages DEST_DIR [PKG...] — download .deb packages with
# their dependencies into DEST_DIR and generate a Packages index so the directory
# can be used as a local apt file:// source during autoinstall.
# Requires running as root (apt-get --download-only) and internet access on the
# build machine.  DEST_DIR is always created; an empty Packages file is written
# when no packages are requested so the apt source never errors on apt-get update.
download_offline_packages() {
  local dest_dir="$1"
  shift
  local pkgs=("$@")

  mkdir -p "$dest_dir"

  if [[ ${#pkgs[@]} -eq 0 || -z "${pkgs[0]:-}" ]]; then
    : > "$dest_dir/Packages"
    echo "  (OFFLINE_PACKAGES not set — empty drivers/ directory created)"
    return 0
  fi

  local apt_cache
  apt_cache="$(mktemp -d /tmp/apt-offline-XXXX)"
  mkdir -p "$apt_cache/partial"

  local failed_pkgs=()
  for pkg in "${pkgs[@]}"; do
    echo "  Fetching: $pkg"
    if ! apt-get install \
        -o Dir::Cache::Archives="$apt_cache" \
        -o Dir::Cache::Archives::partial="$apt_cache/partial" \
        --download-only --no-install-recommends --reinstall -y \
        "$pkg" 2>&1 | tee /tmp/apt-offline-last.log | grep -E '(^Get:|^Err:|WARNING|E:)'; then
      :
    fi
    # Verify the package itself was downloaded (deps may be optional, but the
    # named package must be present).  apt prefixes filenames with the package
    # name followed by an underscore.
    if ! find "$apt_cache" -maxdepth 1 -name "${pkg}_*.deb" -print -quit | grep -q .; then
      failed_pkgs+=("$pkg")
      echo "  ERROR: failed to download $pkg" >&2
      tail -20 /tmp/apt-offline-last.log >&2 || true
    fi
  done

  if [[ ${#failed_pkgs[@]} -gt 0 ]]; then
    echo "" >&2
    echo "ERROR: could not download these OFFLINE_PACKAGES: ${failed_pkgs[*]}" >&2
    echo "  - If a package is in multiverse, enable it on the build host:" >&2
    echo "      sudo add-apt-repository multiverse && sudo apt-get update" >&2
    echo "  - Check the package name is correct for Ubuntu $(lsb_release -rs 2>/dev/null || echo '?')" >&2
    return 1
  fi

  find "$apt_cache" -maxdepth 1 -name '*.deb' -exec cp -t "$dest_dir" {} +
  rm -rf "$apt_cache"

  local count
  count=$(find "$dest_dir" -name '*.deb' | wc -l)
  echo "  $count .deb package(s) ready in drivers/"

  # Generate apt Packages + Release index for use as a file:// repo
  if command -v dpkg-scanpackages >/dev/null 2>&1; then
    (cd "$dest_dir" && dpkg-scanpackages --multiversion . 2>/dev/null > Packages)
  elif command -v apt-ftparchive >/dev/null 2>&1; then
    (cd "$dest_dir" && apt-ftparchive packages . 2>/dev/null > Packages)
  else
    : > "$dest_dir/Packages"
    echo "  NOTE: dpkg-dev not found — Packages index skipped (apt source won't work)"
    echo "        Install it with: sudo apt install dpkg-dev"
    echo "        early-commands dpkg install will still work for binary packages."
    return 0
  fi

  # Release file suppresses apt warnings about missing metadata
  if command -v apt-ftparchive >/dev/null 2>&1; then
    (cd "$dest_dir" && apt-ftparchive release . 2>/dev/null > Release) || true
  fi

  echo "  Packages index generated"
}
