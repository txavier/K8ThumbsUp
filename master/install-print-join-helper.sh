#!/usr/bin/env bash
# install-print-join-helper.sh — one-shot retrofit for an existing master.
#
# Installs /usr/local/bin/k8s-print-join-command.sh and rewrites the
# forced-command for the worker auto-join key in
# /home/kube/.ssh/authorized_keys so that worker reimages no longer
# leave stale Node objects behind.
#
# Run this ONCE on the master after pulling the latest K8ThumbsUp.
#
#   sudo bash install-print-join-helper.sh
#
# Idempotent: safe to re-run.

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: must run as root (use sudo)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/k8s-print-join-command.sh"
DST="/usr/local/bin/k8s-print-join-command.sh"
AUTH="/home/kube/.ssh/authorized_keys"

if [[ ! -f "$SRC" ]]; then
  echo "ERROR: $SRC not found" >&2
  exit 1
fi

if [[ ! -f "$AUTH" ]]; then
  echo "ERROR: $AUTH not found — is this the master?" >&2
  exit 1
fi

echo "==> installing $DST"
install -m 0755 -o root -g root "$SRC" "$DST"

# Rewrite the forced-command on every line that currently invokes
# `kubeadm token create --print-join-command`.  Leave other lines alone.
echo "==> updating forced-command in $AUTH"
cp "$AUTH" "$AUTH.bak.$(date +%s)"
sed -i \
  -e "s|command=\"kubeadm token create --print-join-command\"|command=\"$DST\"|g" \
  "$AUTH"

if grep -q "command=\"$DST\"" "$AUTH"; then
  echo "==> forced-command updated:"
  grep -n "command=" "$AUTH" || true
else
  echo "WARN: no lines matched the old forced-command pattern." >&2
  echo "      Check $AUTH manually." >&2
fi

# Quick sanity check.
if sudo -u kube "$DST" </dev/null >/tmp/k8s-join-test.$$ 2>&1; then
  if grep -q "kubeadm join" /tmp/k8s-join-test.$$; then
    echo "==> OK: wrapper prints a valid join command."
  else
    echo "WARN: wrapper ran but did not produce a join command:" >&2
    cat /tmp/k8s-join-test.$$ >&2
  fi
else
  echo "WARN: wrapper exited non-zero. Output:" >&2
  cat /tmp/k8s-join-test.$$ >&2
fi
rm -f /tmp/k8s-join-test.$$

echo "Done."
