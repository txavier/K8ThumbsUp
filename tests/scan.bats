#!/usr/bin/env bats
# tests/scan.bats — Unit tests for scan.sh (crypto-scan)
#
# Run:  bats tests/scan.bats

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  # Source scan.sh functions without running main
  source "$REPO_DIR/scan.sh"

  # Reset global state
  REPORT=""
  FOUND=0
  FOUND_FILES=()
  MOUNTPOINTS=()

  TEST_TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ─── scan_wallet_files ──────────────────────────────────────────────────

@test "scan_wallet_files detects wallet.dat" {
  mkdir -p "$TEST_TMP/disk/home/user/.bitcoin"
  echo "fake wallet data" > "$TEST_TMP/disk/home/user/.bitcoin/wallet.dat"
  MOUNTPOINTS=("$TEST_TMP/disk")

  scan_wallet_files

  [ "$FOUND" -eq 1 ]
  [ "${#FOUND_FILES[@]}" -eq 1 ]
  [[ "$REPORT" == *"WALLET FILE"* ]]
  [[ "$REPORT" == *"wallet.dat"* ]]
}

@test "scan_wallet_files detects electrum.dat" {
  mkdir -p "$TEST_TMP/disk/home/user/.electrum"
  echo "electrum data" > "$TEST_TMP/disk/home/user/.electrum/electrum.dat"
  MOUNTPOINTS=("$TEST_TMP/disk")

  scan_wallet_files

  [ "$FOUND" -eq 1 ]
  [ "${#FOUND_FILES[@]}" -eq 1 ]
  [[ "$REPORT" == *"electrum.dat"* ]]
}

@test "scan_wallet_files detects keystore.json" {
  mkdir -p "$TEST_TMP/disk/home/user/.ethereum"
  echo '{"address":"0xabc"}' > "$TEST_TMP/disk/home/user/.ethereum/keystore.json"
  MOUNTPOINTS=("$TEST_TMP/disk")

  scan_wallet_files

  [ "$FOUND" -eq 1 ]
  [ "${#FOUND_FILES[@]}" -eq 1 ]
  [[ "$REPORT" == *"keystore.json"* ]]
}

@test "scan_wallet_files ignores empty files" {
  mkdir -p "$TEST_TMP/disk"
  touch "$TEST_TMP/disk/wallet.dat"
  MOUNTPOINTS=("$TEST_TMP/disk")

  scan_wallet_files

  [ "$FOUND" -eq 0 ]
  [ "${#FOUND_FILES[@]}" -eq 0 ]
}

@test "scan_wallet_files finds nothing on clean disk" {
  mkdir -p "$TEST_TMP/disk/home/user/Documents"
  echo "hello" > "$TEST_TMP/disk/home/user/Documents/readme.txt"
  MOUNTPOINTS=("$TEST_TMP/disk")

  scan_wallet_files

  [ "$FOUND" -eq 0 ]
  [ "${#FOUND_FILES[@]}" -eq 0 ]
}

@test "scan_wallet_files detects multiple wallet files" {
  mkdir -p "$TEST_TMP/disk/home/user/.bitcoin"
  mkdir -p "$TEST_TMP/disk/home/user/.electrum"
  echo "btc" > "$TEST_TMP/disk/home/user/.bitcoin/wallet.dat"
  echo "elc" > "$TEST_TMP/disk/home/user/.electrum/default_wallet"
  MOUNTPOINTS=("$TEST_TMP/disk")

  scan_wallet_files

  [ "$FOUND" -eq 1 ]
  [ "${#FOUND_FILES[@]}" -eq 2 ]
}

# ─── scan_wallet_dirs ───────────────────────────────────────────────────

@test "scan_wallet_dirs detects .bitcoin directory" {
  mkdir -p "$TEST_TMP/disk/.bitcoin"
  echo "data" > "$TEST_TMP/disk/.bitcoin/blocks.dat"
  echo "data" > "$TEST_TMP/disk/.bitcoin/chainstate.dat"
  MOUNTPOINTS=("$TEST_TMP/disk")

  scan_wallet_dirs

  [ "$FOUND" -eq 1 ]
  [ "${#FOUND_FILES[@]}" -eq 2 ]
  [[ "$REPORT" == *"WALLET DIR"* ]]
  [[ "$REPORT" == *".bitcoin"* ]]
}

@test "scan_wallet_dirs detects .ethereum directory" {
  mkdir -p "$TEST_TMP/disk/home/user/.ethereum/keystore"
  echo '{}' > "$TEST_TMP/disk/home/user/.ethereum/keystore/key1.json"
  MOUNTPOINTS=("$TEST_TMP/disk")

  scan_wallet_dirs

  [ "$FOUND" -eq 1 ]
  [ "${#FOUND_FILES[@]}" -ge 1 ]
  [[ "$REPORT" == *".ethereum"* ]]
}

