#!/usr/bin/env bats
# tests/usb-helpers.bats — Unit tests for lib/usb-helpers.sh
#
# Run:  bats tests/usb-helpers.bats
# Install bats: sudo apt install bats  (or: npm install -g bats)

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  source "$REPO_DIR/lib/usb-helpers.sh"
  TEST_TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ─── die ────────────────────────────────────────────────────────────────

@test "die prints error to stderr and exits 1" {
  run die "something broke"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Error: something broke"* ]]
}

# ─── validate_command ───────────────────────────────────────────────────

@test "validate_command succeeds for an available command" {
  run validate_command bash "install bash"
  [ "$status" -eq 0 ]
}

@test "validate_command fails for a missing command" {
  run validate_command nonexistent_cmd_xyz "sudo apt install xyz"
  [ "$status" -eq 1 ]
  [[ "$output" == *"nonexistent_cmd_xyz is required"* ]]
}

# ─── validate_not_empty ─────────────────────────────────────────────────

@test "validate_not_empty succeeds with a value" {
  run validate_not_empty "WiFi SSID" "MyNetwork"
  [ "$status" -eq 0 ]
}

@test "validate_not_empty fails with empty string" {
  run validate_not_empty "WiFi SSID" ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"WiFi SSID is required"* ]]
}

# ─── validate_file ──────────────────────────────────────────────────────

@test "validate_file succeeds when file exists" {
  touch "$TEST_TMP/exists.txt"
  run validate_file "$TEST_TMP/exists.txt" "file missing"
  [ "$status" -eq 0 ]
}

@test "validate_file fails when file does not exist" {
  run validate_file "$TEST_TMP/nope.txt" "SSH key missing at /path"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SSH key missing at /path"* ]]
}

# ─── escape_for_sed ─────────────────────────────────────────────────────

@test "escape_for_sed escapes dollar signs" {
  result=$(escape_for_sed '$6$rounds')
  [[ "$result" == *'\$'* ]]
}

@test "escape_for_sed escapes ampersand" {
  result=$(escape_for_sed 'foo&bar')
  [[ "$result" == *'\&'* ]]
}

@test "escape_for_sed escapes forward slash" {
  result=$(escape_for_sed 'foo/bar')
  [[ "$result" == *'\/'* ]]
}

@test "escape_for_sed passes through plain strings unchanged" {
  result=$(escape_for_sed 'hello-world_123')
  [ "$result" = "hello-world_123" ]
}

# ─── load_secrets ───────────────────────────────────────────────────────

@test "load_secrets sources the file and exports variables" {
  cat > "$TEST_TMP/secrets.env" <<'EOF'
WIFI_SSID="test-network"
WIFI_PASSWORD="test-pass"
EOF
  unset WIFI_SSID WIFI_PASSWORD 2>/dev/null || true
  load_secrets "$TEST_TMP/secrets.env"
  [ "$WIFI_SSID" = "test-network" ]
  [ "$WIFI_PASSWORD" = "test-pass" ]
}

@test "load_secrets does nothing when file does not exist" {
  run load_secrets "$TEST_TMP/nonexistent.env"
  [ "$status" -eq 0 ]
}

# ─── render_template ────────────────────────────────────────────────────

@test "render_template replaces single placeholder" {
  echo "ssid: __WIFI_SSID__" > "$TEST_TMP/template.yaml"
  render_template "$TEST_TMP/template.yaml" "$TEST_TMP/output.yaml" \
    "WIFI_SSID=MyNetwork"
  result=$(cat "$TEST_TMP/output.yaml")
  [ "$result" = "ssid: MyNetwork" ]
}

@test "render_template replaces multiple placeholders" {
  cat > "$TEST_TMP/template.yaml" <<'EOF'
ssid: __WIFI_SSID__
pass: __WIFI_PASSWORD__
ip: __MASTER_IP__
EOF
  render_template "$TEST_TMP/template.yaml" "$TEST_TMP/output.yaml" \
    "WIFI_SSID=MyNet" "WIFI_PASSWORD=s3cret" "MASTER_IP=10.0.0.1"
  grep -q "ssid: MyNet" "$TEST_TMP/output.yaml"
  grep -q "pass: s3cret" "$TEST_TMP/output.yaml"
  grep -q "ip: 10.0.0.1" "$TEST_TMP/output.yaml"
}

