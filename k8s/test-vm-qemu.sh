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
set -euo pipefail

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

exec qemu-system-x86_64 \
  $ACCEL \
  -smp "$CPUS" -m "$MEM" \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$OVMF_VARS" \
  -drive file="$DISK",if=virtio,format=qcow2,cache=none \
  -drive file="$ISO",media=cdrom,readonly=on \
  -drive file="$CIDATA_ISO",media=cdrom,readonly=on \
  -boot order=dc,menu=off \
  -netdev user,id=n0,hostfwd=tcp::${SSH_PORT}-:22 \
  -device virtio-net-pci,netdev=n0 \
  -device virtio-rng-pci \
  "${SERIAL_ARGS[@]}"