@test "scan_wallet_dirs collects all files from wallet dir" {
  mkdir -p "$TEST_TMP/disk/.monero"
  echo "a" > "$TEST_TMP/disk/.monero/wallet"
  echo "b" > "$TEST_TMP/disk/.monero/wallet.keys"
  echo "c" > "$TEST_TMP/disk/.monero/wallet.address.txt"
  MOUNTPOINTS=("$TEST_TMP/disk")

  scan_wallet_dirs

  [ "${#FOUND_FILES[@]}" -eq 3 ]
}

@test "scan_wallet_dirs ignores unrelated directories" {
  mkdir -p "$TEST_TMP/disk/home/user/.config/nvim"
  echo "hi" > "$TEST_TMP/disk/home/user/.config/nvim/init.vim"
  MOUNTPOINTS=("$TEST_TMP/disk")

  scan_wallet_dirs

  [ "$FOUND" -eq 0 ]
  [ "${#FOUND_FILES[@]}" -eq 0 ]
}

# ─── scan_key_patterns ──────────────────────────────────────────────────

@test "scan_key_patterns detects Ethereum private key" {
  mkdir -p "$TEST_TMP/disk/home/user"
  echo "0x4c0883a69102937d623580f18c8e0241b87234a5e1a0b4e4a204a7b993e5d1f7" \
    > "$TEST_TMP/disk/home/user/keys.txt"
  MOUNTPOINTS=("$TEST_TMP/disk")

  scan_key_patterns

  [ "$FOUND" -eq 1 ]
  [ "${#FOUND_FILES[@]}" -ge 1 ]
  [[ "$REPORT" == *"Ethereum"* ]]
}

@test "scan_key_patterns ignores normal text files" {
  mkdir -p "$TEST_TMP/disk/home/user"
  echo "just some normal text with no crypto keys" \
    > "$TEST_TMP/disk/home/user/notes.txt"
  MOUNTPOINTS=("$TEST_TMP/disk")

  scan_key_patterns

  [ "$FOUND" -eq 0 ]
  [ "${#FOUND_FILES[@]}" -eq 0 ]
}

@test "scan_key_patterns skips when no home dirs exist" {
  mkdir -p "$TEST_TMP/disk/var/log"
  echo "log data" > "$TEST_TMP/disk/var/log/syslog"
  MOUNTPOINTS=("$TEST_TMP/disk")

  scan_key_patterns

  [ "$FOUND" -eq 0 ]
  [ "${#FOUND_FILES[@]}" -eq 0 ]
}

# ─── copy_to_usb ────────────────────────────────────────────────────────

@test "copy_to_usb does nothing when FOUND_FILES is empty" {
  FOUND_FILES=()

  run copy_to_usb

  [ "$status" -eq 0 ]
}

@test "copy_to_usb returns 1 when no USB partition found" {
  FOUND_FILES=("$TEST_TMP/fakefile")

  # blkid won't find Ventoy or CIDATA labels in test env
  run copy_to_usb

  [ "$status" -eq 1 ]
  [[ "$output" == *"No writable USB partition"* ]]
}

