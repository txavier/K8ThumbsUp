#!/usr/bin/env bash
# backup-logs-usb.sh — Copy install logs to the Ventoy USB drive.
# Run this if an error drops you to a shell during autoinstall.
# Usage: bash backup-logs-usb.sh

set -euo pipefail

USB=$(blkid -t LABEL="Ventoy" -o device 2>/dev/null | head -1)
if [[ -z "$USB" ]]; then
  echo "Error: Ventoy USB partition not found"
  exit 1
fi

mkdir -p /mnt
if ! mountpoint -q /mnt; then
  mount "$USB" /mnt
fi

LOGDIR="/mnt/install-logs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGDIR"

cp /var/log/installer/*.log "$LOGDIR/" 2>/dev/null || true
cp /var/log/syslog "$LOGDIR/" 2>/dev/null || true
cp /autoinstall.yaml "$LOGDIR/" 2>/dev/null || true

sync

echo "Logs saved to USB: install-logs/$(basename "$LOGDIR")/"
echo "You can now unmount with: umount /mnt"
