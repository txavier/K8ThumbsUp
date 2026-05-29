#!/usr/bin/env bash
# Local QEMU/KVM smoke test of the autoinstall ISO.
#
# Spins up a VM that boots /tmp/iso-repack/ubuntu-autoinstall.iso (built by
# prepare-usb.sh with TEST_MODE=1 so GRUB auto-selects the install entry) and
# installs Ubuntu onto a blank 60 GiB qcow2.  Uses QEMU user-mode (NAT)
# networking, so the VM can reach the master on the LAN and the auto-join
# script will register a real node in the cluster.
#
# What this exercises:
#   - subiquity autoinstall against our user-data (full late-commands path)
#   - first-boot k8s-auto-join.service, including the new kubeadm self-heal
#   - SSH to the master and kubeadm join
#
# What this does NOT exercise (vs real hardware):
#   - WiFi netplan / RTL8812AU DKMS (VM uses virtio + NAT)
#   - Rook/Ceph OSD partitioning on >100G disks
#
# Cleanup after a successful join:
#   kubectl delete node <vm-hostname>
#   rm /tmp/k8thumbsup-vm-{disk.qcow2,OVMF_VARS.fd}
#
# Usage:
#   bash k8s/test-vm-qemu.sh                              # build ISO if missing + run
#   SKIP_BUILD=1 bash k8s/test-vm-qemu.sh                 # reuse existing ISO
#   KEEP_DISK=1 bash k8s/test-vm-qemu.sh                  # don't recreate qcow2
#   SERIAL_LOG=/tmp/qemu.log bash k8s/test-vm-qemu.sh &   # headless, log serial to file
#   NO_NETWORK=1 bash k8s/test-vm-qemu.sh                 # boot with NO NIC at
#                                                          all — simulates a real
#                                                          install on a machine
#                                                          with no working
#                                                          driver.  Use this to
#                                                          prove the bundled
#                                                          offline /drivers/
#                                                          repo is self-
#                                                          sufficient (catches
#                                                          missing transitive
#                                                          apt deps that NAT
#                                                          would otherwise mask).#   USB_PASSTHROUGH=0db0:991d bash k8s/test-vm-qemu.sh    # pass a host USB
#                                                          device into the guest
#                                                          (vendor:product, hex
#                                                          IDs as shown by
#                                                          lsusb).  Comma-
#                                                          separated for multi-
#                                                          ple, or "auto" to
#                                                          pass every USB WiFi
#                                                          adapter detected on
#                                                          the host.  Combine
#                                                          with NO_NETWORK=1 to
#                                                          prove the install +
#                                                          first-boot auto-join
#                                                          can come up using
#                                                          ONLY the USB WiFi
#                                                          (no virtio NAT
#                                                          escape hatch).
#                                                          Requires root or
#                                                          group `kvm` write
#                                                          access on
#                                                          /dev/bus/usb/* — the
#                                                          script will sudo-
#                                                          chmod the matching
#                                                          USB device node so
#                                                          QEMU (running as
#                                                          $USER) can claim it.set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ISO="${ISO:-/tmp/iso-repack/ubuntu-autoinstall.iso}"
NOCLOUD_DIR="${NOCLOUD_DIR:-/tmp/iso-repack/extract/nocloud}"
CIDATA_ISO="${CIDATA_ISO:-/tmp/k8thumbsup-cidata.iso}"
DISK="${DISK:-/tmp/k8thumbsup-vm-disk.qcow2}"
OVMF_VARS="${OVMF_VARS:-/tmp/k8thumbsup-vm-OVMF_VARS.fd}"
OVMF_CODE="/usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS_TEMPLATE="/usr/share/OVMF/OVMF_VARS_4M.fd"
DISK_SIZE="${DISK_SIZE:-60G}"
MEM="${MEM:-4096}"
CPUS="${CPUS:-4}"
SSH_PORT="${SSH_PORT:-2222}"
SKIP_BUILD="${SKIP_BUILD:-0}"
KEEP_DISK="${KEEP_DISK:-0}"
NO_NETWORK="${NO_NETWORK:-0}"
USB_PASSTHROUGH="${USB_PASSTHROUGH:-}"   # e.g. "0db0:991d" or "auto" or "0db0:991d,148f:5370"
SERIAL_LOG="${SERIAL_LOG:-}"   # set to a path to log serial to file instead of stdio

command -v qemu-system-x86_64 >/dev/null || { echo "qemu-system-x86_64 not found (apt install qemu-system-x86)" >&2; exit 1; }
command -v qemu-img         >/dev/null || { echo "qemu-img not found (apt install qemu-utils)" >&2; exit 1; }
command -v xorriso          >/dev/null || { echo "xorriso not found (apt install xorriso)" >&2; exit 1; }
[[ -r "$OVMF_CODE"          ]] || { echo "$OVMF_CODE missing (apt install ovmf)" >&2; exit 1; }
[[ -r "$OVMF_VARS_TEMPLATE" ]] || { echo "$OVMF_VARS_TEMPLATE missing (apt install ovmf)" >&2; exit 1; }