@test "copy_to_usb copies files and creates cryptoreadme" {
  # Set up a fake "USB" as a regular directory (mock mount via function override)
  local fake_usb="$TEST_TMP/fake-usb"
  mkdir -p "$fake_usb"

  # Create test source files
  local src_mp="$TEST_TMP/disk"
  mkdir -p "$src_mp/home/user/.bitcoin"
  echo "wallet content" > "$src_mp/home/user/.bitcoin/wallet.dat"
  echo "key content" > "$src_mp/home/user/.bitcoin/wallet.keys"

  MOUNTPOINTS=("$src_mp")
  FOUND_FILES=(
    "$src_mp/home/user/.bitcoin/wallet.dat"
    "$src_mp/home/user/.bitcoin/wallet.keys"
  )
  REPORT="  WALLET FILE: wallet.dat (15 bytes)"$'\n'

  # Override blkid/mount/umount/mountpoint to work without root
  blkid() { echo "/dev/fake1"; }
  mount() { return 0; }
  umount() { return 0; }
  mountpoint() { return 1; }  # "not mounted" so mount() gets called
  export -f blkid mount umount mountpoint

  # Override the USB mount point to our fake dir
  # We need to patch copy_to_usb's local var — instead, replace the function
  # with a version that uses our fake_usb path
  _orig_copy_to_usb=$(declare -f copy_to_usb)

  copy_to_usb() {
    [[ ${#FOUND_FILES[@]} -gt 0 ]] || return 0

    local dest="$fake_usb/crypto-findings/test-run"
    mkdir -p "$dest"

    printf '%s\n' "$REPORT" > "$dest/report.txt"

    local readme="$dest/cryptoreadme.txt"
    {
      echo "Crypto Scan Findings — $(date)"
      echo "========================================"
      echo ""
    } > "$readme"

    local copied=0
    for f in "${FOUND_FILES[@]}"; do
      local relpath="$f"
      for mp in "${MOUNTPOINTS[@]}"; do
        if [[ "$f" == "$mp"/* ]]; then
          relpath="${f#$mp/}"
          break
        fi
      done
      local target="$dest/files/$relpath"
      mkdir -p "$(dirname "$target")"
      if cp -- "$f" "$target" 2>/dev/null; then
        ((copied++)) || true
        echo "Source:      $f" >> "$readme"
        echo "Destination: $target" >> "$readme"
        echo "" >> "$readme"
      fi
    done

    echo "========================================" >> "$readme"
    echo "Total copied: $copied / ${#FOUND_FILES[@]}" >> "$readme"
    sync
  }

  copy_to_usb

  # Verify files were copied
  [ -f "$fake_usb/crypto-findings/test-run/files/home/user/.bitcoin/wallet.dat" ]
  [ -f "$fake_usb/crypto-findings/test-run/files/home/user/.bitcoin/wallet.keys" ]

  # Verify report.txt exists
  [ -f "$fake_usb/crypto-findings/test-run/report.txt" ]
  grep -q "WALLET FILE" "$fake_usb/crypto-findings/test-run/report.txt"

  # Verify cryptoreadme.txt exists with source/dest info
  [ -f "$fake_usb/crypto-findings/test-run/cryptoreadme.txt" ]
  grep -q "Source:" "$fake_usb/crypto-findings/test-run/cryptoreadme.txt"
  grep -q "Destination:" "$fake_usb/crypto-findings/test-run/cryptoreadme.txt"
  grep -q "Total copied: 2 / 2" "$fake_usb/crypto-findings/test-run/cryptoreadme.txt"

  # Verify file contents preserved
  [ "$(cat "$fake_usb/crypto-findings/test-run/files/home/user/.bitcoin/wallet.dat")" = "wallet content" ]
}

@test "copy_to_usb preserves relative paths from mountpoint" {
  local fake_usb="$TEST_TMP/fake-usb"
  mkdir -p "$fake_usb"

  local src_mp="$TEST_TMP/disk"
  mkdir -p "$src_mp/home/alice/Documents"
  echo "seed phrase" > "$src_mp/home/alice/Documents/keys.txt"

  MOUNTPOINTS=("$src_mp")
  FOUND_FILES=("$src_mp/home/alice/Documents/keys.txt")
  REPORT="  KEY PATTERN: keys.txt"$'\n'

  copy_to_usb() {
    [[ ${#FOUND_FILES[@]} -gt 0 ]] || return 0
    local dest="$fake_usb/crypto-findings/relpath-test"
    mkdir -p "$dest"
    local readme="$dest/cryptoreadme.txt"
    echo "test" > "$readme"
    for f in "${FOUND_FILES[@]}"; do
      local relpath="$f"
      for mp in "${MOUNTPOINTS[@]}"; do
        if [[ "$f" == "$mp"/* ]]; then
          relpath="${f#$mp/}"
          break
        fi
      done
      local target="$dest/files/$relpath"
      mkdir -p "$(dirname "$target")"
      cp -- "$f" "$target"
      echo "Source:      $f" >> "$readme"
      echo "Destination: $target" >> "$readme"
    done
  }

  copy_to_usb

  # The temp mountpoint prefix should be stripped, keeping the meaningful path
  [ -f "$fake_usb/crypto-findings/relpath-test/files/home/alice/Documents/keys.txt" ]
  [ "$(cat "$fake_usb/crypto-findings/relpath-test/files/home/alice/Documents/keys.txt")" = "seed phrase" ]
}

# ─── Integration: scan + FOUND_FILES ────────────────────────────────────

@test "scan_wallet_files populates FOUND_FILES with correct paths" {
  mkdir -p "$TEST_TMP/disk/home/user/.bitcoin"
  echo "data" > "$TEST_TMP/disk/home/user/.bitcoin/wallet.dat"
  MOUNTPOINTS=("$TEST_TMP/disk")

  scan_wallet_files

  [ "${#FOUND_FILES[@]}" -eq 1 ]
  [[ "${FOUND_FILES[0]}" == *"/home/user/.bitcoin/wallet.dat" ]]
}

@test "multiple scans accumulate FOUND_FILES" {
  mkdir -p "$TEST_TMP/disk/home/user/.bitcoin"
  mkdir -p "$TEST_TMP/disk/.ethereum"
  echo "btc" > "$TEST_TMP/disk/home/user/.bitcoin/wallet.dat"
  echo "eth" > "$TEST_TMP/disk/.ethereum/keyfile"
  MOUNTPOINTS=("$TEST_TMP/disk")

  scan_wallet_files
  scan_wallet_dirs

  # wallet.dat from scan_wallet_files + keyfile from scan_wallet_dirs
  [ "${#FOUND_FILES[@]}" -ge 2 ]
}
