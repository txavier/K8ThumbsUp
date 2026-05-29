#!/usr/bin/env bash
#
# collect-debug.sh — gather post-install diagnostics onto the CIDATA USB.
#
# Designed to run on a freshly-installed K8ThumbsUp node that has no
# network (e.g. USB WiFi adapter not coming up, wrong netplan, DKMS
# build failed).  No internet, no apt, no extra packages required —
# only tools present in a stock Ubuntu Server install.
#
# Usage on the failed node:
#   1. Log in locally as `kube` (password set during install).
#   2. Plug the K8ThumbsUp install USB back in.
#   3. Mount it and run:
#        sudo bash /media/*/CIDATA/collect-debug.sh
#      ...or, if not auto-mounted:
#        sudo mount /dev/sdX4 /mnt && sudo bash /mnt/collect-debug.sh
#      (sdX4 is the CIDATA partition — `lsblk -f` to find LABEL=CIDATA)
#   4. Pull the USB, plug into your workstation, look under
#      `debug-logs/<hostname>/<timestamp>/` for the bundle.
#
# The script is read-only with respect to the installed system; it
# only WRITES to the USB.

set -u  # not -e: we want to keep collecting even when individual
        # commands fail (no kubectl, no wpa_supplicant, etc.)

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must run as root (sudo bash $0)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Locate the CIDATA partition.
#
# Prefer the partition this script was launched from (so if multiple USB
# sticks are plugged in, we write back to the right one).  Fall back to
# blkid LABEL lookup.
# ---------------------------------------------------------------------------
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
USB_MNT=""

# If the script lives on a mounted filesystem with label CIDATA, use that mount.
if findmnt -no SOURCE,TARGET,LABEL --target "$SCRIPT_DIR" 2>/dev/null \
     | awk '{print $3}' | grep -qx CIDATA; then
  USB_MNT="$(findmnt -no TARGET --target "$SCRIPT_DIR")"
fi

if [[ -z "$USB_MNT" ]]; then
  USB_PART="$(blkid -t LABEL=CIDATA -o device 2>/dev/null | head -1)"
  if [[ -z "$USB_PART" ]]; then
    echo "ERROR: no partition with LABEL=CIDATA found." >&2
    echo "       Plug the install USB in and re-run." >&2
    exit 1
  fi
  USB_MNT="/tmp/cidata-debug-$$"
  mkdir -p "$USB_MNT"
  if ! mount "$USB_PART" "$USB_MNT"; then
    echo "ERROR: failed to mount $USB_PART at $USB_MNT" >&2
    exit 1
  fi
  trap 'sync; umount "$USB_MNT" 2>/dev/null; rmdir "$USB_MNT" 2>/dev/null' EXIT
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
HOST="$(hostname)"
OUT="$USB_MNT/debug-logs/$HOST/$STAMP"
mkdir -p "$OUT"

echo "Collecting diagnostics into: $OUT"
echo "(this takes ~10s, no network required)"

# Tiny helper: run a command, write stdout+stderr to $OUT/<name>.log,
# never abort the script on failure.
_run() {
  local name="$1"; shift
  {
    echo "==== $* ===="
    "$@" 2>&1
    echo "==== exit=$? ===="
  } > "$OUT/$name.log" 2>&1 || true
}

# ---------------------------------------------------------------------------
# System overview
# ---------------------------------------------------------------------------
_run 00-uname              uname -a
_run 00-os-release         cat /etc/os-release
_run 00-uptime             uptime
_run 00-date               date -Iseconds
_run 00-hostname           hostnamectl

# ---------------------------------------------------------------------------
# Hardware / kernel-side network detection
# ---------------------------------------------------------------------------
_run 10-lspci              lspci -nnk
_run 10-lsusb              lsusb -v
_run 10-lsusb-tree         lsusb -t
_run 10-ip-link            ip -d link
_run 10-ip-addr            ip -d addr
_run 10-ip-route           ip route
_run 10-sys-class-net      ls -la /sys/class/net/
_run 10-rfkill             rfkill list all

# Loaded WiFi-related kernel modules (covers rtl/rtw/iwlwifi/brcm/8812/8821/8814)
{
  echo "==== lsmod | grep -iE 'rtl|rtw|8812|8821|8814|iwl|brcm|cfg80211|mac80211' ===="
  lsmod 2>&1 | grep -iE 'rtl|rtw|8812|8821|8814|iwl|brcm|cfg80211|mac80211' || echo "(no matches)"
} > "$OUT/10-lsmod-wifi.log" 2>&1

# ---------------------------------------------------------------------------
# DKMS — did the offline-installed WiFi driver actually build & install?
# ---------------------------------------------------------------------------
_run 20-dkms-status        dkms status
_run 20-dkms-tree          ls -la /var/lib/dkms/
_run 20-modinfo-8821au     modinfo 8821au
_run 20-modinfo-88xxau     modinfo 88XXau
_run 20-modinfo-8812au     modinfo 8812au

# DKMS build logs (one file each so we can read them individually)
if [[ -d /var/lib/dkms ]]; then
  find /var/lib/dkms -name 'make.log' -print0 2>/dev/null | \
    while IFS= read -r -d '' f; do
      safe="$(echo "$f" | tr '/' '_')"
      cp "$f" "$OUT/20-dkms-make${safe}.log" 2>/dev/null || true
    done
fi