@test "render_template handles special characters in values" {
  echo "hash: __PASSWORD_HASH__" > "$TEST_TMP/template.yaml"
  render_template "$TEST_TMP/template.yaml" "$TEST_TMP/output.yaml" \
    'PASSWORD_HASH=$6$rounds=5000$saltsalt$longhashvalue'
  grep -q 'hash: \$6\$rounds=5000\$saltsalt\$longhashvalue' "$TEST_TMP/output.yaml"
}

@test "render_template replaces all occurrences of a placeholder" {
  cat > "$TEST_TMP/template.yaml" <<'EOF'
first: __WIFI_SSID__
second: __WIFI_SSID__
EOF
  render_template "$TEST_TMP/template.yaml" "$TEST_TMP/output.yaml" \
    "WIFI_SSID=Repeated"
  count=$(grep -c "Repeated" "$TEST_TMP/output.yaml")
  [ "$count" -eq 2 ]
}

@test "render_template leaves unmatched placeholders alone" {
  echo "keep: __UNKNOWN__" > "$TEST_TMP/template.yaml"
  render_template "$TEST_TMP/template.yaml" "$TEST_TMP/output.yaml" \
    "WIFI_SSID=Something"
  grep -q "__UNKNOWN__" "$TEST_TMP/output.yaml"
}

# ─── write_grub_cfg ─────────────────────────────────────────────────────

@test "write_grub_cfg creates a valid GRUB config" {
  write_grub_cfg "$TEST_TMP/grub.cfg" "Install Kubernetes Node"
  grep -q 'set timeout=30' "$TEST_TMP/grub.cfg"
  grep -q 'Boot from disk (no changes)' "$TEST_TMP/grub.cfg"
  grep -q 'WIPE DISK & Install Kubernetes Node' "$TEST_TMP/grub.cfg"
}

@test "write_grub_cfg includes autoinstall kernel params" {
  write_grub_cfg "$TEST_TMP/grub.cfg" "Install K8s"
  grep -q 'autoinstall ci.ds=nocloud' "$TEST_TMP/grub.cfg"
}

@test "write_grub_cfg uses the provided menu label" {
  write_grub_cfg "$TEST_TMP/grub.cfg" "Install Kubernetes HEAD Node"
  grep -q 'WIPE DISK & Install Kubernetes HEAD Node' "$TEST_TMP/grub.cfg"
}

@test "write_grub_cfg includes HWE kernel entry" {
  write_grub_cfg "$TEST_TMP/grub.cfg" "Install Kubernetes Node"
  grep -q 'hwe-vmlinuz' "$TEST_TMP/grub.cfg"
  grep -q 'hwe-initrd' "$TEST_TMP/grub.cfg"
}

@test "write_grub_cfg includes UEFI firmware entry" {
  write_grub_cfg "$TEST_TMP/grub.cfg" "Install K8s"
  grep -q 'UEFI Firmware Settings' "$TEST_TMP/grub.cfg"
  grep -q 'fwsetup' "$TEST_TMP/grub.cfg"
}

# ─── find_ubuntu_iso ────────────────────────────────────────────────────

@test "find_ubuntu_iso finds ISO by glob pattern" {
  touch "$TEST_TMP/ubuntu-24.04.2-live-server-amd64.iso"
  UBUNTU_ISO=""
  find_ubuntu_iso "$TEST_TMP"
  [[ "$UBUNTU_ISO" == *"ubuntu-24.04"*".iso" ]]
}

@test "find_ubuntu_iso respects UBUNTU_ISO if already set" {
  touch "$TEST_TMP/custom.iso"
  UBUNTU_ISO="$TEST_TMP/custom.iso"
  find_ubuntu_iso "$TEST_TMP"
  [ "$UBUNTU_ISO" = "$TEST_TMP/custom.iso" ]
}

@test "find_ubuntu_iso fails when no ISO found" {
  UBUNTU_ISO=""
  run find_ubuntu_iso "$TEST_TMP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Ubuntu Server ISO not found"* ]]
}

# ─── validate_block_device ──────────────────────────────────────────────

@test "validate_block_device fails for a regular file" {
  touch "$TEST_TMP/fakefile"
  run validate_block_device "$TEST_TMP/fakefile"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a block device"* ]]
}

@test "validate_block_device fails for nonexistent path" {
  run validate_block_device "/dev/sdZZZ_nonexistent"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a block device"* ]]
}
