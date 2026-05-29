#!/usr/bin/env bats
# tests/autoinstall-consistency.bats
#
# Static checks that catch drift between:
#   - OFFLINE_PACKAGES in config.env (what we bundle on the USB)
#   - the apt-get install list in autoinstall/user-data + head-user-data
#     (what the installer actually tries to install with no network)
#
# Failure here = a USB that will fail to install on a real, offline machine.
# No internet or VM needed; runs in milliseconds.

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# Extract every package name from the late-command apt-get install block.
# We look for the curtin in-target apt-get install line and grab continuation
# lines until the closing yaml literal block ends.
_extract_late_install_pkgs() {
  local file="$1"
  python3 - "$file" <<'PY'
import re, sys, yaml, pathlib
doc = pathlib.Path(sys.argv[1]).read_text()
data = yaml.safe_load(doc)
ai = data.get("autoinstall", data)
late = ai.get("late-commands", []) or []
# Our offline-install late-command has a unique signature:
#   curtin in-target --target=/target -- env DEBIAN_FRONTEND=noninteractive \
#     apt-get install -y --allow-unauthenticated --no-install-recommends \
#       PKG PKG PKG
# We only want the package tokens from THAT specific command.
SIG = "--allow-unauthenticated --no-install-recommends"
PKG_RE = re.compile(r"^[a-z0-9][a-z0-9+.\-]+$")
for cmd in late:
    if not isinstance(cmd, str): continue
    if SIG not in cmd: continue
    after = cmd.split(SIG, 1)[1]
    # Cut at the first shell metacharacter so we don't pick up tokens
    # from a trailing redirection / pipeline (e.g. `... | tee /var/log/x`
    # otherwise yields `tee` as a phantom "package").
    after = re.split(r"[|;<>&]", after, maxsplit=1)[0]
    # Strip yaml line-continuations and split on whitespace.
    for tok in re.split(r"[\s\\]+", after):
        tok = tok.strip()
        if PKG_RE.match(tok):
            print(tok)
PY
}

_extract_offline_packages() {
  # shellcheck disable=SC1090
  ( set +u; source "$REPO_DIR/config.env" >/dev/null; printf '%s\n' $OFFLINE_PACKAGES )
}

@test "autoinstall/user-data: every late-command package is in OFFLINE_PACKAGES" {
  command -v python3 >/dev/null || skip "python3 not available"
  python3 -c 'import yaml' 2>/dev/null || skip "PyYAML not available (pip install pyyaml)"

  local missing=()
  local offline; offline=$(_extract_offline_packages | sort -u)
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    if ! grep -qx "$pkg" <<<"$offline"; then
      missing+=("$pkg")
    fi
  done < <(_extract_late_install_pkgs "$REPO_DIR/autoinstall/user-data" | sort -u)

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Packages referenced in autoinstall/user-data late-commands but NOT in OFFLINE_PACKAGES:" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    echo "" >&2
    echo "Fix: add them to OFFLINE_PACKAGES in config.env so they're bundled" >&2
    echo "     on the USB.  Otherwise the target machine has no network and" >&2
    echo "     apt will exit 100 in the late-command stage." >&2
    return 1
  fi
}

@test "autoinstall/head-user-data: every late-command package is in OFFLINE_PACKAGES" {
  command -v python3 >/dev/null || skip "python3 not available"
  python3 -c 'import yaml' 2>/dev/null || skip "PyYAML not available"

  local missing=()
  local offline; offline=$(_extract_offline_packages | sort -u)
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    if ! grep -qx "$pkg" <<<"$offline"; then
      missing+=("$pkg")
    fi
  done < <(_extract_late_install_pkgs "$REPO_DIR/autoinstall/head-user-data" | sort -u)

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Packages referenced in autoinstall/head-user-data late-commands but NOT in OFFLINE_PACKAGES:" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    return 1
  fi
}

# Extract packages from the top-level `packages:` block of an autoinstall file.
_extract_subiquity_packages() {
  awk '
    /^  packages:/   { in_block=1; next }
    in_block && /^  [a-zA-Z]/ { in_block=0 }
    in_block && /^    - / { sub(/^    - /,""); print }
  ' "$1"
}

# Packages that live in main/restricted on the Ubuntu Server live ISO and
# can therefore appear in subiquity's `packages:` list without needing the
# bundled /cdrom/drivers/ offline repo.
_LIVE_ISO_ALLOWLIST=(
  curl ca-certificates gpg apt-transport-https
  linux-firmware wpasupplicant
)

# Shared check: every package in the subiquity `packages:` list must be
# resolvable at install time -- either it lives in main/restricted on the
# live ISO (allow-list above) OR it's bundled in /cdrom/drivers/ via
# OFFLINE_PACKAGES.  Otherwise subiquity exits 100 trying to download it
# (the original 2026-05-22 install_iw failure mode), unless apt is also
# configured with AllowUnauthenticated for the offline repo.
_assert_packages_resolvable() {
  local file="$1"
  command -v python3 >/dev/null || skip "python3 not available"
  python3 -c 'import yaml' 2>/dev/null || skip "PyYAML not available"

  # Require the apt: AllowUnauthenticated conf so the offline /drivers/
  # repo is actually usable by subiquity's `packages:` resolution.
  if ! grep -q 'AllowUnauthenticated' "$file"; then
    echo "Missing apt.conf AllowUnauthenticated in $file" >&2
    echo "Without it, subiquity refuses unsigned packages from /cdrom/drivers/" >&2
    echo "and the packages: list will fail for anything outside main/restricted." >&2
    return 1
  fi

  local allow; allow=$(printf '%s\n' "${_LIVE_ISO_ALLOWLIST[@]}" | sort -u)
  local offline; offline=$(_extract_offline_packages | sort -u)
  local bad=()
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    if grep -qx "$pkg" <<<"$allow"; then continue; fi
    if grep -qx "$pkg" <<<"$offline"; then continue; fi
    bad+=("$pkg")
  done < <(_extract_subiquity_packages "$file" | sort -u)

  if [[ ${#bad[@]} -gt 0 ]]; then
    echo "Packages in $file `packages:` are NOT in main/restricted on the live" >&2
    echo "ISO and NOT in OFFLINE_PACKAGES, so subiquity will fail to fetch them:" >&2
    printf '  - %s\n' "${bad[@]}" >&2
    echo "" >&2
    echo "Fix: either add them to OFFLINE_PACKAGES (config.env) so they're" >&2
    echo "bundled on the USB, or move them to a late-command apt-get install." >&2
    return 1
  fi
}

@test "autoinstall/user-data: subiquity packages: list is resolvable offline" {
  _assert_packages_resolvable "$REPO_DIR/autoinstall/user-data"
}

@test "autoinstall/head-user-data: subiquity packages: list is resolvable offline" {
  _assert_packages_resolvable "$REPO_DIR/autoinstall/head-user-data"
}