# Build ISO (TEST_MODE=1 → GRUB auto-selects "WIPE & install")
if [[ "$SKIP_BUILD" == "1" ]]; then
  [[ -f "$ISO" ]] || { echo "SKIP_BUILD=1 but $ISO is missing" >&2; exit 1; }
  echo "=== Reusing $ISO ==="
else
  echo "=== Building TEST_MODE ISO ==="
  ( cd "$REPO_ROOT" && sudo env TEST_MODE=1 BUILD_ISO_ONLY=1 bash prepare-usb.sh )
  [[ -f "$ISO" ]] || { echo "ISO build failed" >&2; exit 1; }
  sudo chmod a+r "$ISO"
fi

# Build a CIDATA-labelled ISO with the cloud-init user-data + meta-data.
# On a real USB, prepare-usb.sh creates a CIDATA partition (step 6).  In
# BUILD_ISO_ONLY mode that step is skipped, so the VM has no NoCloud
# datasource unless we attach one here as a second cdrom.  Without this,
# `ci.ds=nocloud` on the kernel cmdline finds nothing and subiquity hangs
# waiting for cloud-init.
echo "=== Building CIDATA ISO (cloud-init NoCloud datasource) ==="
[[ -d "$NOCLOUD_DIR" ]] || { echo "$NOCLOUD_DIR missing — run without SKIP_BUILD=1 or point NOCLOUD_DIR at extracted nocloud/" >&2; exit 1; }
CIDATA_STAGE="$(mktemp -d)"
trap 'rm -rf "$CIDATA_STAGE"' EXIT
sudo cp "$NOCLOUD_DIR/user-data" "$CIDATA_STAGE/user-data"
sudo cp "$NOCLOUD_DIR/meta-data" "$CIDATA_STAGE/meta-data"
sudo chmod a+r "$CIDATA_STAGE"/*
rm -f "$CIDATA_ISO"
xorriso -as mkisofs -V CIDATA -o "$CIDATA_ISO" -r -J "$CIDATA_STAGE" 2>/dev/null
[[ -f "$CIDATA_ISO" ]] || { echo "CIDATA ISO build failed" >&2; exit 1; }

# Fresh OVMF vars copy (so each run starts from a clean NVRAM state)
cp "$OVMF_VARS_TEMPLATE" "$OVMF_VARS"

# Disk
if [[ "$KEEP_DISK" != "1" || ! -f "$DISK" ]]; then
  echo "=== Creating fresh $DISK_SIZE qcow2 at $DISK ==="
  rm -f "$DISK"
  qemu-img create -f qcow2 "$DISK" "$DISK_SIZE" >/dev/null
fi

# KVM acceleration if available + permitted
ACCEL="-machine type=q35,accel=tcg"
if [[ -w /dev/kvm ]]; then
  ACCEL="-machine type=q35,accel=kvm -cpu host"
elif [[ -r /dev/kvm ]] && groups | tr ' ' '\n' | grep -qx kvm; then
  ACCEL="-machine type=q35,accel=kvm -cpu host"
else
  echo "NOTE: /dev/kvm not writable for $USER — falling back to TCG (slow)." >&2
  echo "      To enable KVM: sudo usermod -aG kvm $USER  (then log out/in)" >&2
fi

echo "=== Booting VM ==="
echo "  ISO       : $ISO"
echo "  CIDATA    : $CIDATA_ISO"
echo "  Disk      : $DISK ($DISK_SIZE)"
echo "  Memory    : ${MEM} MiB,  CPUs: $CPUS"
if [[ -n "$SERIAL_LOG" ]]; then
  echo "  Console   : serial -> $SERIAL_LOG (background)"
  SERIAL_ARGS=(-display none -serial "file:$SERIAL_LOG")
else
  echo "  Console   : serial on this terminal (Ctrl-A X to quit QEMU)"
  SERIAL_ARGS=(-nographic -serial mon:stdio)
fi
echo "  SSH fwd   : localhost:${SSH_PORT} -> guest:22 (post-install)"
echo ""

# Network: by default attach user-mode NAT (so post-install k8s join works).
# With NO_NETWORK=1, attach no NIC at all — proves the offline /drivers/ repo
# is self-sufficient (this is the test that would have caught the
# 2026-05-25 broadcom-sta-dkms missing-deps install failure).
if [[ "$NO_NETWORK" == "1" ]]; then
  echo "  Network   : NONE (NO_NETWORK=1 — proves offline-install works)"
  NET_ARGS=(-nic none)
else
  NET_ARGS=(
    -netdev user,id=n0,hostfwd=tcp::${SSH_PORT}-:22
    -device virtio-net-pci,netdev=n0
  )
fi

# USB passthrough.  Allows testing real USB WiFi adapter support inside the
# guest: install-time driver loading, netplan binding, kubeadm-join over
# WiFi, etc.  Without this, QEMU's virtio-net NAT papers over driver bugs.
#
# USB_PASSTHROUGH accepts:
#   ""                    no passthrough (default)
#   "VID:PID"             single device, hex IDs as shown by `lsusb`
#   "VID:PID,VID:PID,..." multiple devices
#   "auto"                every USB device whose ID matches a known WiFi
#                         adapter (Realtek 8852/8812/8821/8814, Ralink, etc.)
#
# Implementation notes:
#   * We attach a `qemu-xhci` controller (USB 3.0) so the adapter shows up
#     to the guest as it would on real hardware.
#   * `-device usb-host` claims the device by VID/PID at start.  QEMU
#     (running as $USER) needs r/w access to /dev/bus/usb/BBB/DDD, so we
#     sudo-chmod the matching node.  We do NOT detach the host kernel
#     driver — the device is `Driver=[none]` on the host since we don't
#     ship rtl8852cu there either; if a future device IS bound to a host
#     driver, `usb-host` will fail and you'll need to `modprobe -r` it
#     first (we print a hint).
#   * The pass-through is *live*: unplug = guest sees disconnect.
USB_ARGS=()
if [[ -n "$USB_PASSTHROUGH" ]]; then
  command -v lsusb >/dev/null || { echo "lsusb not found (apt install usbutils)" >&2; exit 1; }

  declare -a PT_IDS=()
  if [[ "$USB_PASSTHROUGH" == "auto" ]]; then
    # Known USB WiFi chipset VID:PIDs we ship drivers for.  Extend as needed.
    # (Format: ERE matched against the "ID xxxx:yyyy" column of lsusb.)
    WIFI_RE='0bda:[0-9a-f]{4}|0db0:991d|148f:[0-9a-f]{4}|0846:[0-9a-f]{4}|2357:[0-9a-f]{4}'
    while IFS= read -r line; do
      id=$(echo "$line" | awk '{print $6}')
      [[ -n "$id" ]] && PT_IDS+=("$id")
    done < <(lsusb | grep -E "ID ($WIFI_RE)" || true)
    if [[ ${#PT_IDS[@]} -eq 0 ]]; then
      echo "USB_PASSTHROUGH=auto but no known USB WiFi adapter found in lsusb" >&2
      exit 1
    fi
    echo "  USB auto  : detected ${#PT_IDS[@]} adapter(s): ${PT_IDS[*]}"
  else
    IFS=',' read -r -a PT_IDS <<< "$USB_PASSTHROUGH"
  fi

  USB_ARGS+=(-device qemu-xhci,id=xhci)
  for id in "${PT_IDS[@]}"; do
    [[ "$id" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]] || {
      echo "USB_PASSTHROUGH: bad VID:PID '$id' (expected 4hex:4hex)" >&2; exit 1; }
    vid="${id%:*}"; pid="${id#*:}"
    # Resolve current /dev/bus/usb/BBB/DDD node so we can chmod it.
    bus_dev=$(lsusb -d "$id" 2>/dev/null | awk '{printf "%s/%s\n", $2, substr($4,1,3)}' | head -1)
    if [[ -z "$bus_dev" ]]; then
      echo "USB_PASSTHROUGH: device $id not present on host (lsusb shows nothing)" >&2
      exit 1
    fi
    node="/dev/bus/usb/$bus_dev"
    if [[ ! -w "$node" ]]; then
      echo "  USB chmod : $node (needs sudo so QEMU can claim it)"
      sudo chmod a+rw "$node" || { echo "chmod $node failed" >&2; exit 1; }
    fi
    # Warn if a host driver is currently bound — usb-host will likely fail.
    if drv=$(lsusb -t 2>/dev/null | awk -v b="${bus_dev%%/*}" -v d="${bus_dev##*/}" \
              '/^\// {gsub(/Bus 0*/, "", $2); host_bus=$2+0} \
               /Dev '"$((10#${bus_dev##*/}))"',/ {for(i=1;i<=NF;i++) if($i~/^Driver=/) print substr($i,8)}' \
              | grep -vE '^(\[none\]|hub|usbfs)?$' | head -1); then
      [[ -n "$drv" ]] && echo "  USB warn  : $id is bound to host driver '$drv' — if QEMU fails, 'sudo modprobe -r $drv' first"
    fi
    USB_ARGS+=(-device "usb-host,bus=xhci.0,vendorid=0x${vid},productid=0x${pid}")
    echo "  USB fwd   : $id -> guest (host node $node)"
  done
fi

exec qemu-system-x86_64 \
  $ACCEL \
  -smp "$CPUS" -m "$MEM" \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$OVMF_VARS" \
  -drive file="$DISK",if=virtio,format=qcow2,cache=none \
  -drive file="$ISO",media=cdrom,readonly=on \
  -drive file="$CIDATA_ISO",media=cdrom,readonly=on \
  -boot order=dc,menu=off \
  "${NET_ARGS[@]}" \
  "${USB_ARGS[@]}" \
  -device virtio-rng-pci \
  "${SERIAL_ARGS[@]}"
