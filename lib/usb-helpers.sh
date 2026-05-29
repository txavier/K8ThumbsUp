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

# download_offline_packages DEST_DIR [PKG...] — download .deb packages plus the
# *full transitive dependency closure* into DEST_DIR and generate a Packages
# index so the directory can be used as a local apt file:// source during
# autoinstall on a target with NO network access.
#
# CRITICAL: this resolves deps via `apt-cache depends --recurse` and fetches
# every .deb via `apt-get download` (which always fetches regardless of whether
# the build host has the package installed).  The naive `apt-get install
# --download-only` approach only fetches what is MISSING on the build host,
# which leaves the offline bundle incomplete — apt on the target machine then
# fails with "unmet dependencies" / exit 100 the moment it sees a dep like
# gcc/make/libc6-dev that DKMS packages require but our bundle didn't ship.
#
# Requires running as root and internet access on the build machine.  DEST_DIR
# is always created; an empty Packages file is written when no packages are
# requested so the apt source never errors on apt-get update.
#
# Caching: downloaded .debs are kept in a persistent per-codename cache
# (default ~/.cache/k8thumbsup/offline-packages/<codename>/, override with
# OFFLINE_PKG_CACHE_DIR) so subsequent runs only re-download packages whose
# candidate version has changed.  Set OFFLINE_PKG_CACHE_DIR=/dev/null-style
# empty string to disable caching.  Pass OFFLINE_PKG_REFRESH=1 to force
# `apt-get update` before resolving the closure.
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

  # Cache dir, keyed by Ubuntu codename so different releases don't collide.
  # Under sudo, prefer the invoking user's home over /root so cached debs
  # persist across the user's normal workflow.
  local codename cache_home
  codename="$(lsb_release -cs 2>/dev/null || echo unknown)"
  if [[ -n "${SUDO_USER:-}" ]] && cache_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)" && [[ -n "$cache_home" ]]; then
    :
  else
    cache_home="$HOME"
  fi
  local cache_dir="${OFFLINE_PKG_CACHE_DIR-$cache_home/.cache/k8thumbsup/offline-packages/$codename}"
  if [[ -n "$cache_dir" ]]; then
    mkdir -p "$cache_dir"
    # apt-get download drops to the _apt user; ensure it can traverse + write.
    chmod a+rx "$cache_dir" 2>/dev/null || true
    # Walk up so _apt can reach the leaf.
    local _p="$cache_dir"
    while [[ "$_p" != "/" && "$_p" != "$cache_home" ]]; do
      chmod a+rx "$_p" 2>/dev/null || true
      _p="$(dirname "$_p")"
    done
    echo "  Cache dir: $cache_dir"
  fi

  if [[ "${OFFLINE_PKG_REFRESH:-0}" == "1" ]]; then
    echo "  OFFLINE_PKG_REFRESH=1 — running apt-get update first"
    apt-get update -qq >/dev/null 2>&1 || true
  fi

  # 1. Resolve full transitive dependency closure (real packages only —
  #    apt-cache show filters virtuals/alternatives that can't be downloaded).
  echo "  Resolving dependency closure for ${#pkgs[@]} requested package(s)..."
  local closure_raw closure
  closure_raw=$(apt-cache depends --recurse \
                  --no-recommends --no-suggests --no-conflicts \
                  --no-breaks --no-replaces --no-enhances \
                  "${pkgs[@]}" 2>/dev/null \
                | awk '/^[a-zA-Z0-9]/ {print $1}' | sort -u)
  # Keep only names that resolve to a real installable package.
  closure=$(echo "$closure_raw" \
            | xargs -r apt-cache show 2>/dev/null \
            | awk '/^Package:/ {print $2}' | sort -u)
  local closure_count
  closure_count=$(echo "$closure" | grep -c . || true)
  echo "  Closure: $closure_count real package(s) to fetch"

  # 2. Ask apt for the authoritative candidate URIs (which include the
  #    exact .deb basenames).  This is the only reliable way to know which
  #    file `apt-get download` will produce — `apt-cache show` lists ALL
  #    versions and the first Filename: isn't always the candidate.
  echo "  Querying candidate URIs..."
  local uri_output
  uri_output=$( (cd /tmp && printf '%s\n' $closure | xargs -r apt-get download --print-uris -y 2>/dev/null) )
  # Format: 'http://.../foo_1.2_amd64.deb' foo_1.2_amd64.deb 1234 SHA256:...
  local expected_basenames=()
  local to_download=()
  local resolved_pkgs=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local basename_deb pkg_name
    basename_deb=$(echo "$line" | awk '{print $2}')
    [[ -z "$basename_deb" ]] && continue
    pkg_name="${basename_deb%%_*}"
    expected_basenames+=("$basename_deb")
    resolved_pkgs+=("$pkg_name")
    if [[ -n "$cache_dir" && -f "$cache_dir/$basename_deb" ]]; then
      continue
    fi
    to_download+=("$pkg_name")
  done <<< "$uri_output"

  local cache_hits=$(( ${#expected_basenames[@]} - ${#to_download[@]} ))
  echo "  Cache: $cache_hits hit / ${#to_download[@]} miss"

  # 3. Download only the cache-miss packages into the cache (or a scratch
  #    dir if caching is disabled).  apt-get download writes to CWD.
  local download_dir="$cache_dir"
  local scratch_dir=""
  if [[ -z "$cache_dir" ]]; then
    scratch_dir="$(mktemp -d /tmp/apt-offline-XXXX)"
    download_dir="$scratch_dir"
  fi

  if [[ ${#to_download[@]} -gt 0 ]]; then
    (
      cd "$download_dir"
      printf '%s\n' "${to_download[@]}" | xargs -r apt-get download -y 2>&1 \
        | grep -E '^(Get:|Err:|E:|W: )' | grep -v 'unsandboxed' | tail -20 || true
    )
    # Ensure newly-downloaded files are world-readable so _apt can sandbox
    # downloads in this dir on the next run.
    chmod a+r "$download_dir"/*.deb 2>/dev/null || true
  fi

  # 4. Copy every closure .deb from the download dir into dest_dir using
  #    the exact candidate basenames.
  local copied=0
  for basename_deb in "${expected_basenames[@]}"; do
    if [[ -f "$download_dir/$basename_deb" ]]; then
      cp -- "$download_dir/$basename_deb" "$dest_dir/"
      copied=$((copied + 1))
    fi
  done

  # 5. Verify every originally-requested package is present in dest_dir.
  local failed_pkgs=()
  for pkg in "${pkgs[@]}"; do
    if ! find "$dest_dir" -maxdepth 1 -name "${pkg}_*.deb" -print -quit | grep -q .; then
      failed_pkgs+=("$pkg")
      echo "  ERROR: failed to obtain $pkg" >&2
    fi
  done

  if [[ ${#failed_pkgs[@]} -gt 0 ]]; then
    echo "" >&2
    echo "ERROR: could not download these OFFLINE_PACKAGES: ${failed_pkgs[*]}" >&2
    echo "  - If a package is in multiverse, enable it on the build host:" >&2
    echo "      sudo add-apt-repository multiverse && sudo apt-get update" >&2
    echo "  - Check the package name is correct for Ubuntu $(lsb_release -rs 2>/dev/null || echo '?')" >&2
    echo "  - Try OFFLINE_PKG_REFRESH=1 to refresh apt indexes before retrying." >&2
    [[ -n "$scratch_dir" ]] && rm -rf "$scratch_dir"
    return 1
  fi

  [[ -n "$scratch_dir" ]] && rm -rf "$scratch_dir"

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

  # Sanity check: verify the local repo can satisfy an install of every
  # requested package WITHOUT touching the internet.  This catches the
  # exact failure mode that crashed the real install (broadcom-sta-dkms
  # → unmet dep gcc/make/libc6-dev) before we ever flash a USB.
  if command -v apt-get >/dev/null 2>&1; then
    local rootdir; rootdir="$(mktemp -d /tmp/apt-verify-XXXX)"
    mkdir -p "$rootdir"/{etc/apt/sources.list.d,var/lib/apt/lists/partial,var/cache/apt/archives/partial,var/lib/dpkg}
    : > "$rootdir/var/lib/dpkg/status"
    echo "deb [trusted=yes] file://$dest_dir/ ./" \
      > "$rootdir/etc/apt/sources.list.d/offline.list"
    : > "$rootdir/etc/apt/sources.list"
    if apt-get -o Dir="$rootdir" \
                -o Dir::State="$rootdir/var/lib/apt" \
                -o Dir::State::status="$rootdir/var/lib/dpkg/status" \
                -o Dir::Cache="$rootdir/var/cache/apt" \
                -o Dir::Etc::sourcelist="$rootdir/etc/apt/sources.list" \
                -o Dir::Etc::sourceparts="$rootdir/etc/apt/sources.list.d" \
                -o Acquire::AllowInsecureRepositories=true \
                update >/dev/null 2>&1 \
       && apt-get -o Dir="$rootdir" \
                  -o Dir::State="$rootdir/var/lib/apt" \
                  -o Dir::State::status="$rootdir/var/lib/dpkg/status" \
                  -o Dir::Cache="$rootdir/var/cache/apt" \
                  -o Dir::Etc::sourcelist="$rootdir/etc/apt/sources.list" \
                  -o Dir::Etc::sourceparts="$rootdir/etc/apt/sources.list.d" \
                  -o Acquire::AllowInsecureRepositories=true \
                  install -s -y --no-install-recommends --allow-unauthenticated \
                  "${pkgs[@]}" >/tmp/apt-offline-verify.log 2>&1; then
      echo "  Offline-install simulation: OK ($(grep -c '^Inst ' /tmp/apt-offline-verify.log) packages would install)"
      rm -rf "$rootdir"
    else
      echo "" >&2
      echo "ERROR: offline-install simulation FAILED — drivers/ does not satisfy all deps" >&2
      echo "  The target machine would also fail with apt exit 100." >&2
      echo "  Last 20 lines of simulation output:" >&2
      tail -20 /tmp/apt-offline-verify.log | sed 's/^/    /' >&2
      rm -rf "$rootdir"
      return 1
    fi
  fi
}

# build_rtl8852cu_deb DEST_DIR — clone the morrownr/rtl8852cu-20251113 DKMS source
# tree and produce a `rtl8852cu-dkms_<ver>_all.deb` in DEST_DIR.
#
# Why this exists: the USB WiFi 6 (802.11ax) adapters with Realtek RTL8852CU
# chips (idVendor 0db0 idProduct 991d is one such device) are NOT supported
# by `rtl8812au-dkms` (which covers only the older 88xxAU / 802.11ac chips)
# and the in-kernel `rtw89` driver in 6.8 only handles the PCIe variants of
# the 8852 family.  No Ubuntu apt package exists for the USB variant, so we
# vendor the morrownr/rtl8852cu-20251113 out-of-tree DKMS source and build a .deb
# from it on the build host.  The resulting binary .deb is kernel-agnostic:
# it installs the source under /usr/src/ and DKMS rebuilds the module
# against the target's running kernel on first apt-get install.
#
# Best-effort: if git/dkms/build tools are missing, prints a warning and
# returns 0.  The install will still succeed; the 8852cu adapter just
# won't have a driver.  Set BUILD_RTL8852CU=0 to skip this step entirely.
#
# Cache directory: ${OFFLINE_PKG_CACHE_DIR-$HOME/.cache/k8thumbsup}/rtl8852cu-src
# Repo:  https://github.com/morrownr/rtl8852cu-20251113
build_rtl8852cu_deb() {
  local dest_dir="$1"
  local repo_url="${RTL8852CU_REPO_URL:-https://github.com/morrownr/rtl8852cu-20251113.git}"

  if [[ "${BUILD_RTL8852CU:-1}" != "1" ]]; then
    echo "  BUILD_RTL8852CU=0 — skipping rtl8852cu DKMS build"
    return 0
  fi

  local missing=()
  for cmd in git dpkg-deb; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "  WARN: rtl8852cu DKMS build skipped — missing on build host: ${missing[*]}"
    echo "        Install with: sudo apt install git dpkg-dev"
    return 0
  fi

  # Cache the source tree per invoking user so re-runs are fast.
  local cache_home
  if [[ -n "${SUDO_USER:-}" ]] && cache_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)" && [[ -n "$cache_home" ]]; then
    :
  else
    cache_home="$HOME"
  fi
  local cache_root="${OFFLINE_PKG_CACHE_DIR:-}"
  cache_root="${cache_root%/*}"
  [[ -z "$cache_root" || "$cache_root" == "/dev" ]] && cache_root="$cache_home/.cache/k8thumbsup"
  local src_cache="$cache_root/rtl8852cu-src"
  mkdir -p "$cache_root"

  echo "  Fetching rtl8852cu source ($repo_url)..."
  if [[ -d "$src_cache/.git" ]]; then
    if ! ( cd "$src_cache" && git fetch --depth=1 origin HEAD >/dev/null 2>&1 \
                          && git reset --hard FETCH_HEAD >/dev/null 2>&1 ); then
      echo "  WARN: git fetch failed; using existing cached tree"
    fi
  else
    if ! git clone --depth=1 "$repo_url" "$src_cache" >/dev/null 2>&1; then
      echo "  WARN: git clone failed — rtl8852cu DKMS build skipped"
      echo "        (no internet, or repo unreachable: $repo_url)"
      return 0
    fi
  fi

  if [[ ! -f "$src_cache/dkms.conf" ]]; then
    echo "  WARN: dkms.conf not found in $src_cache — rtl8852cu build skipped"
    return 0
  fi

  local pkgname pkgver debver
  pkgname="$(awk -F'"' '/^PACKAGE_NAME=/{print $2}' "$src_cache/dkms.conf")"
  pkgver="$(awk  -F'"' '/^PACKAGE_VERSION=/{print $2}' "$src_cache/dkms.conf")"
  [[ -z "$pkgname" ]] && pkgname="rtl8852cu"
  [[ -z "$pkgver"  ]] && pkgver="$(date +%Y%m%d)"
  # Strip leading 'v' from PACKAGE_VERSION ("v1.19.22-103" → "1.19.22-103")
  # so the Debian version field follows policy.  Replace '-' so it doesn't
  # confuse dpkg's debian-revision split.
  debver="${pkgver#v}"
  debver="${debver//-/.}"
  echo "  Building DKMS package: ${pkgname}-dkms ${debver} (upstream ${pkgver})"

  # DKMS 3.x removed `dkms mkdeb`, so we build the .deb ourselves with
  # dpkg-deb.  The layout we produce is the classic "DKMS source-only"
  # package: drop the source tree under /usr/src/<name>-<ver>/ and let
  # postinst run `dkms add` + `dkms install` against the target's kernel.
  local stage; stage="$(mktemp -d /tmp/rtl8852cu-deb-XXXX)"
  local debpkg="${pkgname}-dkms"
  local srcdir="$stage/usr/src/${pkgname}-${pkgver}"
  mkdir -p "$srcdir" "$stage/DEBIAN"
  cp -a "$src_cache/." "$srcdir/"
  # Strip VCS metadata so the .deb stays small and reproducible.
  rm -rf "$srcdir/.git" "$srcdir/.github"

  cat > "$stage/DEBIAN/control" <<EOF
Package: ${debpkg}
Version: ${debver}
Section: kernel
Priority: optional
Architecture: all
Depends: dkms (>= 2.1.0.0), make, gcc, libc6-dev
Recommends: linux-headers-generic | linux-headers
Maintainer: K8ThumbsUp build <root@localhost>
Description: Realtek RTL8852CU USB WiFi 6E driver (DKMS)
 Out-of-tree DKMS source for the Realtek RTL8852CU / RTL8832CU USB
 802.11ax/be WiFi adapters (e.g. MSI AXE5400, USB ID 0db0:991d).
 The kernel module is built on the target via DKMS against the
 running kernel's headers.
 .
 Source: ${repo_url}
EOF

  cat > "$stage/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
NAME=${pkgname}
VER=${pkgver}
if [ "\$1" = configure ]; then
  # Register the source tree with DKMS (idempotent).
  dkms add -m "\$NAME" -v "\$VER" 2>/dev/null || true
  # Build + install for EVERY installed kernel that has matching headers.
  # We must not restrict to \$(uname -r) here: in the subiquity install
  # path this postinst runs against the live-installer kernel ABI, but
  # the installed system frequently boots a newer kernel ABI (e.g. when
  # linux-generic metapackage pulls a point release).  Without
  # autoinstall, the module exists only for the live ABI and the USB
  # WiFi adapter has no driver after first boot.  autoinstall also wires
  # us into /etc/kernel/postinst.d/dkms so future kernel upgrades
  # rebuild automatically.
  dkms autoinstall -m "\$NAME/\$VER" || true
fi
exit 0
EOF
  chmod 0755 "$stage/DEBIAN/postinst"

  cat > "$stage/DEBIAN/prerm" <<EOF
#!/bin/sh
set -e
NAME=${pkgname}
VER=${pkgver}
if [ "\$1" = remove ] || [ "\$1" = upgrade ] || [ "\$1" = deconfigure ]; then
  dkms remove -m "\$NAME" -v "\$VER" --all 2>/dev/null || true
fi
exit 0
EOF
  chmod 0755 "$stage/DEBIAN/prerm"

  local out_deb="$dest_dir/${debpkg}_${debver}_all.deb"
  if ! dpkg-deb --root-owner-group --build "$stage" "$out_deb" >/dev/null; then
    echo "  ERROR: dpkg-deb --build failed for ${out_deb}" >&2
    rm -rf "$stage"
    return 1
  fi
  rm -rf "$stage"
  echo "  Built $(basename "$out_deb")"
}

# regenerate_offline_apt_index DEST_DIR — re-run dpkg-scanpackages so an
# apt source pointed at DEST_DIR sees any .debs added AFTER
# download_offline_packages returned (e.g. our locally-built
# rtl8852cu-dkms).  Safe to call repeatedly.
regenerate_offline_apt_index() {
  local dest_dir="$1"
  [[ -d "$dest_dir" ]] || return 0
  if command -v dpkg-scanpackages >/dev/null 2>&1; then
    (cd "$dest_dir" && dpkg-scanpackages --multiversion . 2>/dev/null > Packages)
  elif command -v apt-ftparchive >/dev/null 2>&1; then
    (cd "$dest_dir" && apt-ftparchive packages . 2>/dev/null > Packages)
  fi
  if command -v apt-ftparchive >/dev/null 2>&1; then
    (cd "$dest_dir" && apt-ftparchive release . 2>/dev/null > Release) || true
  fi
  local count; count=$(find "$dest_dir" -maxdepth 1 -name '*.deb' | wc -l)
  echo "  drivers/ now contains $count .deb file(s)"
}
