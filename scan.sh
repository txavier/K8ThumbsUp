#!/usr/bin/env bash
# crypto-scan.sh — Scan disks for cryptocurrency wallets/keys before wiping.
# Runs from the live USB environment (early-commands or standalone).
# If crypto artifacts are found, prints a report and halts.
# If nothing is found, exits 0 so the install can continue.
set -euo pipefail

REPORT=""
FOUND=0

log()  { echo "[crypto-scan] $*"; }
hit()  { FOUND=1; REPORT+="  $*"$'\n'; }

# --- Mount all discoverable partitions read-only ---
MOUNTPOINTS=()

cleanup() {
  for mp in "${MOUNTPOINTS[@]}"; do
    umount "$mp" 2>/dev/null || true
    rmdir "$mp" 2>/dev/null || true
  done
}
trap cleanup EXIT

mount_all_partitions() {
  for part in $(lsblk -lnpo NAME,TYPE | awk '$2=="part" || $2=="lvm" {print $1}'); do
    local fstype
    fstype=$(blkid -o value -s TYPE "$part" 2>/dev/null || true)
    [[ -n "$fstype" ]] || continue
    # Skip swap, iso9660 (the USB itself), vfat EFI partitions < 1G
    case "$fstype" in
      swap|iso9660|squashfs) continue ;;
    esac
    local mp
    mp=$(mktemp -d /tmp/cryptoscan.XXXX)
    if mount -o ro "$part" "$mp" 2>/dev/null; then
      MOUNTPOINTS+=("$mp")
      log "Mounted $part ($fstype) at $mp"
    else
      rmdir "$mp" 2>/dev/null || true
    fi
  done
}

# --- Wallet file patterns ---
scan_wallet_files() {
  log "Scanning for wallet files..."

  local patterns=(
    # Bitcoin Core
    "wallet.dat"
    # Electrum
    "default_wallet"
    "electrum.dat"
    # Ethereum / Geth keystore
    "UTC--*"
    # Monero
    "*.keys"
    # Litecoin
    "litecoin/wallet.dat"
    # Dogecoin
    "dogecoin/wallet.dat"
    # Generic
    "keystore.json"
  )

  for mp in "${MOUNTPOINTS[@]}"; do
    for pat in "${patterns[@]}"; do
      while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        local size
        size=$(stat -c%s "$f" 2>/dev/null || echo 0)
        # wallet.dat should be > 0 bytes; UTC-- keystore files are typically small JSON
        if [[ "$size" -gt 0 ]]; then
          hit "WALLET FILE: $f (${size} bytes)"
        fi
      done < <(find "$mp" -maxdepth 6 -iname "$pat" -type f 2>/dev/null || true)
    done
  done
}

# --- Known wallet directories ---
scan_wallet_dirs() {
  log "Scanning for wallet directories..."

  local dirs=(
    ".bitcoin"
    ".ethereum"
    ".electrum"
    ".monero"
    ".litecoin"
    ".dogecoin"
    ".solana"
    ".config/solana"
    ".zcash"
    ".dash"
    ".atomic"              # Atomic Wallet
    "Electrum"
    "Exodus"               # Exodus wallet
    "Coinomi"
    "Wasabi Wallet"
    "Ledger Live"
    "Trezor"
  )

  for mp in "${MOUNTPOINTS[@]}"; do
    for d in "${dirs[@]}"; do
      while IFS= read -r found; do
        [[ -n "$found" ]] || continue
        local count
        count=$(find "$found" -type f 2>/dev/null | head -20 | wc -l)
        hit "WALLET DIR:  $found/ ($count files)"
      done < <(find "$mp" -maxdepth 4 -type d -iname "$d" 2>/dev/null || true)
    done
  done
}

# --- Private key patterns in common locations ---
scan_key_patterns() {
  log "Scanning for private key patterns in common files..."

  # Only scan likely locations (home dirs, Documents, Desktop) to keep it fast
  local search_dirs=()
  for mp in "${MOUNTPOINTS[@]}"; do
    for sub in home root "Users" "Documents and Settings"; do
      [[ -d "$mp/$sub" ]] && search_dirs+=("$mp/$sub")
    done
  done

  [[ ${#search_dirs[@]} -gt 0 ]] || return 0

  # Patterns that indicate crypto private keys (hex keys, WIF, seed phrases)
  # Bitcoin WIF: 5, K, or L followed by base58 (51 chars total)
  # Ethereum: 0x followed by 64 hex chars
  # BIP39 seed: 12+ common English words in sequence (detected by file names only)
  local key_files
  key_files=$(grep -rlE \
    '(^|\s)(5[HJK][1-9A-HJ-NP-Za-km-z]{49}|[KL][1-9A-HJ-NP-Za-km-z]{51})(\s|$)' \
    "${search_dirs[@]}" \
    --include='*.txt' --include='*.json' --include='*.csv' --include='*.key' \
    --include='*.pem' --include='*.wallet' --include='*.bak' --include='*.dat' \
    -l 2>/dev/null || true)

  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    hit "KEY PATTERN: $f (possible Bitcoin WIF private key)"
  done <<< "$key_files"

  # Ethereum private key pattern (64 hex chars, often prefixed with 0x)
  local eth_files
  eth_files=$(grep -rlE \
    '(^|\s)0x[0-9a-fA-F]{64}(\s|$)' \
    "${search_dirs[@]}" \
    --include='*.txt' --include='*.json' --include='*.csv' --include='*.key' \
    --include='*.wallet' --include='*.bak' \
    -l 2>/dev/null || true)

  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    hit "KEY PATTERN: $f (possible Ethereum private key)"
  done <<< "$eth_files"
}

# ===== Main =====
log "Starting cryptocurrency scan..."
log ""

mount_all_partitions

if [[ ${#MOUNTPOINTS[@]} -eq 0 ]]; then
  log "No mountable partitions found. Nothing to scan."
  exit 0
fi

scan_wallet_files
scan_wallet_dirs
scan_key_patterns

echo ""
echo "========================================"
if [[ $FOUND -eq 1 ]]; then
  echo "  CRYPTOCURRENCY ARTIFACTS FOUND"
  echo "========================================"
  echo ""
  echo "$REPORT"
  echo "========================================"
  echo "  WIPE ABORTED — review the above before proceeding."
  echo "  Remove the USB and reboot, or press Ctrl-C."
  echo "========================================"
  echo ""
  # Block forever — user must pull the USB or Ctrl-C
  log "Halting. Will not proceed with disk wipe."
  while true; do sleep 3600; done
else
  echo "  No cryptocurrency artifacts found."
  echo "========================================"
  echo ""
  log "Scan complete. Safe to proceed with wipe."
  exit 0
fi