# ---------------------------------------------------------------------------
# Netplan & networking services
# ---------------------------------------------------------------------------
_run 30-netplan-ls         ls -la /etc/netplan/
{
  echo "==== contents of /etc/netplan/*.yaml ===="
  for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do
    [[ -e "$f" ]] || continue
    echo
    echo "----- $f -----"
    # Mask the WiFi password before writing to the (shared) USB
    sed -E 's/(password:\s*).*/\1<REDACTED>/' "$f"
  done
} > "$OUT/30-netplan-contents.log" 2>&1

_run 30-netplan-get        netplan get
_run 30-netplan-generate   netplan generate
_run 30-networkctl         networkctl status --no-pager
_run 30-networkctl-list    networkctl list --no-pager
_run 30-systemd-networkd   systemctl status systemd-networkd --no-pager
_run 30-systemd-resolved   systemctl status systemd-resolved --no-pager
_run 30-resolvconf         cat /etc/resolv.conf
_run 30-resolvectl         resolvectl status

# wpa_supplicant
_run 31-wpa-status         systemctl status 'wpa_supplicant*' --no-pager
_run 31-wpa-conf-ls        ls -la /etc/wpa_supplicant/ /run/netplan/
{
  echo "==== /run/netplan/*.conf (netplan-generated wpa_supplicant config) ===="
  for f in /run/netplan/*.conf; do
    [[ -e "$f" ]] || continue
    echo
    echo "----- $f -----"
    sed -E 's/(psk=).*/\1<REDACTED>/' "$f"
  done
} > "$OUT/31-wpa-generated.log" 2>&1

# ---------------------------------------------------------------------------
# Kubernetes / auto-join state
# ---------------------------------------------------------------------------
_run 40-k8s-autojoin-status  systemctl status k8s-auto-join.service --no-pager
_run 40-k8s-autojoin-journal journalctl -u k8s-auto-join.service --no-pager -b
_run 40-k8s-autojoin-log     cat /var/log/k8s-auto-join.log
_run 40-kubelet-status       systemctl status kubelet --no-pager
_run 40-kubelet-journal      journalctl -u kubelet --no-pager -b
_run 40-containerd-status    systemctl status containerd --no-pager
_run 40-which-kubeadm        bash -c 'which kubeadm; kubeadm version 2>&1'
_run 40-ssh-key-perms        ls -la /etc/kubernetes/

# ---------------------------------------------------------------------------
# Boot logs
# ---------------------------------------------------------------------------
_run 50-dmesg                dmesg
{
  echo "==== dmesg | grep wifi/wlan/usb/firmware/cfg80211 ===="
  dmesg 2>&1 | grep -iE 'wlan|wifi|usb|firmware|cfg80211|mac80211|rtl|rtw|8812|8821|8814|iwl|brcm' || echo "(no matches)"
} > "$OUT/50-dmesg-wifi.log" 2>&1

_run 50-journalctl-boot      journalctl -b --no-pager
_run 50-failed-services      systemctl --failed --no-pager
_run 50-systemd-analyze      systemd-analyze blame
_run 50-cloud-init-status    cat /etc/cloud/cloud-init.disabled
{
  echo "==== /var/log/installer/*.log ===="
  ls -la /var/log/installer/ 2>&1
} > "$OUT/50-installer-logdir.log" 2>&1
# Copy installer logs verbatim — these were written during autoinstall
# (curtin-install.log etc.) and contain the failure root cause if any.
if [[ -d /var/log/installer ]]; then
  mkdir -p "$OUT/installer-logs"
  cp -a /var/log/installer/. "$OUT/installer-logs/" 2>/dev/null || true
fi

# The K8ThumbsUp offline-package install log (written by late-commands)
if [[ -f /var/log/k8thumbsup-offline-install.log ]]; then
  cp /var/log/k8thumbsup-offline-install.log "$OUT/50-k8thumbsup-offline-install.log"
fi

# ---------------------------------------------------------------------------
# Manifest of what we collected, plus quick triage summary at the top.
# ---------------------------------------------------------------------------
{
  echo "K8ThumbsUp post-install debug bundle"
  echo "host:      $HOST"
  echo "stamp:     $STAMP"
  echo "kernel:    $(uname -r)"
  echo
  echo "---- quick triage ----"
  echo "interfaces:           $(ls /sys/class/net/ | tr '\n' ' ')"
  echo "wl* interfaces:       $(ls /sys/class/net/ | grep -E '^wl' | tr '\n' ' ')"
  echo "en* interfaces:       $(ls /sys/class/net/ | grep -E '^en' | tr '\n' ' ')"
  echo "default route:        $(ip route show default 2>/dev/null | head -1)"
  echo "dkms status:          $(dkms status 2>/dev/null | tr '\n' '|')"
  echo "k8s-auto-join state:  $(systemctl is-active k8s-auto-join.service 2>/dev/null)"
  echo "kubelet state:        $(systemctl is-active kubelet 2>/dev/null)"
  echo "containerd state:     $(systemctl is-active containerd 2>/dev/null)"
  echo "kubeadm installed:    $(command -v kubeadm >/dev/null && echo yes || echo no)"
  echo
  echo "---- files ----"
  (cd "$OUT" && find . -type f | sort)
} > "$OUT/00-SUMMARY.txt"

sync
echo
echo "Done.  Bundle written to:"
echo "  $OUT"
echo
echo "Eject the USB and inspect 00-SUMMARY.txt first."
