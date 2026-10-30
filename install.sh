#!/usr/bin/env bash
set -Eeuo pipefail

INSTALLER_VERSION="1.0.1"
REPO_RAW_BASE="${WEB_AUTH_REPO_RAW_BASE:-https://raw.githubusercontent.com/qq8658868/web-auth-firewall/main}"
SETUP_URL="${WEB_AUTH_SETUP_URL:-${REPO_RAW_BASE}/setup_web_firewall.sh}"
COMMAND_PATH="${WEB_AUTH_COMMAND_PATH:-/usr/local/sbin/web-auth-firewall}"

say() {
  printf '\033[1;32m[+] %s\033[0m\n' "$*"
}

die() {
  printf '\033[1;31m[!] %s\033[0m\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Web Authentication Firewall one-click installer ${INSTALLER_VERSION}

Usage:
  sudo bash install.sh [setup options]

With no options, the installer runs:
  setup_web_firewall.sh --install

Examples:
  sudo bash install.sh
  sudo bash install.sh --port 18622
  sudo bash install.sh --path /my-login --allow-icmp

Set WEB_AUTH_DRY_RUN=1 to download and validate the main script without running it.
After installation, run "sudo web-auth-firewall" to open the management menu.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "${EUID}" -ne 0 ]]; then
  die "This installer must be run as root (use: sudo bash install.sh)"
fi

command -v bash >/dev/null 2>&1 || die "bash is required"
command -v mktemp >/dev/null 2>&1 || die "mktemp is required"

tmp_file="$(mktemp /tmp/web-auth-install.XXXXXX)"
cleanup() {
  rm -f "${tmp_file}"
}
trap cleanup EXIT

download() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 \
      -o "${tmp_file}" "${SETUP_URL}"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "${tmp_file}" --tries=3 --timeout=30 "${SETUP_URL}"
  else
    die "curl or wget is required"
  fi
}

say "Downloading setup_web_firewall.sh"
download

[[ -s "${tmp_file}" ]] || die "Downloaded file is empty"
grep -q '#!/usr/bin/env bash' "${tmp_file}" \
  || die "Downloaded file does not look like the expected shell script"
grep -q 'setup_web_firewall.sh - Web authentication firewall' "${tmp_file}" \
  || die "Downloaded file is missing the expected installer header"
bash -n "${tmp_file}" || die "Downloaded installer failed shell syntax validation"

if [[ -n "${WEB_AUTH_EXPECTED_SHA256:-}" ]]; then
  actual_sha256="$(sha256sum "${tmp_file}" | awk '{print $1}')"
  expected_sha256="${WEB_AUTH_EXPECTED_SHA256,,}"
  [[ "${actual_sha256}" == "${expected_sha256}" ]] \
    || die "SHA-256 verification failed"
  say "SHA-256 verification passed"
fi

if [[ "${WEB_AUTH_DRY_RUN:-0}" == "1" ]]; then
  say "Dry run complete: downloaded script is valid"
  exit 0
fi

install -d -m 755 "$(dirname "${COMMAND_PATH}")"
install -m 700 "${tmp_file}" "${COMMAND_PATH}"
say "Installed management command: ${COMMAND_PATH}"

if [[ "$#" -eq 0 ]]; then
  set -- --install
fi

say "Starting installation"
bash "${COMMAND_PATH}" "$@"
