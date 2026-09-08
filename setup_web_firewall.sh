#!/usr/bin/env bash
#
# setup_web_firewall.sh - Web authentication firewall for modern Linux
#
# Deploys a Python login service on TCP 18622.  Every source IP may reach
# the login page.  A successful login adds the client IP to an nftables
# whitelist that is allowed to reach every service on the host.  A failed
# login adds the client IP to a blacklist that is denied access to every
# port except the auth port.  The default INPUT policy is DROP.
#
# Usage:
#   sudo ./setup_web_firewall.sh [--port 18622] [--keep-ssh|--no-keep-ssh]
#   sudo ./setup_web_firewall.sh --allow-icmp
#   sudo ./setup_web_firewall.sh --uninstall
#
#
# Version history:
#   1.1.4 (2026-09):
#     - feat: GeoIP city/region names translated to Chinese (major cities worldwide)
#     - feat: restart auth service automatically after GeoIP database update
#   1.1.3 (2026-09):
#     - fix: stream GeoIP download/decompression to avoid OOM kill on low-RAM VPS
#     - feat: GeoIP locations shown in Chinese (continents / countries / CN regions)
#     - feat: menu option 7 shows current login credentials (username / password state)
#
set -Eeuo pipefail

VERSION="1.1.4"

AUTH_USER="admin"
AUTH_PASSWORD='P@ssw0rd'
AUTH_PORT="${AUTH_PORT:-18622}"
AUTH_PATH="/"
NFT_TABLE="web_auth"
SERVICE="web-auth-firewall"
INSTALL_DIR="/opt/web-auth-firewall"
ETC_DIR="/etc/web-auth-firewall"
STATE_DIR="/var/lib/web-auth-firewall"
STATE_FILE="${STATE_DIR}/state.json"
CRED_FILE="${ETC_DIR}/credentials"
NFT_CONF="/etc/nftables.conf"
NFT_BACKUP="${NFT_CONF}.pre-web-auth"
AUTH_PORT_CONFIG="${ETC_DIR}/auth_port"

KEEP_SSH="auto"
ALLOW_ICMP=0
ACTION="menu"
CLI_USER=""
CLI_PASSWORD=""
NFT_BIN="/usr/sbin/nft"
PY_BIN="/usr/bin/python3"
DISTRO_ID=""
DISTRO_LIKE=""
DISTRO_NAME=""
PKG_MGR=""

say()  { printf '\033[1;32m[+] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[!] %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
setup_web_firewall.sh ${VERSION}

Options:
  --install         Install or update the web authentication firewall
  --port N          Auth web port (default: 18622)
  --path PATH       Custom login path, e.g. /sdfcxsd (default: /)
  --random-path     Generate a random login path during install
  --keep-ssh        Whitelist the current SSH client IP during install
  --no-keep-ssh     Do not whitelist the current SSH client IP
  --allow-icmp      Also accept ICMP ping on the host
  --change-credentials
                    Change username/password from the command line
  --username NAME   New username (used with --change-credentials)
  --password PASS   New password (used with --change-credentials)
  --uninstall       Remove the service and restore the previous ruleset
  --menu            Show the interactive management menu (default)
  -h, --help        Show this help

Running the script without options opens an interactive menu with options
to install, view/add/remove whitelist and blacklist IPs, and reset the
login credentials. Credentials can only be changed by root from the
command line; the web interface has no credential management page.
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "This script must be run as root (sudo ./setup_web_firewall.sh)"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port)
        [[ -n "${2:-}" ]] || die "--port requires a value"
        AUTH_PORT="$2"
        shift 2
        ;;
      --port=*)
        AUTH_PORT="${1#*=}"
        shift
        ;;
      --path)
        [[ -n "${2:-}" ]] || die "--path requires a value"
        normalize_auth_path "$2"
        shift 2
        ;;
      --path=*)
        normalize_auth_path "${1#*=}"
        shift
        ;;
      --random-path)
        AUTH_PATH="/$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 12)"
        shift
        ;;
      --update-geoip)
        ACTION="update_geoip"
        shift
        ;;
      --keep-ssh)
        KEEP_SSH=1
        shift
        ;;
      --no-keep-ssh)
        KEEP_SSH=0
        shift
        ;;
      --allow-icmp)
        ALLOW_ICMP=1
        shift
        ;;
      --install)
        ACTION="install"
        shift
        ;;
      --menu)
        ACTION="menu"
        shift
        ;;
      --change-credentials)
        ACTION="change_credentials"
        shift
        ;;
      --username)
        [[ -n "${2:-}" ]] || die "--username requires a value"
        CLI_USER="$2"
        shift 2
        ;;
      --password)
        [[ -n "${2:-}" ]] || die "--password requires a value"
        CLI_PASSWORD="$2"
        shift 2
        ;;
      --uninstall)
        ACTION="uninstall"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: ${1} (see --help)"
        ;;
    esac
  done
}

detect_distro() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_LIKE="${ID_LIKE:-}"
    DISTRO_NAME="${PRETTY_NAME:-${DISTRO_ID}}"
  else
    DISTRO_ID="unknown"
    DISTRO_LIKE=""
    DISTRO_NAME="unknown"
  fi
}

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MGR="zypper"
  elif command -v pacman >/dev/null 2>&1; then
    PKG_MGR="pacman"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
  else
    die "No supported package manager found (apt/dnf/yum/zypper/pacman/apk)."
  fi
  say "Package manager: ${PKG_MGR}"
}

install_packages() {
  local pkgs=()
  case "${PKG_MGR}" in
    apt) pkgs=(nftables python3 curl unzip) ;;
    dnf|yum) pkgs=(nftables python3 curl unzip) ;;
    zypper) pkgs=(nftables python3 curl unzip) ;;
    pacman) pkgs=(nftables python curl unzip) ;;
    apk) pkgs=(nftables python3 curl unzip) ;;
  esac
  say "Installing packages: ${pkgs[*]}"
  case "${PKG_MGR}" in
    apt)
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
      ;;
    dnf)
      dnf install -y "${pkgs[@]}"
      ;;
    yum)
      yum install -y "${pkgs[@]}"
      ;;
    zypper)
      zypper --non-interactive install "${pkgs[@]}"
      ;;
    pacman)
      pacman --noconfirm -S "${pkgs[@]}"
      ;;
    apk)
      apk add "${pkgs[@]}"
      ;;
  esac
}

ensure_tools() {
  command -v systemctl >/dev/null 2>&1 || die "systemd (systemctl) is required; Alpine/OpenRC systems are not supported."
  command -v sha256sum >/dev/null 2>&1 || die "Required command not found: sha256sum"
  command -v awk >/dev/null 2>&1 || die "Required command not found: awk"
  detect_distro
  detect_package_manager
  local need_install=0
  command -v python3 >/dev/null 2>&1 || need_install=1
  command -v nft >/dev/null 2>&1 || need_install=1
  if [[ "${need_install}" -eq 1 ]]; then
    install_packages
  fi
  command -v python3 >/dev/null 2>&1 || die "python3 is still missing after package install."
  command -v nft >/dev/null 2>&1 || die "nft is still missing after package install."
  NFT_BIN="$(command -v nft)"
  PY_BIN="$(command -v python3)"
  say "Detected system: ${DISTRO_NAME} (${PKG_MGR})"
}

backup_existing_ruleset() {
  if [[ -f "${NFT_CONF}" ]] && ! grep -qs "Generated by web-auth-firewall" "${NFT_CONF}"; then
    cp -a "${NFT_CONF}" "${NFT_BACKUP}"
    say "Backed up existing ruleset to ${NFT_BACKUP}"
  fi
}

save_pre_install_state() {
  install -d -m 700 "${ETC_DIR}"
  {
    if systemctl is-enabled --quiet nftables 2>/dev/null; then
      echo "nft_enabled=yes"
    else
      echo "nft_enabled=no"
    fi
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
      echo "ufw_active=yes"
    else
      echo "ufw_active=no"
    fi
    if systemctl is-active --quiet firewalld 2>/dev/null; then
      echo "fw_active=yes"
    else
      echo "fw_active=no"
    fi
  } > "${ETC_DIR}/pre_install_state"
  chmod 600 "${ETC_DIR}/pre_install_state"
}

stop_conflicting_firewalls() {
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    warn "Disabling ufw (web-auth-firewall manages nftables directly)."
    ufw --force disable || true
    systemctl disable --now ufw >/dev/null 2>&1 || true
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    warn "Disabling firewalld (web-auth-firewall manages nftables directly)."
    systemctl disable --now firewalld >/dev/null 2>&1 || true
  fi
}

write_credentials() {
  local pwd_hash
  pwd_hash="$(printf '%s' "${AUTH_PASSWORD}" | sha256sum | cut -d' ' -f1)"
  install -d -m 700 "${ETC_DIR}"
  if [[ -f "${CRED_FILE}" ]] && command -v chattr >/dev/null 2>&1; then
    chattr -i "${CRED_FILE}" 2>/dev/null || true
  fi
  printf '%s\n%s\n' "${AUTH_USER}" "${pwd_hash}" > "${CRED_FILE}"
  chown root:root "${CRED_FILE}"
  chmod 600 "${CRED_FILE}"
  if command -v chattr >/dev/null 2>&1; then
    if chattr +i "${CRED_FILE}" 2>/dev/null; then
      say "Credentials locked: root-only and immutable."
    else
      warn "chattr +i failed; credentials are root-only but not immutable."
    fi
  fi
}

write_auth_server() {
  if [[ -f "${INSTALL_DIR}/auth_server.py" ]] && command -v chattr >/dev/null 2>&1; then
    chattr -i "${INSTALL_DIR}/auth_server.py" 2>/dev/null || true
  fi
  cat > "${INSTALL_DIR}/auth_server.py" <<'PYEOF'
#!/usr/bin/env python3
"""Web authentication firewall service for modern Linux distributions.

Serves a login page on the configured port. Successful logins add the
client IP to an nftables whitelist; failed logins add it to a blacklist.
The service is intentionally limited: it has no admin pages and cannot
change the fixed credentials.
"""
# BEGIN_AUTH_SERVER

import hashlib
import hmac
import ipaddress
import json
import logging
import os
import socket
import subprocess
import threading
import time
from html import escape
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

try:
    import geoip
except ImportError:
    geoip = None

AUTH_PORT_CONFIG = os.environ.get("AUTH_PORT_CONFIG", "/etc/web-auth-firewall/auth_port")
AUTH_PORT = int(os.environ.get("AUTH_PORT", "18622"))
try:
    with open(AUTH_PORT_CONFIG, "r", encoding="ascii") as fh:
        configured_port = fh.read().strip()
    if configured_port:
        AUTH_PORT = int(configured_port)
except (OSError, ValueError):
    pass
NFT_TABLE = os.environ.get("NFT_TABLE", "web_auth")
CRED_FILE = os.environ.get("CRED_FILE", "/etc/web-auth-firewall/credentials")
STATE_FILE = os.environ.get("STATE_FILE", "/var/lib/web-auth-firewall/state.json")
NFT_BASE_CONF = os.environ.get("NFT_BASE_CONF", "/etc/nftables.conf")
BIND_ADDR = os.environ.get("BIND_ADDR", "::")
AUTH_PATH_CONFIG = os.environ.get("AUTH_PATH_CONFIG", "/etc/web-auth-firewall/auth_path")
AUTH_PATH = os.environ.get("AUTH_PATH", "/").strip() or "/"
try:
    with open(AUTH_PATH_CONFIG, "r", encoding="ascii") as fh:
        configured_path = fh.read().strip()
    if configured_path:
        AUTH_PATH = configured_path
except OSError:
    pass
if not AUTH_PATH.startswith("/"):
    AUTH_PATH = "/" + AUTH_PATH
if AUTH_PATH != "/":
    AUTH_PATH = AUTH_PATH.rstrip("/")
LOGIN_ACTION = AUTH_PATH if AUTH_PATH != "/" else "/"
MANAGE_ACTION = AUTH_PATH + "/manage" if AUTH_PATH != "/" else "/manage"
LOGOUT_ACTION = AUTH_PATH + "/logout" if AUTH_PATH != "/" else "/logout"
SCRIPT_VERSION = "1.1.4"

# Immutable defaults. The service refuses to start if the on-disk
# credentials file does not match these exact values.
EXPECTED_USER = "admin"
EXPECTED_PASSWORD_HASH = "b03ddf3ca2e714a6548e7495e2a03f5e824eaac9837cd7f159c67b90fb4b7342"

DEFAULT_TTL_HOURS = 48
MAX_TTL_HOURS = 720
WHITELIST_TTL_HOURS = DEFAULT_TTL_HOURS
BLACKLIST_TTL_HOURS = DEFAULT_TTL_HOURS
WHITELIST_TTL_SECONDS = WHITELIST_TTL_HOURS * 3600
BLACKLIST_TTL_SECONDS = BLACKLIST_TTL_HOURS * 3600
TTL_CONFIG = os.environ.get("TTL_CONFIG", "/var/lib/web-auth-firewall/ttl.json")
try:
    with open(TTL_CONFIG, "r", encoding="utf-8") as fh:
        _ttl_data = json.load(fh)
    WHITELIST_TTL_HOURS = max(1, min(MAX_TTL_HOURS, int(_ttl_data.get("whitelist_hours", WHITELIST_TTL_HOURS))))
    BLACKLIST_TTL_HOURS = max(1, min(MAX_TTL_HOURS, int(_ttl_data.get("blacklist_hours", BLACKLIST_TTL_HOURS))))
    WHITELIST_TTL_SECONDS = WHITELIST_TTL_HOURS * 3600
    BLACKLIST_TTL_SECONDS = BLACKLIST_TTL_HOURS * 3600
except (OSError, ValueError, TypeError):
    pass


def set_global_ttl(whitelist_hours, blacklist_hours):
    global WHITELIST_TTL_SECONDS, BLACKLIST_TTL_SECONDS
    global WHITELIST_TTL_HOURS, BLACKLIST_TTL_HOURS
    WHITELIST_TTL_HOURS = max(1, min(MAX_TTL_HOURS, int(whitelist_hours)))
    BLACKLIST_TTL_HOURS = max(1, min(MAX_TTL_HOURS, int(blacklist_hours)))
    WHITELIST_TTL_SECONDS = WHITELIST_TTL_HOURS * 3600
    BLACKLIST_TTL_SECONDS = BLACKLIST_TTL_HOURS * 3600
    os.makedirs(os.path.dirname(TTL_CONFIG) or ".", exist_ok=True)
    tmp = TTL_CONFIG + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(
            {"whitelist_hours": WHITELIST_TTL_HOURS, "blacklist_hours": BLACKLIST_TTL_HOURS},
            fh,
            indent=2,
            sort_keys=True,
        )
        fh.write("\n")
    os.replace(tmp, TTL_CONFIG)
    with STATE_LOCK:
        now = time.time()
        whitelist_refreshed = 0
        blacklist_refreshed = 0
        for family in FAMILIES:
            for ip, expires in list(STATE["whitelist"][family].items()):
                if expires > now:
                    STATE["whitelist"][family][ip] = now + WHITELIST_TTL_SECONDS
                    whitelist_refreshed += 1
            for ip, expires in list(STATE["blacklist"][family].items()):
                if expires > now:
                    STATE["blacklist"][family][ip] = now + BLACKLIST_TTL_SECONDS
                    blacklist_refreshed += 1
        save_state(STATE)
    LOG.info(
        "global TTL updated: whitelist %dh (%d refreshed), blacklist %dh (%d refreshed)",
        WHITELIST_TTL_HOURS, whitelist_refreshed, BLACKLIST_TTL_HOURS, blacklist_refreshed,
    )

# A client is blacklisted after 3 failed logins within 5 minutes.
FAIL_WINDOW_SECONDS = 5 * 60
MAX_FAILED_ATTEMPTS = 3
FAILED_ATTEMPTS = {}
FAIL_LOCK = threading.RLock()
RECONCILE_INTERVAL_SECONDS = int(os.environ.get("RECONCILE_INTERVAL_SECONDS", "300"))
MAX_CONCURRENT_REQUESTS = int(os.environ.get("MAX_CONCURRENT_REQUESTS", "16"))
_REQUEST_SEMAPHORE = threading.BoundedSemaphore(MAX_CONCURRENT_REQUESTS)
_PORT_CACHE = {"ts": 0.0, "tcp": [], "udp": []}

WHITELIST_SETS = {"4": "whitelist_v4", "6": "whitelist_v6"}
BLACKLIST_SETS = {"4": "blacklist_v4", "6": "blacklist_v6"}
SET_KINDS = ("whitelist", "blacklist")
FAMILIES = ("4", "6")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
LOG = logging.getLogger("web-auth-firewall")
STATE_LOCK = threading.RLock()


def empty_state():
    return {"whitelist": {"4": {}, "6": {}}, "blacklist": {"4": {}, "6": {}}}


STATE = empty_state()


def password_hash(password):
    return hashlib.sha256(password.encode("utf-8")).hexdigest()


def verify_credentials_file():
    try:
        with open(CRED_FILE, "r", encoding="ascii") as fh:
            lines = [line.strip() for line in fh if line.strip()]
    except OSError as exc:
        LOG.error("cannot read credentials file %s: %s", CRED_FILE, exc)
        return False
    if len(lines) != 2:
        LOG.error("credentials file must contain exactly username and password hash")
        return False
    user_ok = hmac.compare_digest(lines[0].encode("ascii"), EXPECTED_USER.encode("ascii"))
    pwd_ok = hmac.compare_digest(lines[1].encode("ascii"), EXPECTED_PASSWORD_HASH.encode("ascii"))
    if not (user_ok and pwd_ok):
        LOG.error("credentials file does not match the immutable defaults")
        return False
    return True


def check_login(username, password):
    user_ok = hmac.compare_digest(username.encode("utf-8"), EXPECTED_USER.encode("utf-8"))
    pwd_ok = hmac.compare_digest(
        password_hash(password).encode("ascii"),
        EXPECTED_PASSWORD_HASH.encode("ascii"),
    )
    return user_ok and pwd_ok


def record_failed_attempt(ip, family):
    with FAIL_LOCK:
        now = time.time()
        cutoff = now - FAIL_WINDOW_SECONDS
        timestamps = [ts for ts in FAILED_ATTEMPTS.get(ip, []) if ts > cutoff]
        timestamps.append(now)
        FAILED_ATTEMPTS[ip] = timestamps
        if len(timestamps) >= MAX_FAILED_ATTEMPTS:
            FAILED_ATTEMPTS.pop(ip, None)
            revoke_access(ip, family)
            return True, 0
        return False, MAX_FAILED_ATTEMPTS - len(timestamps)


def clear_failed_attempts(ip):
    with FAIL_LOCK:
        FAILED_ATTEMPTS.pop(ip, None)


def nft_ok(*args):
    return subprocess.run(
        ["nft", *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    ).returncode == 0


def ensure_table():
    probe = subprocess.run(
        ["nft", "list", "table", "inet", NFT_TABLE],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if probe.returncode != 0:
        LOG.warning("nftables table missing; loading %s", NFT_BASE_CONF)
        subprocess.run(["nft", "-f", NFT_BASE_CONF], check=True)


def set_name(kind, family):
    sets = WHITELIST_SETS if kind == "whitelist" else BLACKLIST_SETS
    return sets[family]


def normalize_ip(raw):
    try:
        addr = ipaddress.ip_address(raw.strip())
    except ValueError:
        return None, None
    if isinstance(addr, ipaddress.IPv6Address) and addr.ipv4_mapped is not None:
        addr = addr.ipv4_mapped
    if isinstance(addr, ipaddress.IPv4Address):
        return addr.compressed, "4"
    return addr.compressed, "6"


def load_state():
    state = empty_state()
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return state
    except (OSError, ValueError) as exc:
        LOG.error("cannot read state file %s: %s", STATE_FILE, exc)
        return state
    now = time.time()
    for kind in SET_KINDS:
        by_family = data.get(kind)
        if not isinstance(by_family, dict):
            continue
        for family in FAMILIES:
            raw = by_family.get(family)
            ttl = WHITELIST_TTL_SECONDS if kind == "whitelist" else BLACKLIST_TTL_SECONDS
            target = {}
            if isinstance(raw, list):
                # Migrate old list format: treat existing entries as fresh.
                for item in raw:
                    if isinstance(item, str) and item.strip():
                        target[item.strip()] = now + ttl
            elif isinstance(raw, dict):
                for item, expiry in raw.items():
                    if not isinstance(item, str) or not item.strip():
                        continue
                    try:
                        expires = float(expiry)
                    except (TypeError, ValueError):
                        expires = now + ttl
                    target[item.strip()] = expires
            state[kind][family] = target
    return state


def save_state(state):
    os.makedirs(os.path.dirname(STATE_FILE) or ".", exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(state, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, STATE_FILE)
    try:
        os.chmod(STATE_FILE, 0o600)
    except OSError:
        pass


def count_state(kind):
    return len(STATE[kind]["4"]) + len(STATE[kind]["6"])


def reconcile():
    with STATE_LOCK:
        ensure_table()
        expire_whitelist()
        expire_blacklist()
        for kind in SET_KINDS:
            for family in FAMILIES:
                setname = set_name(kind, family)
                if not nft_ok("flush", "set", "inet", NFT_TABLE, setname):
                    LOG.error("failed to flush set %s", setname)
                    continue
                for ip in STATE[kind][family]:
                    nft_ok("add", "element", "inet", NFT_TABLE, setname, "{", ip, "}")
        LOG.info(
            "reconciled state: %d whitelist, %d blacklist",
            count_state("whitelist"),
            count_state("blacklist"),
        )


def grant_access(ip, family, ttl_seconds=None):
    with STATE_LOCK:
        if ip in STATE["blacklist"][family]:
            del STATE["blacklist"][family][ip]
            nft_ok("delete", "element", "inet", NFT_TABLE, set_name("blacklist", family), "{", ip, "}")
        ttl = ttl_seconds if ttl_seconds else WHITELIST_TTL_SECONDS
        STATE["whitelist"][family][ip] = time.time() + ttl
        nft_ok("add", "element", "inet", NFT_TABLE, set_name("whitelist", family), "{", ip, "}")
        save_state(STATE)
        LOG.info(
            "granted access to %s (family %s) for %d seconds",
            ip, family, ttl,
        )


def revoke_access(ip, family, ttl_seconds=None):
    with STATE_LOCK:
        if ip in STATE["whitelist"][family]:
            del STATE["whitelist"][family][ip]
            nft_ok("delete", "element", "inet", NFT_TABLE, set_name("whitelist", family), "{", ip, "}")
        ttl = ttl_seconds if ttl_seconds else BLACKLIST_TTL_SECONDS
        STATE["blacklist"][family][ip] = time.time() + ttl
        nft_ok("add", "element", "inet", NFT_TABLE, set_name("blacklist", family), "{", ip, "}")
        save_state(STATE)
        LOG.warning(
            "revoked access from %s (family %s) for %d seconds",
            ip, family, ttl,
        )


def expire_list(kind):
    with STATE_LOCK:
        now = time.time()
        removed = []
        for family in FAMILIES:
            expired = [
                ip for ip, expires in STATE[kind][family].items()
                if expires <= now
            ]
            for ip in expired:
                nft_ok("delete", "element", "inet", NFT_TABLE, set_name(kind, family), "{", ip, "}")
                del STATE[kind][family][ip]
                removed.append(ip)
        if removed:
            save_state(STATE)
            LOG.info("expired %d %s IP(s): %s", len(removed), kind, ", ".join(removed))
    return removed


def expire_whitelist():
    return expire_list("whitelist")


def expire_blacklist():
    return expire_list("blacklist")


def remove_from_whitelist(ip, family):
    with STATE_LOCK:
        if ip in STATE["whitelist"][family]:
            del STATE["whitelist"][family][ip]
            nft_ok("delete", "element", "inet", NFT_TABLE, set_name("whitelist", family), "{", ip, "}")
            save_state(STATE)
            LOG.info("removed %s from whitelist (family %s)", ip, family)
            return True
    return False


def remove_from_blacklist(ip, family):
    with STATE_LOCK:
        if ip in STATE["blacklist"][family]:
            del STATE["blacklist"][family][ip]
            nft_ok("delete", "element", "inet", NFT_TABLE, set_name("blacklist", family), "{", ip, "}")
            save_state(STATE)
            LOG.info("removed %s from blacklist (family %s)", ip, family)
            return True
    return False


def _proc_ports(path, tcp):
    result = []
    try:
        with open(path, "r", encoding="ascii") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return result
    for line in lines[1:]:
        fields = line.split()
        if len(fields) < 4:
            continue
        if tcp and fields[3] != "0A":
            continue
        local = fields[1]
        if ":" not in local:
            continue
        port_hex = local.rsplit(":", 1)[1]
        try:
            port = int(port_hex, 16)
        except ValueError:
            continue
        if port != 0:
            result.append(port)
    return result


def collect_tcp_ports():
    ports = set()
    for path in ("/proc/net/tcp", "/proc/net/tcp6"):
        ports.update(_proc_ports(path, tcp=True))
    return sorted(ports)


def collect_udp_ports():
    ports = set()
    for path in ("/proc/net/udp", "/proc/net/udp6"):
        ports.update(_proc_ports(path, tcp=False))
    return sorted(ports)


def collect_open_ports_cached():
    now = time.time()
    if now - _PORT_CACHE["ts"] < 10:
        return _PORT_CACHE["tcp"], _PORT_CACHE["udp"]
    tcp_ports = collect_tcp_ports()
    udp_ports = collect_udp_ports()
    _PORT_CACHE["tcp"] = tcp_ports
    _PORT_CACHE["udp"] = udp_ports
    _PORT_CACHE["ts"] = now
    return tcp_ports, udp_ports


def port_badges(ports):
    if not ports:
        return '<span class="port">无</span>'
    return "".join('<span class="port">%d</span>' % port for port in ports)


COUNTRY_NAMES = {
    "CN": "中国", "US": "美国", "JP": "日本", "KR": "韩国", "SG": "新加坡",
    "HK": "中国香港", "TW": "中国台湾", "MO": "中国澳门", "GB": "英国", "DE": "德国",
    "FR": "法国", "RU": "俄罗斯", "CA": "加拿大", "AU": "澳大利亚", "IN": "印度",
    "NL": "荷兰", "SE": "瑞典", "CH": "瑞士", "IT": "意大利", "ES": "西班牙",
    "BR": "巴西", "MX": "墨西哥", "ZA": "南非", "EG": "埃及", "TR": "土耳其",
    "AE": "阿联酋", "SA": "沙特阿拉伯", "ID": "印度尼西亚", "TH": "泰国", "VN": "越南",
    "PH": "菲律宾", "MY": "马来西亚", "PK": "巴基斯坦", "BD": "孟加拉国", "UA": "乌克兰",
    "PL": "波兰", "CZ": "捷克", "AT": "奥地利", "BE": "比利时", "DK": "丹麦",
    "FI": "芬兰", "NO": "挪威", "IE": "爱尔兰", "NZ": "新西兰", "AR": "阿根廷",
    "CL": "智利", "CO": "哥伦比亚", "PE": "秘鲁", "RO": "罗马尼亚", "GR": "希腊",
}


CONTINENT_NAMES = {
    "AF": "非洲",
    "AS": "亚洲",
    "EU": "欧洲",
    "NA": "北美洲",
    "OC": "大洋洲",
    "SA": "南美洲",
    "AN": "南极洲",
}


CN_REGION_NAMES = {
    "Anhui": "安徽", "Beijing": "北京", "Chongqing": "重庆", "Fujian": "福建",
    "Gansu": "甘肃", "Guangdong": "广东", "Guangxi": "广西", "Guizhou": "贵州",
    "Hainan": "海南", "Hebei": "河北", "Heilongjiang": "黑龙江", "Henan": "河南",
    "Hubei": "湖北", "Hunan": "湖南", "Inner Mongolia": "内蒙古", "Nei Mongol": "内蒙古",
    "Jiangsu": "江苏", "Jiangxi": "江西", "Jilin": "吉林", "Liaoning": "辽宁",
    "Ningxia": "宁夏", "Qinghai": "青海", "Shaanxi": "陕西", "Shandong": "山东",
    "Shanghai": "上海", "Shanxi": "山西", "Sichuan": "四川", "Tianjin": "天津",
    "Tibet": "西藏", "Xizang": "西藏", "Xinjiang": "新疆", "Yunnan": "云南",
    "Zhejiang": "浙江", "Hong Kong": "香港", "Macau": "澳门", "Macao": "澳门",
    "Taiwan": "台湾",
}


CITY_NAMES = {
    # 中国主要城市
    "Beijing": "北京", "Shanghai": "上海", "Tianjin": "天津", "Chongqing": "重庆",
    "Guangzhou": "广州", "Shenzhen": "深圳", "Chengdu": "成都", "Hangzhou": "杭州",
    "Wuhan": "武汉", "Nanjing": "南京", "Xi'an": "西安", "Zhengzhou": "郑州",
    "Changsha": "长沙", "Shenyang": "沈阳", "Harbin": "哈尔滨", "Changchun": "长春",
    "Jinan": "济南", "Qingdao": "青岛", "Dalian": "大连", "Xiamen": "厦门",
    "Fuzhou": "福州", "Hefei": "合肥", "Nanchang": "南昌", "Kunming": "昆明",
    "Guiyang": "贵阳", "Nanning": "南宁", "Haikou": "海口", "Sanya": "三亚",
    "Lanzhou": "兰州", "Xining": "西宁", "Yinchuan": "银川", "Urumqi": "乌鲁木齐",
    "Hohhot": "呼和浩特", "Taiyuan": "太原", "Shijiazhuang": "石家庄",
    "Suzhou": "苏州", "Wuxi": "无锡", "Ningbo": "宁波", "Wenzhou": "温州",
    "Dongguan": "东莞", "Foshan": "佛山", "Zhuhai": "珠海", "Zhongshan": "中山",
    "Huizhou": "惠州", "Luoyang": "洛阳", "Guilin": "桂林", "Liuzhou": "柳州",
    "Quanzhou": "泉州", "Zhangzhou": "漳州", "Jinhua": "金华", "Shaoxing": "绍兴",
    "Jiaxing": "嘉兴", "Taizhou": "台州", "Yangzhou": "扬州", "Xuzhou": "徐州",
    "Changzhou": "常州", "Nantong": "南通", "Yantai": "烟台", "Weifang": "潍坊",
    "Tangshan": "唐山", "Baoding": "保定", "Langfang": "廊坊", "Cangzhou": "沧州",
    "Handan": "邯郸", "Xiangyang": "襄阳", "Yichang": "宜昌", "Jingzhou": "荆州",
    "Zhuzhou": "株洲", "Xiangtan": "湘潭", "Hengyang": "衡阳", "Mianyang": "绵阳",
    "Luzhou": "泸州", "Deyang": "德阳", "Zunyi": "遵义", "Liupanshui": "六盘水",
    "Baotou": "包头", "Ordos": "鄂尔多斯", "Hulunbuir": "呼伦贝尔",
    "Lhasa": "拉萨", "Kashgar": "喀什", "Ili": "伊犁", "Karamay": "克拉玛依",
    "Hong Kong": "香港", "Macau": "澳门", "Macao": "澳门", "Taipei": "台北",
    "Kaohsiung": "高雄", "Taichung": "台中", "Tainan": "台南", "Hsinchu": "新竹",
    "Taoyuan": "桃园", "Keelung": "基隆",
    # 亚洲主要城市
    "Tokyo": "东京", "Osaka": "大阪", "Yokohama": "横滨", "Nagoya": "名古屋",
    "Sapporo": "札幌", "Fukuoka": "福冈", "Kyoto": "京都", "Kobe": "神户",
    "Kawasaki": "川崎", "Saitama": "埼玉", "Hiroshima": "广岛", "Sendai": "仙台",
    "Seoul": "首尔", "Busan": "釜山", "Incheon": "仁川", "Daegu": "大邱",
    "Daejeon": "大田", "Gwangju": "光州", "Suwon": "水原", "Ulsan": "蔚山",
    "Singapore": "新加坡", "Kuala Lumpur": "吉隆坡", "Penang": "槟城",
    "George Town": "乔治市", "Johor Bahru": "新山", "Ipoh": "怡保",
    "Bangkok": "曼谷", "Chiang Mai": "清迈", "Phuket": "普吉", "Pattaya": "芭堤雅",
    "Manila": "马尼拉", "Cebu": "宿务", "Davao": "达沃", "Quezon City": "奎松市",
    "Jakarta": "雅加达", "Surabaya": "泗水", "Bandung": "万隆", "Medan": "棉兰",
    "Denpasar": "登巴萨", "Bali": "巴厘岛", "Yogyakarta": "日惹",
    "Hanoi": "河内", "Ho Chi Minh City": "胡志明市", "Da Nang": "岘港",
    "Can Tho": "芹苴", "Phnom Penh": "金边", "Vientiane": "万象",
    "Yangon": "仰光", "Mandalay": "曼德勒", "Dhaka": "达卡", "Chittagong": "吉大港",
    "Colombo": "科伦坡", "Kathmandu": "加德满都", "Thimphu": "廷布",
    "New Delhi": "新德里", "Mumbai": "孟买", "Bengaluru": "班加罗尔",
    "Bangalore": "班加罗尔", "Chennai": "金奈", "Kolkata": "加尔各答",
    "Hyderabad": "海得拉巴", "Pune": "浦那", "Ahmedabad": "艾哈迈达巴德",
    "Karachi": "卡拉奇", "Lahore": "拉合尔", "Islamabad": "伊斯兰堡",
    "Dubai": "迪拜", "Abu Dhabi": "阿布扎比", "Sharjah": "沙迦", "Doha": "多哈",
    "Riyadh": "利雅得", "Jeddah": "吉达", "Mecca": "麦加", "Medina": "麦地那",
    "Kuwait City": "科威特城", "Muscat": "马斯喀特", "Manama": "麦纳麦",
    "Tel Aviv": "特拉维夫", "Jerusalem": "耶路撒冷", "Amman": "安曼", "Beirut": "贝鲁特",
    "Baghdad": "巴格达", "Tehran": "德黑兰", "Mashhad": "马什哈德",
    "Istanbul": "伊斯坦布尔", "Ankara": "安卡拉", "Izmir": "伊兹密尔",
    "Antalya": "安塔利亚", "Bursa": "布尔萨", "Tashkent": "塔什干",
    "Almaty": "阿拉木图", "Astana": "阿斯塔纳", "Nur-Sultan": "努尔苏丹",
    "Bishkek": "比什凯克", "Dushanbe": "杜尚别", "Ashgabat": "阿什哈巴德",
    "Baku": "巴库", "Tbilisi": "第比利斯", "Yerevan": "埃里温",
    # 欧洲主要城市
    "London": "伦敦", "Manchester": "曼彻斯特", "Birmingham": "伯明翰",
    "Glasgow": "格拉斯哥", "Edinburgh": "爱丁堡", "Liverpool": "利物浦",
    "Leeds": "利兹", "Bristol": "布里斯托尔", "Sheffield": "谢菲尔德",
    "Newcastle": "纽卡斯尔", "Nottingham": "诺丁汉", "Cardiff": "加的夫",
    "Belfast": "贝尔法斯特", "Dublin": "都柏林", "Cork": "科克",
    "Paris": "巴黎", "Marseille": "马赛", "Lyon": "里昂", "Nice": "尼斯",
    "Toulouse": "图卢兹", "Bordeaux": "波尔多", "Lille": "里尔", "Strasbourg": "斯特拉斯堡",
    "Nantes": "南特", "Montpellier": "蒙彼利埃", "Rennes": "雷恩",
    "Berlin": "柏林", "Munich": "慕尼黑", "Hamburg": "汉堡", "Frankfurt": "法兰克福",
    "Cologne": "科隆", "Stuttgart": "斯图加特", "Dusseldorf": "杜塞尔多夫",
    "Dresden": "德累斯顿", "Leipzig": "莱比锡", "Nuremberg": "纽伦堡",
    "Dortmund": "多特蒙德", "Essen": "埃森", "Bremen": "不来梅", "Hannover": "汉诺威",
    "Amsterdam": "阿姆斯特丹", "Rotterdam": "鹿特丹", "The Hague": "海牙",
    "Utrecht": "乌得勒支", "Eindhoven": "埃因霍温", "Brussels": "布鲁塞尔",
    "Antwerp": "安特卫普", "Ghent": "根特", "Charleroi": "沙勒罗瓦",
    "Vienna": "维也纳", "Graz": "格拉茨", "Linz": "林茨", "Salzburg": "萨尔茨堡",
    "Zurich": "苏黎世", "Geneva": "日内瓦", "Basel": "巴塞尔", "Bern": "伯尔尼",
    "Lausanne": "洛桑", "Lucerne": "卢塞恩", "Rome": "罗马", "Milan": "米兰",
    "Naples": "那不勒斯", "Turin": "都灵", "Venice": "威尼斯", "Florence": "佛罗伦萨",
    "Bologna": "博洛尼亚", "Genoa": "热那亚", "Palermo": "巴勒莫", "Catania": "卡塔尼亚",
    "Bari": "巴里", "Verona": "维罗纳", "Madrid": "马德里", "Barcelona": "巴塞罗那",
    "Valencia": "巴伦西亚", "Seville": "塞维利亚", "Zaragoza": "萨拉戈萨",
    "Malaga": "马拉加", "Bilbao": "毕尔巴鄂", "Alicante": "阿利坎特",
    "Palma": "帕尔马", "Lisbon": "里斯本", "Porto": "波尔图", "Braga": "布拉加",
    "Athens": "雅典", "Thessaloniki": "塞萨洛尼基", "Patras": "帕特雷",
    "Stockholm": "斯德哥尔摩", "Gothenburg": "哥德堡", "Malmo": "马尔默",
    "Uppsala": "乌普萨拉", "Oslo": "奥斯陆", "Bergen": "卑尔根", "Trondheim": "特隆赫姆",
    "Stavanger": "斯塔万格", "Copenhagen": "哥本哈根", "Aarhus": "奥胡斯",
    "Odense": "欧登塞", "Helsinki": "赫尔辛基", "Espoo": "埃斯波", "Tampere": "坦佩雷",
    "Turku": "图尔库", "Oulu": "奥卢", "Reykjavik": "雷克雅未克",
    "Warsaw": "华沙", "Krakow": "克拉科夫", "Wroclaw": "弗罗茨瓦夫",
    "Gdansk": "格但斯克", "Poznan": "波兹南", "Lodz": "罗兹", "Szczecin": "什切青",
    "Prague": "布拉格", "Brno": "布尔诺", "Ostrava": "俄斯特拉发", "Plzen": "比尔森",
    "Budapest": "布达佩斯", "Debrecen": "德布勒森", "Szeged": "塞格德",
    "Bucharest": "布加勒斯特", "Cluj-Napoca": "克卢日-纳波卡", "Cluj": "克卢日",
    "Timisoara": "蒂米什瓦拉", "Iasi": "雅西", "Constanta": "康斯坦察",
    "Sofia": "索非亚", "Plovdiv": "普罗夫迪夫", "Varna": "瓦尔纳", "Burgas": "布尔加斯",
    "Belgrade": "贝尔格莱德", "Novi Sad": "诺维萨德", "Nis": "尼什",
    "Zagreb": "萨格勒布", "Split": "斯普利特", "Rijeka": "里耶卡",
    "Ljubljana": "卢布尔雅那", "Maribor": "马里博尔", "Sarajevo": "萨拉热窝",
    "Skopje": "斯科普里", "Tirana": "地拉那", "Podgorica": "波德戈里察",
    "Bratislava": "布拉迪斯拉发", "Kosice": "科希策", "Kyiv": "基辅",
    "Kiev": "基辅", "Kharkiv": "哈尔科夫", "Odesa": "敖德萨", "Odessa": "敖德萨",
    "Lviv": "利沃夫", "Dnipro": "第聂伯罗", "Donetsk": "顿涅茨克",
    "Minsk": "明斯克", "Gomel": "戈梅利", "Vilnius": "维尔纽斯", "Kaunas": "考纳斯",
    "Klaipeda": "克莱佩达", "Riga": "里加", "Tallinn": "塔林", "Tartu": "塔尔图",
    "Moscow": "莫斯科", "Saint Petersburg": "圣彼得堡", "St Petersburg": "圣彼得堡",
    "Novosibirsk": "新西伯利亚", "Yekaterinburg": "叶卡捷琳堡", "Kazan": "喀山",
    "Nizhny Novgorod": "下诺夫哥罗德", "Samara": "萨马拉", "Omsk": "鄂木斯克",
    "Chelyabinsk": "车里雅宾斯克", "Rostov-on-Don": "顿河畔罗斯托夫",
    "Ufa": "乌法", "Krasnodar": "克拉斯诺达尔", "Perm": "彼尔姆",
    "Voronezh": "沃罗涅日", "Volgograd": "伏尔加格勒",
    # 北美洲主要城市
    "New York": "纽约", "Los Angeles": "洛杉矶", "Chicago": "芝加哥",
    "Houston": "休斯顿", "Phoenix": "凤凰城", "Philadelphia": "费城",
    "San Antonio": "圣安东尼奥", "San Diego": "圣迭戈", "Dallas": "达拉斯",
    "San Jose": "圣何塞", "Austin": "奥斯汀", "Jacksonville": "杰克逊维尔",
    "Fort Worth": "沃斯堡", "Columbus": "哥伦布", "Charlotte": "夏洛特",
    "San Francisco": "旧金山", "Indianapolis": "印第安纳波利斯", "Seattle": "西雅图",
    "Denver": "丹佛", "Washington": "华盛顿", "Boston": "波士顿",
    "El Paso": "埃尔帕索", "Nashville": "纳什维尔", "Detroit": "底特律",
    "Portland": "波特兰", "Las Vegas": "拉斯维加斯", "Memphis": "孟菲斯",
    "Louisville": "路易斯维尔", "Baltimore": "巴尔的摩", "Milwaukee": "密尔沃基",
    "Albuquerque": "阿尔伯克基", "Tucson": "图森", "Miami": "迈阿密",
    "Sacramento": "萨克拉门托", "Atlanta": "亚特兰大", "Kansas City": "堪萨斯城",
    "Omaha": "奥马哈", "Raleigh": "罗利", "Oakland": "奥克兰",
    "Minneapolis": "明尼阿波利斯", "Tampa": "坦帕", "Pittsburgh": "匹兹堡",
    "Cincinnati": "辛辛那提", "Cleveland": "克利夫兰", "St Louis": "圣路易斯",
    "Orlando": "奥兰多", "New Orleans": "新奥尔良", "Salt Lake City": "盐湖城",
    "Toronto": "多伦多", "Montreal": "蒙特利尔", "Vancouver": "温哥华",
    "Calgary": "卡尔加里", "Edmonton": "埃德蒙顿", "Ottawa": "渥太华",
    "Winnipeg": "温尼伯", "Quebec City": "魁北克市", "Halifax": "哈利法克斯",
    "Hamilton": "哈密尔顿", "Kitchener": "基奇纳", "London (Ontario)": "伦敦（安大略）",
    "Mexico City": "墨西哥城", "Guadalajara": "瓜达拉哈拉", "Monterrey": "蒙特雷",
    "Cancun": "坎昆", "Tijuana": "蒂华纳", "Puebla": "普埃布拉",
    "Havana": "哈瓦那", "Santo Domingo": "圣多明各", "San Juan": "圣胡安",
    "Kingston": "金斯敦", "Port-au-Prince": "太子港", "Panama City": "巴拿马城",
    "San Jose (Costa Rica)": "圣何塞", "Guatemala City": "危地马拉城",
    "Tegucigalpa": "特古西加尔巴", "Managua": "马那瓜", "San Salvador": "圣萨尔瓦多",
    # 南美洲主要城市
    "Sao Paulo": "圣保罗", "Rio de Janeiro": "里约热内卢", "Brasilia": "巴西利亚",
    "Salvador": "萨尔瓦多", "Fortaleza": "福塔莱萨", "Belo Horizonte": "贝洛奥里藏特",
    "Recife": "累西腓", "Porto Alegre": "阿雷格里港", "Curitiba": "库里蒂巴",
    "Manaus": "马瑙斯", "Buenos Aires": "布宜诺斯艾利斯", "Cordoba": "科尔多瓦",
    "Rosario": "罗萨里奥", "Mendoza": "门多萨", "La Plata": "拉普拉塔",
    "Santiago": "圣地亚哥", "Valparaiso": "瓦尔帕莱索", "Concepcion": "康塞普西翁",
    "Lima": "利马", "Arequipa": "阿雷基帕", "Cusco": "库斯科",
    "Bogota": "波哥大", "Medellin": "麦德林", "Cali": "卡利", "Barranquilla": "巴兰基亚",
    "Cartagena": "卡塔赫纳", "Caracas": "加拉加斯", "Maracaibo": "马拉开波",
    "Quito": "基多", "Guayaquil": "瓜亚基尔", "Montevideo": "蒙得维的亚",
    "Asuncion": "亚松森", "La Paz": "拉巴斯", "Santa Cruz": "圣克鲁斯",
    "Georgetown": "乔治敦", "Paramaribo": "帕拉马里博", "Cayenne": "卡宴",
    # 大洋洲主要城市
    "Sydney": "悉尼", "Melbourne": "墨尔本", "Brisbane": "布里斯班",
    "Perth": "珀斯", "Adelaide": "阿德莱德", "Canberra": "堪培拉",
    "Gold Coast": "黄金海岸", "Hobart": "霍巴特", "Darwin": "达尔文",
    "Wollongong": "伍伦贡", "Geelong": "吉朗", "Auckland": "奥克兰",
    "Wellington": "惠灵顿", "Christchurch": "克赖斯特彻奇", "Tauranga": "陶朗加",
    "Dunedin": "达尼丁", "Suva": "苏瓦", "Port Moresby": "莫尔兹比港",
    "Noumea": "努美阿", "Papeete": "帕皮提",
    # 非洲主要城市
    "Johannesburg": "约翰内斯堡", "Cape Town": "开普敦", "Durban": "德班",
    "Pretoria": "比勒陀利亚", "East London": "东伦敦", "Bloemfontein": "布隆方丹",
    "Nairobi": "内罗毕", "Mombasa": "蒙巴萨", "Kisumu": "基苏木",
    "Lagos": "拉各斯", "Abuja": "阿布贾", "Ibadan": "伊巴丹", "Kano": "卡诺",
    "Accra": "阿克拉", "Kumasi": "库马西", "Cairo": "开罗", "Alexandria": "亚历山大",
    "Giza": "吉萨", "Casablanca": "卡萨布兰卡", "Rabat": "拉巴特",
    "Marrakesh": "马拉喀什", "Fes": "非斯", "Tangier": "丹吉尔",
    "Tunis": "突尼斯市", "Algiers": "阿尔及尔", "Oran": "奥兰",
    "Tripoli": "的黎波里", "Khartoum": "喀土穆", "Addis Ababa": "亚的斯亚贝巴",
    "Dar es Salaam": "达累斯萨拉姆", "Dodoma": "多多马", "Kampala": "坎帕拉",
    "Lusaka": "卢萨卡", "Harare": "哈拉雷", "Maputo": "马普托", "Luanda": "罗安达",
    "Kinshasa": "金沙萨", "Douala": "杜阿拉", "Yaounde": "雅温得",
    "Abidjan": "阿比让", "Dakar": "达喀尔", "Bamako": "巴马科",
    "Ouagadougou": "瓦加杜古", "Antananarivo": "塔那那利佛", "Mauritius": "毛里求斯",
}


def _translate_geo_label(raw):
    """Translate stored GeoIP labels into Chinese for display.

    Handles the formats produced by the bundled builders:
      * "CN"              (v2ray .dat source: plain country code)
      * "AS · CN, Yunnan" (db-ip CSV source: continent · code, region)
    """
    if not raw:
        return raw
    raw = raw.strip()

    def _tr(token):
        token = token.strip()
        if token in COUNTRY_NAMES:
            return COUNTRY_NAMES[token]
        if token in CONTINENT_NAMES:
            return CONTINENT_NAMES[token]
        if token in CN_REGION_NAMES:
            return CN_REGION_NAMES[token]
        if token in CITY_NAMES:
            return CITY_NAMES[token]
        return token

    if "·" in raw:
        head, _, tail = raw.partition("·")
        head = _tr(head)
        tail = ", ".join(t for t in (_tr(x) for x in tail.split(",")) if t)
        if head and tail:
            return head + " · " + tail
        return head or tail
    return _tr(raw)


def geo_label(ip):
    if geoip is None or not geoip.is_available():
        return '<span class="geo unknown">未知</span>'
    info = geoip.country(ip)
    if not info:
        return '<span class="geo unknown">未知</span>'
    label = _translate_geo_label(info)
    return '<span class="geo">%s</span>' % escape(label)


def render_list_rows(kind):
    rows = []
    action = "remove_whitelist" if kind == "whitelist" else "remove_blacklist"
    now = time.time()
    for family in FAMILIES:
        family_label = "IPv4" if family == "4" else "IPv6"
        for ip, expires in STATE[kind][family].items():
            safe_ip = escape(ip)
            remaining = int((expires - now) / 3600 + 0.5)
            expiry_label = "<1h" if remaining < 1 else "剩余%dh" % remaining
            rows.append(
                '<div class="iprow">'
                '<span class="ipaddr">%s</span>'
                '<span class="family">%s</span>'
                '<span class="expiry">%s</span>'
                '%s'
                '<form method="post" action="%s">'
                '<input type="hidden" name="action" value="%s">'
                '<input type="hidden" name="ip" value="%s">'
                '<button type="submit" class="small danger">删除</button>'
                "</form>"
                "</div>" % (safe_ip, family_label, expiry_label, geo_label(ip), MANAGE_ACTION, action, safe_ip)
            )
    if not rows:
        return '<div class="empty">无</div>'
    return "".join(rows)


def render_success_page(client_ip, message=""):
    tcp_ports, udp_ports = collect_open_ports_cached()
    msg_html = ""
    if message:
        msg_html = '<div class="msg">%s</div>' % escape(message)
    geo_notice = ""
    if geoip is None or not geoip.is_available():
        geo_notice = '<div class="msg">未安装 GeoIP 数据库，请在后台菜单选择“更新 GeoIP 数据库”。</div>'
    return (
        SUCCESS_PAGE
        .replace("__CLIENT_IP__", escape(client_ip))
        .replace("__CLIENT_GEO__", geo_label(client_ip))
        .replace("__TCP_PORTS__", port_badges(tcp_ports))
        .replace("__UDP_PORTS__", port_badges(udp_ports))
        .replace("__WHITELIST_ROWS__", render_list_rows("whitelist"))
        .replace("__BLACKLIST_ROWS__", render_list_rows("blacklist"))
        .replace("__WHITELIST_TTL__", str(WHITELIST_TTL_HOURS))
        .replace("__BLACKLIST_TTL__", str(BLACKLIST_TTL_HOURS))
        .replace("__MANAGE_MESSAGE__", msg_html)
        .replace("__GEOIP_NOTICE__", geo_notice)
        .replace("__MANAGE_ACTION__", MANAGE_ACTION)
        .replace("__LOGOUT_ACTION__", LOGOUT_ACTION)
        .replace("__VERSION__", SCRIPT_VERSION)
    )


def render_failure_page(message):
    return FAILURE_PAGE.replace("__FAIL_MESSAGE__", escape(message))


def render_login_page(logout=False):
    notice = ""
    if logout:
        notice = '<div class="notice">您已退出登录，IP 仍保留在白名单中，可重新登录其它账号。</div>'
    return (
        LOGIN_PAGE
        .replace("__LOGIN_NOTICE__", notice)
        .replace("__AUTH_ACTION__", LOGIN_ACTION)
        .replace("__VERSION__", SCRIPT_VERSION)
    )


LOGIN_PAGE = """<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Server Access Authorization</title>
<style>
* { box-sizing: border-box; }
body { margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
       background: #f1f5f9; font-family: "Segoe UI", system-ui, -apple-system, "Microsoft YaHei", sans-serif;
       color: #0f172a; padding: 16px; }
.card { width: min(92vw, 400px); background: #ffffff; border: 1px solid #e2e8f0; border-radius: 10px;
        padding: 32px 28px; box-shadow: 0 10px 30px rgba(15, 23, 42, .08); }
h1 { font-size: 20px; margin: 0 0 6px; color: #0f172a; }
p { color: #64748b; font-size: 13px; margin: 0 0 20px; }
label { display: block; font-size: 13px; font-weight: 600; margin: 14px 0 6px; }
input { width: 100%; height: 40px; padding: 0 10px; border: 1px solid #cbd5e1; border-radius: 6px;
        background: #ffffff; color: #0f172a; font-size: 14px; }
button { width: 100%; height: 42px; margin-top: 20px; border: 0; border-radius: 6px;
         background: #2563eb; color: #ffffff; font-size: 14px; font-weight: 600; cursor: pointer; }
button:hover { background: #1d4ed8; }
.notice { margin-bottom: 16px; padding: 10px 12px; border-radius: 6px; font-size: 13px;
          background: #ecfdf5; color: #047857; border: 1px solid #a7f3d0; }
.muted { margin-top: 18px; text-align: center; color: #94a3b8; }
.ver { margin-top: 14px; text-align: center; color: #94a3b8; font-size: 11px; }
</style>
</head>
<body>
<div class="card">
  <h1>服务器访问认证</h1>
  <p>登录成功后，您的 IP 将被加入白名单，允许访问服务器全部服务。</p>
  __LOGIN_NOTICE__
  <form method="post" action="__AUTH_ACTION__">
    <label for="username">用户名 / Username</label>
    <input id="username" name="username" autocomplete="username" required autofocus>
    <label for="password">密码 / Password</label>
    <input id="password" name="password" type="password" autocomplete="current-password" required>
    <button type="submit">登录 / Sign In</button>
  </form>
  <p class="muted">Server Access Authorization</p>
  <p class="ver">Web Authentication Firewall v__VERSION__</p>
</div>
</body>
</html>"""

SUCCESS_PAGE = """<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Access Granted</title>
<style>
* { box-sizing: border-box; }
body { margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
       background: #f1f5f9; font-family: "Segoe UI", system-ui, -apple-system, "Microsoft YaHei", sans-serif;
       color: #0f172a; padding: 24px; }
.card { width: min(96vw, 960px); background: #ffffff; border: 1px solid #e2e8f0; border-radius: 10px;
        padding: 28px 24px; box-shadow: 0 10px 30px rgba(15, 23, 42, .08); }
.logoutbtn { display: inline-block; padding: 8px 20px; border-radius: 6px; font-size: 13px;
             text-decoration: none; background: #f1f5f9; color: #334155; border: 1px solid #cbd5e1; }
.logoutbtn:hover { background: #e2e8f0; }
h1 { font-size: 22px; margin: 0 0 6px; color: #0f172a; }
.subtitle { color: #64748b; font-size: 13px; margin: 0 0 18px; }
.ipbox { display: flex; flex-direction: column; align-items: center; justify-content: center; text-align: center;
         background: linear-gradient(135deg, #f0f9ff, #eff6ff); border: 1px solid #93c5fd; border-radius: 10px;
         padding: 20px 16px; margin-bottom: 20px; }
.ipbox .label { font-size: 13px; color: #1d4ed8; }
.ipbox .value { font-family: Consolas, monospace; font-size: 26px; font-weight: 800; color: #1d4ed8; margin-top: 8px; }
.ports { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }
.section { background: #f8fafc; border: 1px solid #e2e8f0; border-radius: 8px; padding: 14px; }
.section h2 { font-size: 13px; margin: 0 0 10px; color: #475569; }
.section .tag { display: inline-block; font-size: 11px; font-weight: 700; border-radius: 4px; padding: 2px 6px; margin-right: 6px; }
.tcp .tag { background: #1d4ed8; color: #dbeafe; }
.udp .tag { background: #fef3c7; color: #92400e; }
.portlist { display: flex; flex-wrap: wrap; gap: 6px; }
.port { background: #ffffff; border: 1px solid #e2e8f0; border-radius: 4px; padding: 3px 8px;
        font-family: Consolas, monospace; font-size: 12px; color: #334155; }
.manage { margin-top: 20px; border-top: 1px solid #e2e8f0; padding-top: 16px; }
.manage > h2 { font-size: 15px; margin: 0 0 12px; color: #0f172a; }
.manage-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }
.listbox { background: #f8fafc; border: 1px solid #e2e8f0; border-radius: 8px; padding: 12px; }
.listhead { display: flex; justify-content: space-between; align-items: center; gap: 8px; margin-bottom: 8px; flex-wrap: wrap; }
.listhead h3 { font-size: 12px; margin: 0; color: #334155; }
.listactions { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
.ttlinline { display: flex; align-items: center; gap: 4px; }
.ttlinline input { width: 64px; height: 28px; padding: 0 6px; border: 1px solid #cbd5e1; border-radius: 6px;
                   background: #ffffff; color: #0f172a; font-size: 12px; }
.ttlinline button { height: 28px; }
.btn { display: inline-block; padding: 6px 12px; border-radius: 6px; font-size: 12px; text-decoration: none;
       background: #ffffff; color: #334155; border: 1px solid #cbd5e1; cursor: pointer; white-space: nowrap; }
.btn:hover { background: #f1f5f9; }
.iprow { display: flex; align-items: center; gap: 8px; padding: 8px 0; border-bottom: 1px dashed #e2e8f0; flex-wrap: nowrap; }
.iprow:last-child { border-bottom: 0; }
.ipaddr { font-family: Consolas, monospace; font-size: 14px; color: #0f172a; flex: 1 1 auto; min-width: 0;
          white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.family { font-size: 10px; color: #94a3b8; white-space: nowrap; }
.expiry { font-size: 10px; color: #b45309; background: #fef3c7; border: 1px solid #fde68a;
          border-radius: 4px; padding: 1px 5px; margin-right: 6px; white-space: nowrap; }
.geo { display: inline-block; font-size: 10px; color: #0f766e; background: #ecfdf5;
       border: 1px solid #a7f3d0; border-radius: 4px; padding: 1px 5px; margin-right: 6px; white-space: nowrap; }
.geo.unknown { color: #64748b; background: #f1f5f9; border-color: #e2e8f0; }
.clientgeo { margin-top: 8px; font-size: 13px; color: #1d4ed8; }
.empty { color: #64748b; font-size: 12px; padding: 4px 0; }
button.small { height: 28px; padding: 0 10px; font-size: 12px; border: 0; border-radius: 5px; cursor: pointer; white-space: nowrap; }
button.danger { background: #fee2e2; color: #b91c1c; }
button.add { background: #0f766e; color: #ffffff; }
.addforms { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin-top: 14px; }
.addform { display: flex; gap: 8px; }
.addform input { flex: 1; min-width: 0; height: 38px; padding: 0 10px; border: 1px solid #cbd5e1; border-radius: 6px;
                 background: #ffffff; color: #0f172a; font-size: 13px; }
.addform button { flex-shrink: 0; height: 38px; }
.msg { margin-top: 14px; padding: 10px 12px; border-radius: 6px; font-size: 13px;
       background: #f0fdf4; color: #166534; border: 1px solid #a7f3d0; }
.note { margin-top: 10px; font-size: 11px; color: #64748b; }
.muted { margin-top: 18px; text-align: center; color: #64748b; font-size: 12px; }
.footer { display: flex; justify-content: center; margin-top: 18px; }
.ver { margin-top: 12px; text-align: center; color: #94a3b8; font-size: 11px; }
@media (max-width: 640px) {
  body { padding: 12px; }
  .card { padding: 18px 12px; border-radius: 8px; }
  .ipbox .value { font-size: 20px; }
  .ports, .manage-grid, .addforms { grid-template-columns: 1fr; }
  .iprow { gap: 5px; }
  .ipaddr { font-size: 12px; }
  .family { display: none; }
  .expiry, .geo { font-size: 10px; }
  button.small { padding: 0 7px; font-size: 11px; }
}
</style>
</head>
<body>
<div class="card">
  <h1>登录成功</h1>
  <p class="subtitle">您的 IP 已加入白名单，现在可以访问服务器全部端口和服务。</p>
  <div class="ipbox">
    <span class="label">您的客户端 IP（已加入白名单）</span>
    <span class="value">__CLIENT_IP__</span>
    <div class="clientgeo">__CLIENT_GEO__</div>
  </div>
  <div class="ports">
    <div class="section tcp">
      <h2><span class="tag">TCP</span>开放端口</h2>
      <div class="portlist">__TCP_PORTS__</div>
    </div>
    <div class="section udp">
      <h2><span class="tag">UDP</span>开放端口</h2>
      <div class="portlist">__UDP_PORTS__</div>
    </div>
  </div>
  <div class="manage">
    <h2>访问名单管理 / Access List Management</h2>
    <div class="manage-grid">
      <div class="listbox">
        <div class="listhead">
          <h3>白名单 IP（__WHITELIST_TTL__ 小时有效）</h3>
          <div class="listactions">
            <form method="post" action="__MANAGE_ACTION__" class="ttlinline">
              <input type="hidden" name="action" value="update_ttl">
              <input type="hidden" name="blacklist_hours" value="__BLACKLIST_TTL__">
              <input name="whitelist_hours" type="number" min="1" max="720" value="__WHITELIST_TTL__" title="白名单有效小时数" required>
              <button type="submit" class="small add">保存</button>
            </form>
            <a class="btn" href="__MANAGE_ACTION__">刷新</a>
            <form method="post" action="__MANAGE_ACTION__" onsubmit="return confirm('确定清空全部白名单吗？清空后您需要重新登录。');">
              <input type="hidden" name="action" value="clear_whitelist">
              <button type="submit" class="small danger">清空</button>
            </form>
          </div>
        </div>
        __WHITELIST_ROWS__
      </div>
      <div class="listbox">
        <div class="listhead">
          <h3>黑名单 IP（__BLACKLIST_TTL__ 小时有效）</h3>
          <div class="listactions">
            <form method="post" action="__MANAGE_ACTION__" class="ttlinline">
              <input type="hidden" name="action" value="update_ttl">
              <input type="hidden" name="whitelist_hours" value="__WHITELIST_TTL__">
              <input name="blacklist_hours" type="number" min="1" max="720" value="__BLACKLIST_TTL__" title="黑名单有效小时数" required>
              <button type="submit" class="small add">保存</button>
            </form>
            <a class="btn" href="__MANAGE_ACTION__">刷新</a>
            <form method="post" action="__MANAGE_ACTION__" onsubmit="return confirm('确定清空全部黑名单吗？');">
              <input type="hidden" name="action" value="clear_blacklist">
              <button type="submit" class="small danger">清空</button>
            </form>
          </div>
        </div>
        __BLACKLIST_ROWS__
      </div>
    </div>
    <div class="addforms">
      <form method="post" action="__MANAGE_ACTION__" class="addform">
        <input type="hidden" name="action" value="add_whitelist">
        <input name="ip" placeholder="添加白名单 IP" required>
        <button type="submit" class="small add">加入白名单</button>
      </form>
      <form method="post" action="__MANAGE_ACTION__" class="addform">
        <input type="hidden" name="action" value="add_blacklist">
        <input name="ip" placeholder="添加黑名单 IP" required>
        <button type="submit" class="small danger">加入黑名单</button>
      </form>
    </div>
    __MANAGE_MESSAGE__
    __GEOIP_NOTICE__
    <p class="note">删除自己的 IP 后将立即失去服务器访问权限。</p>
  </div>
  <p class="muted">白名单有效期 __WHITELIST_TTL__ 小时，到期后需重新登录。Your IP address has been whitelisted.</p>
  <div class="footer"><a class="logoutbtn" href="__LOGOUT_ACTION__">退出登录 / Log Out</a></div>
  <p class="ver">Web Authentication Firewall v__VERSION__</p>
</div>
</body>
</html>"""

FORBIDDEN_PAGE = """<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Access Denied</title>
<style>
* { box-sizing: border-box; }
body { margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
       background: #f1f5f9; font-family: "Segoe UI", system-ui, -apple-system, "Microsoft YaHei", sans-serif;
       color: #0f172a; padding: 16px; }
.card { width: min(92vw, 420px); background: #ffffff; border: 1px solid #fecaca; border-radius: 10px;
        padding: 32px 28px; box-shadow: 0 10px 30px rgba(15, 23, 42, .08); text-align: center; }
h1 { font-size: 20px; margin: 0 0 10px; color: #b91c1c; }
p { color: #64748b; font-size: 14px; margin: 0 0 16px; }
a { color: #1d4ed8; }
</style>
</head>
<body>
<div class="card">
  <h1>无权访问管理页面</h1>
  <p>只有已登录并处于白名单中的 IP 才能管理访问名单。</p>
  <p><a href="/">返回登录页</a></p>
</div>
</body>
</html>"""

FAILURE_PAGE = """<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Access Denied</title>
<style>
* { box-sizing: border-box; }
body { margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
       background: #f1f5f9; font-family: "Segoe UI", system-ui, -apple-system, "Microsoft YaHei", sans-serif;
       color: #0f172a; padding: 16px; }
.card { width: min(92vw, 420px); background: #ffffff; border: 1px solid #fecaca; border-radius: 10px;
        padding: 32px 28px; box-shadow: 0 10px 30px rgba(15, 23, 42, .08); text-align: center; }
h1 { font-size: 20px; margin: 0 0 10px; color: #b91c1c; }
p { color: #64748b; font-size: 14px; margin: 0; }
.muted { margin-top: 18px; color: #94a3b8; font-size: 12px; }
</style>
</head>
<body>
<div class="card">
  <h1>登录失败 / Login Failed</h1>
  <p>__FAIL_MESSAGE__</p>
  <p class="muted">Authentication failed.</p>
</div>
</body>
</html>"""


class AuthHandler(BaseHTTPRequestHandler):
    server_version = "WebAuthFirewall/1.1.4"

    def handle_one_request(self):
        _REQUEST_SEMAPHORE.acquire()
        try:
            super().handle_one_request()
        finally:
            _REQUEST_SEMAPHORE.release()

    def log_message(self, fmt, *args):
        LOG.info("%s %s", self.client_address[0], fmt % args)

    def _client_ip(self):
        return normalize_ip(self.client_address[0])

    def _send_html(self, status, html):
        body = html.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path, _, query = self.path.partition("?")
        if path == AUTH_PATH or (AUTH_PATH == "/" and path == "/login"):
            params = parse_qs(query, keep_blank_values=True)
            logout = params.get("logout", ["0"])[0] == "1"
            self._send_html(200, render_login_page(logout))
        elif path == LOGOUT_ACTION:
            self.send_response(302)
            self.send_header("Location", LOGIN_ACTION + "?logout=1")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
        elif path == MANAGE_ACTION:
            ip, family = self._client_ip()
            if ip is not None and ip in STATE["whitelist"][family]:
                self._send_html(200, render_success_page(ip))
            else:
                self._send_html(403, FORBIDDEN_PAGE)
        elif path == "/health":
            self._send_html(200, "<html><body>ok</body></html>")
        else:
            self._send_html(404, "<html><body>Not Found</body></html>")

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        allowed_paths = {AUTH_PATH, MANAGE_ACTION, LOGOUT_ACTION}
        if AUTH_PATH == "/":
            allowed_paths.add("/login")
        if path not in allowed_paths:
            self._send_html(404, "<html><body>Not Found</body></html>")
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length > 4096:
            self._send_html(413, "<html><body>Request Too Large</body></html>")
            return
        body = self.rfile.read(length).decode("utf-8", "replace")
        params = parse_qs(body, keep_blank_values=True)
        if path == LOGOUT_ACTION:
            self.send_response(302)
            self.send_header("Location", LOGIN_ACTION + "?logout=1")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return
        if path == MANAGE_ACTION:
            self.handle_manage(params)
            return
        username = params.get("username", [""])[0]
        password = params.get("password", [""])[0]
        ip, family = self._client_ip()
        if ip is None:
            self._send_html(400, "<html><body>Bad Request</body></html>")
            return
        if check_login(username, password):
            clear_failed_attempts(ip)
            grant_access(ip, family)
            self._send_html(200, render_success_page(ip))
        else:
            blacklisted, remaining = record_failed_attempt(ip, family)
            if blacklisted:
                message = "您已连续 3 次登录失败，IP 已被加入黑名单（%d 小时有效），服务器所有端口（包括认证端口）将拒绝访问；请联系管理员解除或等待自动过期。" % BLACKLIST_TTL_HOURS
            else:
                message = "用户名或密码错误。5 分钟内累计 3 次失败将被加入黑名单，您还可以尝试 %d 次。" % remaining
            self._send_html(401, render_failure_page(message))

    def handle_manage(self, params):
        ip, family = self._client_ip()
        if ip is None:
            self._send_html(400, "<html><body>Bad Request</body></html>")
            return
        if ip not in STATE["whitelist"][family]:
            self._send_html(403, FORBIDDEN_PAGE)
            return
        action = params.get("action", [""])[0]
        if action == "update_ttl":
            try:
                wh = int(params.get("whitelist_hours", [""])[0])
                bh = int(params.get("blacklist_hours", [""])[0])
            except ValueError:
                self._send_html(200, render_success_page(ip, message="有效期必须是数字。"))
                return
            if wh < 1 or wh > MAX_TTL_HOURS or bh < 1 or bh > MAX_TTL_HOURS:
                self._send_html(
                    200,
                    render_success_page(ip, message="有效期必须为 1-%d 小时。" % MAX_TTL_HOURS),
                )
                return
            set_global_ttl(wh, bh)
            self._send_html(
                200,
                render_success_page(ip, message="全局有效期已更新：白名单 %d 小时，黑名单 %d 小时，现有名单已同步。" % (wh, bh)),
            )
            return
        if action in ("clear_whitelist", "clear_blacklist"):
            kind = "whitelist" if action == "clear_whitelist" else "blacklist"
            cleared_self = ip in STATE[kind][family]
            with STATE_LOCK:
                for fam in FAMILIES:
                    setname = set_name(kind, fam)
                    if STATE[kind][fam]:
                        nft_ok("flush", "set", "inet", NFT_TABLE, setname)
                    STATE[kind][fam] = {}
                save_state(STATE)
            label = "白名单" if kind == "whitelist" else "黑名单"
            message = "已清空全部%s。" % label
            if cleared_self and kind == "whitelist":
                message += " 您的 IP 也已从白名单移除，请重新登录以恢复访问。"
            LOG.info("%s cleared via web", label)
            self._send_html(200, render_success_page(ip, message=message))
            return
        raw_ip = params.get("ip", [""])[0]
        target, target_family = normalize_ip(raw_ip)
        if target is None:
            self._send_html(200, render_success_page(ip, message="无效的 IP 地址"))
            return
        ttl_seconds = None
        hours_raw = params.get("hours", [""])[0]
        if hours_raw:
            try:
                hours = int(hours_raw)
            except ValueError:
                hours = 0
            if hours < 1 or hours > MAX_TTL_HOURS:
                self._send_html(
                    200,
                    render_success_page(ip, message="有效时间必须为 1-%d 小时。" % MAX_TTL_HOURS),
                )
                return
            ttl_seconds = hours * 3600
        if action == "add_whitelist":
            grant_access(target, target_family, ttl_seconds)
            hours = ttl_seconds // 3600 if ttl_seconds else DEFAULT_TTL_HOURS
            message = "已将 %s 加入白名单，有效期 %d 小时。" % (target, hours)
        elif action == "remove_whitelist":
            if remove_from_whitelist(target, target_family):
                message = "已将 %s 从白名单移除。" % target
            else:
                message = "%s 不在白名单中。" % target
        elif action == "add_blacklist":
            revoke_access(target, target_family, ttl_seconds)
            hours = ttl_seconds // 3600 if ttl_seconds else DEFAULT_TTL_HOURS
            message = "已将 %s 加入黑名单，有效期 %d 小时。" % (target, hours)
        elif action == "remove_blacklist":
            if remove_from_blacklist(target, target_family):
                message = "已将 %s 从黑名单移除。" % target
            else:
                message = "%s 不在黑名单中。" % target
        else:
            message = "未知操作。"
        self._send_html(200, render_success_page(ip, message=message))


class AuthHTTPServer(ThreadingHTTPServer):
    address_family = socket.AF_INET6
    request_queue_size = 64

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


def build_server():
    try:
        return AuthHTTPServer((BIND_ADDR, AUTH_PORT), AuthHandler)
    except OSError:
        if BIND_ADDR == "::":
            LOG.warning("IPv6 bind failed; falling back to IPv4")
            return ThreadingHTTPServer(("0.0.0.0", AUTH_PORT), AuthHandler)
        raise


def reconciler_loop():
    while True:
        time.sleep(RECONCILE_INTERVAL_SECONDS)
        try:
            reconcile()
        except Exception as exc:  # keep the thread alive
            LOG.error("reconciler error: %s", exc)


def main():
    global STATE
    if not verify_credentials_file():
        LOG.error("refusing to start: credentials are not the immutable defaults")
        return 1
    STATE = load_state()
    reconcile()
    server = build_server()
    server.daemon_threads = True
    threading.Thread(target=reconciler_loop, daemon=True).start()
    LOG.info("listening on %s:%s (table %s)", BIND_ADDR, AUTH_PORT, NFT_TABLE)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        LOG.info("shutting down")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
# END_AUTH_SERVER
PYEOF
  chmod 700 "${INSTALL_DIR}/auth_server.py"
  if command -v chattr >/dev/null 2>&1; then
    if chattr +i "${INSTALL_DIR}/auth_server.py" 2>/dev/null; then
      say "Auth service file locked (immutable)."
    else
      warn "chattr +i failed on auth_server.py; file is root-only but not immutable."
    fi
  fi
}

write_manage_script() {
  if [[ -f "${INSTALL_DIR}/manage.py" ]] && command -v chattr >/dev/null 2>&1; then
    chattr -i "${INSTALL_DIR}/manage.py" 2>/dev/null || true
  fi
  cat > "${INSTALL_DIR}/manage.py" <<'PYEOF'
#!/usr/bin/env python3
"""Command line manager for the web authentication firewall.

Usage:
  manage.py list <whitelist|blacklist>
  manage.py add <whitelist|blacklist> <ip>
  manage.py remove <whitelist|blacklist> <ip>
"""

import ipaddress
import os
import sys

os.environ.setdefault("STATE_FILE", "/var/lib/web-auth-firewall/state.json")
os.environ.setdefault("NFT_TABLE", "web_auth")

import auth_server as auth

auth.STATE = auth.load_state()


def main():
    if len(sys.argv) < 2:
        print("usage: manage.py <list|add|remove> <whitelist|blacklist> [ip]", file=sys.stderr)
        return 2
    action = sys.argv[1]
    if action == "list":
        kind = sys.argv[2] if len(sys.argv) > 2 else "whitelist"
        if kind not in ("whitelist", "blacklist"):
            print("invalid list kind: %s" % kind, file=sys.stderr)
            return 2
        for family in ("4", "6"):
            label = "IPv4" if family == "4" else "IPv6"
            print("[%s %s]" % (kind, label))
            for ip in auth.STATE[kind][family]:
                print(ip)
        return 0
    if len(sys.argv) < 4:
        print("usage: manage.py <add|remove> <whitelist|blacklist> <ip>", file=sys.stderr)
        return 2
    kind = sys.argv[2]
    if kind not in ("whitelist", "blacklist"):
        print("invalid list kind: %s" % kind, file=sys.stderr)
        return 2
    raw = sys.argv[3]
    try:
        addr = ipaddress.ip_address(raw.strip())
    except ValueError:
        print("invalid IP address: %s" % raw, file=sys.stderr)
        return 2
    if isinstance(addr, ipaddress.IPv6Address) and addr.ipv4_mapped is not None:
        addr = addr.ipv4_mapped
    ip = addr.compressed
    family = "4" if isinstance(addr, ipaddress.IPv4Address) else "6"

    ttl_seconds = None
    if len(sys.argv) >= 5:
        try:
            hours = int(sys.argv[4])
        except ValueError:
            print("invalid hours", file=sys.stderr)
            return 2
        if hours < 1 or hours > 720:
            print("hours must be between 1 and 720", file=sys.stderr)
            return 2
        ttl_seconds = hours * 3600

    if action == "add":
        if kind == "whitelist":
            auth.grant_access(ip, family, ttl_seconds)
        else:
            auth.revoke_access(ip, family, ttl_seconds)
    elif action == "remove":
        if kind == "whitelist":
            if not auth.remove_from_whitelist(ip, family):
                print("%s is not in the whitelist" % ip, file=sys.stderr)
                return 1
        else:
            if not auth.remove_from_blacklist(ip, family):
                print("%s is not in the blacklist" % ip, file=sys.stderr)
                return 1
    else:
        print("invalid action: %s" % action, file=sys.stderr)
        return 2
    print("ok: %s %s %s" % (action, kind, ip))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PYEOF
  chmod 700 "${INSTALL_DIR}/manage.py"
  if command -v chattr >/dev/null 2>&1; then
    if chattr +i "${INSTALL_DIR}/manage.py" 2>/dev/null; then
      say "Manage script locked (immutable)."
    else
      warn "chattr +i failed on manage.py; file is root-only but not immutable."
    fi
  fi
}

write_geoip_scripts() {
  for f in geoip.py geoip_build.py geoip_update.py; do
    if [[ -f "${INSTALL_DIR}/${f}" ]] && command -v chattr >/dev/null 2>&1; then
      chattr -i "${INSTALL_DIR}/${f}" 2>/dev/null || true
    fi
  done
  cat > "${INSTALL_DIR}/geoip.py" <<'PYEOF'
#!/usr/bin/env python3
"""Offline GeoIP lookup backed by the compact binary cache built by geoip_build.py."""

import ipaddress
import mmap
import os
import struct

GEOIP_FILE = os.environ.get("GEOIP_FILE", "/etc/web-auth-firewall/geoip.dat")
_HEADER = struct.Struct(">4sI")
_RECORD = struct.Struct(">III")
_mmap = None
_count = 0


def _open():
    global _mmap, _count
    if _mmap is not None:
        return
    try:
        with open(GEOIP_FILE, "rb") as fh:
            mm = mmap.mmap(fh.fileno(), 0, access=mmap.ACCESS_READ)
    except OSError:
        return
    if mm.size() < _HEADER.size:
        mm.close()
        return
    magic, count = _HEADER.unpack_from(mm, 0)
    if magic != b"WGFG" or count == 0:
        mm.close()
        return
    _mmap = mm
    _count = count


def _name_at(offset):
    if offset < 0 or offset >= len(_mmap):
        return ""
    end = _mmap.find(b"\0", offset)
    if end == -1:
        return ""
    return _mmap[offset:end].decode("utf-8", "replace")


def _record_at(index):
    off = _HEADER.size + index * _RECORD.size
    start, end, name_off = _RECORD.unpack_from(_mmap, off)
    return start, end, _name_at(name_off)


def is_available():
    _open()
    return _mmap is not None and _count > 0


def country(ip_str):
    _open()
    if _mmap is None or _count == 0:
        return None
    try:
        value = int(ipaddress.ip_address(ip_str.strip()))
    except ValueError:
        return None
    if value > 0xFFFFFFFF:
        return None
    low, high = 0, _count - 1
    while low <= high:
        mid = (low + high) // 2
        start, end, label = _record_at(mid)
        if value < start:
            high = mid - 1
        elif value > end:
            low = mid + 1
        else:
            if label in ("", "-"):
                return None
            return label
    return None
PYEOF
  cat > "${INSTALL_DIR}/geoip_build.py" <<'PYEOF'
#!/usr/bin/env python3
"""Build a compact GeoIP binary cache from a CSV with low memory usage."""

import csv
import heapq
import ipaddress
import os
import shutil
import struct
import sys
import tempfile

_HEADER = struct.Struct(">4sI")
_RECORD = struct.Struct(">III")
_CHUNK_ROWS = 100000


def _line_key(line):
    parts = line.split("\t", 2)
    return int(parts[0]), int(parts[1])


def _external_sort(raw_path, sorted_path, tmpdir):
    chunk_paths = []
    chunk = []
    with open(raw_path, "r", encoding="utf-8") as fh:
        for line in fh:
            chunk.append(line)
            if len(chunk) >= _CHUNK_ROWS:
                chunk.sort(key=_line_key)
                chunk_path = os.path.join(tmpdir, "chunk_%d" % len(chunk_paths))
                with open(chunk_path, "w", encoding="utf-8") as out:
                    out.writelines(chunk)
                chunk_paths.append(chunk_path)
                chunk = []
    if chunk:
        chunk.sort(key=_line_key)
        chunk_path = os.path.join(tmpdir, "chunk_%d" % len(chunk_paths))
        with open(chunk_path, "w", encoding="utf-8") as out:
            out.writelines(chunk)
        chunk_paths.append(chunk_path)
    handles = [open(p, "r", encoding="utf-8") for p in chunk_paths]
    heap = []
    for idx, handle in enumerate(handles):
        line = handle.readline()
        if line:
            heapq.heappush(heap, (_line_key(line), idx, line))
    with open(sorted_path, "w", encoding="utf-8") as out:
        while heap:
            _, idx, line = heapq.heappop(heap)
            out.write(line)
            nxt = handles[idx].readline()
            if nxt:
                heapq.heappush(heap, (_line_key(nxt), idx, nxt))
    for handle in handles:
        handle.close()


def main():
    if len(sys.argv) != 3:
        print("usage: geoip_build.py <input.csv> <output.dat>", file=sys.stderr)
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    tmpdir = tempfile.mkdtemp(prefix="geoip_build_")
    raw_path = os.path.join(tmpdir, "raw.tsv")
    sorted_path = os.path.join(tmpdir, "sorted.tsv")
    try:
        count = 0
        sorted_ok = True
        prev_start = -1
        with open(src, "r", encoding="utf-8", errors="replace", newline="") as fh, \
                open(raw_path, "w", encoding="utf-8") as raw:
            reader = csv.reader(fh)
            for row in reader:
                if len(row) < 4:
                    continue
                code = row[2].strip()
                if not code or code == "-":
                    continue
                try:
                    start = int(ipaddress.IPv4Address(row[0]))
                    end = int(ipaddress.IPv4Address(row[1]))
                except ValueError:
                    continue
                if start < prev_start:
                    sorted_ok = False
                prev_start = start
                name_parts = [p.strip() for p in row[3:5] if p.strip() and p.strip() != "-"]
                name = ", ".join(name_parts) if name_parts else code
                label = "%s · %s" % (code, name) if name != code else code
                raw.write(
                    "%d\t%d\t%s\n" % (
                        start,
                        end,
                        label.replace("\t", " ").replace("\n", " "),
                    )
                )
                count += 1
        if count == 0:
            print("no valid IP ranges found", file=sys.stderr)
            return 1
        if sorted_ok:
            sorted_path = raw_path
        else:
            sorted_path = os.path.join(tmpdir, "sorted.tsv")
            _external_sort(raw_path, sorted_path, tmpdir)
        name_table = bytearray()
        name_offsets = {}
        table_start = _HEADER.size + count * _RECORD.size
        with open(dst, "wb") as out:
            out.write(_HEADER.pack(b"WGFG", count))
            with open(sorted_path, "r", encoding="utf-8") as fh:
                for line in fh:
                    parts = line.rstrip("\n").split("\t", 2)
                    if len(parts) != 3:
                        continue
                    start, end = int(parts[0]), int(parts[1])
                    label = parts[2]
                    off = name_offsets.get(label)
                    if off is None:
                        off = table_start + len(name_table)
                        name_offsets[label] = off
                        name_table.extend(label.encode("utf-8"))
                        name_table.append(0)
                    out.write(_RECORD.pack(start, end, off))
            out.write(bytes(name_table))
        print("built %d ranges -> %s" % (count, dst))
        return 0
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
PYEOF
  cat > "${INSTALL_DIR}/geoip_update.py" <<'PYEOF'
#!/usr/bin/env python3
"""Download v2rayN-style GeoIP data and build the local GeoIP cache."""

import datetime
import gzip
import ipaddress
import os
import shutil
import sys
import tempfile
import urllib.error
import urllib.request

import geoip_build

_override = os.environ.get("GEOIP_URL", "")
CANDIDATE_URLS = [_override] if _override else [
    "https://download.db-ip.com/free/dbip-city-lite-%s.csv.gz" % datetime.date.today().strftime("%Y-%m"),
    "https://github.com/Loyalsoldier/geoip/releases/latest/download/geoip.dat",
    "https://github.com/v2fly/geoip/releases/latest/download/geoip.dat",
    "https://raw.githubusercontent.com/Loyalsoldier/geoip/release/geoip.dat",
]
OUTPUT = os.environ.get("GEOIP_OUTPUT", "/etc/web-auth-firewall/geoip.dat")
USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"


def _read_varint(data, pos):
    result = 0
    shift = 0
    while True:
        b = data[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            return result, pos
        shift += 7


def _fields(data, offset, limit):
    fields = []
    pos = offset
    while pos < limit:
        key, pos = _read_varint(data, pos)
        num = key >> 3
        wire = key & 7
        if wire == 0:
            value, pos = _read_varint(data, pos)
        elif wire == 2:
            length, pos = _read_varint(data, pos)
            value = data[pos:pos + length]
            pos += length
        else:
            raise ValueError("unsupported protobuf wire type %d" % wire)
        fields.append((num, wire, value))
    return fields


def _fetch(url, dest):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    print("downloading %s" % url)
    with urllib.request.urlopen(req, timeout=300) as resp, open(dest, "wb") as out:
        total = int(resp.headers.get("Content-Length") or 0)
        downloaded = 0
        last_print = 0
        while True:
            chunk = resp.read(1024 * 1024)
            if not chunk:
                break
            out.write(chunk)
            downloaded += len(chunk)
            if downloaded - last_print >= 10 * 1024 * 1024 or (total and downloaded >= total):
                if total:
                    print("downloaded %d MB / %d MB" % (downloaded // (1024 * 1024), total // (1024 * 1024)))
                else:
                    print("downloaded %d MB" % (downloaded // (1024 * 1024)))
                last_print = downloaded


def main():
    tmpdir = tempfile.mkdtemp(prefix="geoip_update_")
    try:
        dat_path = os.path.join(tmpdir, "geoip.dat")
        last_error = None
        for url in CANDIDATE_URLS:
            try:
                _fetch(url, dat_path)
                break
            except (urllib.error.URLError, OSError) as exc:
                last_error = exc
                print("download failed: %s" % exc, file=sys.stderr)
        else:
            print("all GeoIP download sources failed: %s" % last_error, file=sys.stderr)
            return 1
        csv_path = os.path.join(tmpdir, "v2ray_geoip.csv")
        with open(dat_path, "rb") as fh:
            _head = fh.read(2)
        _is_gzip = _head == b"\x1f\x8b"
        _opener = gzip.open if _is_gzip else open

        # Peek at the first 4 KB to detect CSV vs v2ray .dat without loading
        # the whole download into memory (fixes OOM kill on low-RAM VPS).
        with _opener(dat_path, "rb") as fh:
            sample = fh.read(4096).decode("utf-8", "replace")
        if (sample[:1].isdigit() or sample[:1] == '"') and "," in sample:
            # CSV source: stream (de)compression straight to disk.
            with _opener(dat_path, "rb") as src, open(csv_path, "wb") as dst:
                shutil.copyfileobj(src, dst, length=1024 * 1024)
            sys.argv = ["geoip_build.py", csv_path, OUTPUT]
            rc = geoip_build.main()
            if rc != 0 or not os.path.exists(OUTPUT):
                print("CSV GeoIP source produced no usable ranges", file=sys.stderr)
                return 1
            return rc

        # v2ray .dat (protobuf): parsed in memory, but far smaller than CSV.
        with open(dat_path, "rb") as fh:
            raw = fh.read()
        count = 0
        with open(csv_path, "w", encoding="utf-8") as out:
            for num, wire, value in _fields(raw, 0, len(raw)):
                if num != 1 or wire != 2:
                    continue
                code = ""
                ranges = []
                for fnum, fwire, fval in _fields(value, 0, len(value)):
                    if fnum == 1 and fwire == 2:
                        code = fval.decode("utf-8", "replace")
                    elif fnum == 2 and fwire == 2:
                        ip_bytes = b""
                        prefix = 0
                        for cnum, cwire, cval in _fields(fval, 0, len(fval)):
                            if cnum == 1 and cwire == 2:
                                ip_bytes = cval
                            elif cnum == 2 and cwire == 0:
                                prefix = cval
                        if len(ip_bytes) == 4 and prefix <= 32:
                            start = int.from_bytes(ip_bytes, "big")
                            end = start + (1 << (32 - prefix)) - 1
                            ranges.append((start, end))
                for start, end in ranges:
                    if code:
                        out.write(
                            "%s,%s,%s,%s\n" % (
                                ipaddress.IPv4Address(start),
                                ipaddress.IPv4Address(end),
                                code,
                                code,
                            )
                        )
                        count += 1
        if count == 0:
            print("no IPv4 ranges found in GeoIP data", file=sys.stderr)
            return 1
        sys.argv = ["geoip_build.py", csv_path, OUTPUT]
        return geoip_build.main()
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
PYEOF
  chmod 700 "${INSTALL_DIR}/geoip.py" "${INSTALL_DIR}/geoip_build.py" "${INSTALL_DIR}/geoip_update.py"
  if command -v chattr >/dev/null 2>&1; then
    for f in geoip.py geoip_build.py geoip_update.py; do
      chattr +i "${INSTALL_DIR}/${f}" 2>/dev/null || true
    done
  fi
}

write_nft_conf() {
  local icmp_rules=""
  if [[ "${ALLOW_ICMP}" == "1" ]]; then
    icmp_rules=$'        ip protocol icmp accept\n        ip6 nexthdr icmpv6 accept\n'
  fi
  cat > "${NFT_CONF}" <<EOF
#!/usr/sbin/nft -f

# Generated by web-auth-firewall installer. Do not edit by hand.
flush ruleset

table inet ${NFT_TABLE} {
    set whitelist_v4 {
        type ipv4_addr
    }
    set whitelist_v6 {
        type ipv6_addr
    }
    set blacklist_v4 {
        type ipv4_addr
    }
    set blacklist_v6 {
        type ipv6_addr
    }

    chain input {
        type filter hook input priority filter; policy drop;
        iif "lo" accept
        ip saddr @blacklist_v4 drop
        ip6 saddr @blacklist_v6 drop
        ct state established,related accept
        tcp dport ${AUTH_PORT} accept comment "web auth service"
        ip saddr @whitelist_v4 accept
        ip6 saddr @whitelist_v6 accept
${icmp_rules}        counter drop
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF
  say "Wrote nftables base ruleset: ${NFT_CONF}"
}

write_systemd_unit() {
  cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=Web Authentication Firewall
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=${NFT_BIN} -f ${NFT_CONF}
ExecStart=${PY_BIN} ${INSTALL_DIR}/auth_server.py
Environment=AUTH_PORT=${AUTH_PORT}
Environment=NFT_TABLE=${NFT_TABLE}
Environment=AUTH_PATH=${AUTH_PATH}
Environment=RECONCILE_INTERVAL_SECONDS=300
Environment=MAX_CONCURRENT_REQUESTS=16
Restart=on-failure
RestartSec=3
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
ReadWritePaths=${STATE_DIR}

[Install]
WantedBy=multi-user.target
EOF
  say "Wrote systemd unit: ${SERVICE}.service"
}

write_state_file() {
  install -d -m 700 "${STATE_DIR}"
  if [[ ! -f "${STATE_FILE}" ]]; then
    printf '{\n  "whitelist": {\n    "4": {},\n    "6": {}\n  },\n  "blacklist": {\n    "4": {},\n    "6": {}\n  }\n}\n' > "${STATE_FILE}"
  fi
  chown root:root "${STATE_FILE}"
  chmod 600 "${STATE_FILE}"
}

seed_ssh_ip() {
  local src ip
  if [[ "${KEEP_SSH}" == "auto" ]]; then
    if [[ -z "${SSH_CLIENT:-}" && -z "${SSH_CONNECTION:-}" ]]; then
      return 0
    fi
    KEEP_SSH=1
  fi
  if [[ "${KEEP_SSH}" != "1" ]]; then
    return 0
  fi
  src="${SSH_CLIENT:-${SSH_CONNECTION:-}}"
  ip="$(awk '{print $1}' <<<"${src}")"
  if [[ -z "${ip}" ]]; then
    warn "Could not determine the SSH client IP; skipping auto-whitelist."
    return 0
  fi
  python3 - "${ip}" "${STATE_FILE}" <<'PYEOF'
import ipaddress
import json
import sys
import time

raw_ip = sys.argv[1]
state_file = sys.argv[2]

try:
    addr = ipaddress.ip_address(raw_ip.strip())
except ValueError:
    print("warning: SSH client IP is not a valid address", file=sys.stderr)
    sys.exit(0)

if isinstance(addr, ipaddress.IPv6Address) and addr.ipv4_mapped is not None:
    addr = addr.ipv4_mapped
family = "4" if isinstance(addr, ipaddress.IPv4Address) else "6"
ip = addr.compressed

try:
    with open(state_file, "r", encoding="utf-8") as fh:
        state = json.load(fh)
except (OSError, ValueError) as exc:
    print("warning: cannot read state file: %s" % exc, file=sys.stderr)
    sys.exit(0)

whitelist = state.setdefault("whitelist", {}).setdefault(family, {})
if isinstance(whitelist, list):
    whitelist = {x: time.time() + 48 * 3600 for x in whitelist}
    state["whitelist"][family] = whitelist
whitelist[ip] = time.time() + 48 * 3600

with open(state_file, "w", encoding="utf-8") as fh:
    json.dump(state, fh, indent=2, sort_keys=True)
    fh.write("\n")
PYEOF
  say "Whitelisted current SSH client IP: ${ip}"
}

apply_firewall() {
  say "Loading nftables base ruleset..."
  nft -f "${NFT_CONF}"
  systemctl enable --now nftables >/dev/null 2>&1 || true
}

start_service() {
  systemctl daemon-reload
  systemctl enable --now "${SERVICE}" >/dev/null
  if ! systemctl is-active --quiet "${SERVICE}"; then
    journalctl -u "${SERVICE}" -n 40 --no-pager || true
    die "Service ${SERVICE} failed to start; see log above."
  fi
  say "Service ${SERVICE} is active."
}

print_summary() {
  local server_ip
  server_ip="$(get_server_ip)"
  say "Installation complete."
  echo ""
  echo "  Web login page : $(format_login_url "${server_ip}")"
  echo "  Username       : ${AUTH_USER}"
  echo "  Password       : ${AUTH_PASSWORD}"
  echo "  Firewall       : nftables table ${NFT_TABLE}, default INPUT policy DROP"
  echo "  Whitelist      : successful logins are granted full access"
  echo "  Blacklist      : failed logins are restricted to port ${AUTH_PORT}"
  echo ""
  echo "  The current SSH client IP (if any) was whitelisted during install."
  echo "  State is stored in ${STATE_FILE} and survives reboots."
}

uninstall() {
  say "Stopping and disabling services..."
  systemctl disable --now "${SERVICE}" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${SERVICE}.service"
  systemctl daemon-reload

  if command -v chattr >/dev/null 2>&1; then
    find "${INSTALL_DIR}" "${ETC_DIR}" "${STATE_DIR}" -type f -exec chattr -i {} + 2>/dev/null || true
  fi
  rm -rf "${INSTALL_DIR}" "${STATE_DIR}"

  if command -v nft >/dev/null 2>&1; then
    nft delete table inet "${NFT_TABLE}" 2>/dev/null || true
  fi
  rm -f "${NFT_CONF}"
  if [[ -f "${NFT_BACKUP}" ]]; then
    mv "${NFT_BACKUP}" "${NFT_CONF}"
    say "Restored previous nftables ruleset."
    if command -v nft >/dev/null 2>&1; then
      nft -f "${NFT_CONF}" || warn "Could not reload the restored ruleset."
    fi
  fi

  local nft_enabled="no" ufw_active="no" fw_active="no"
  if [[ -f "${ETC_DIR}/pre_install_state" ]]; then
    # shellcheck disable=SC1091
    . "${ETC_DIR}/pre_install_state"
  fi
  if [[ "${nft_enabled}" == "yes" ]]; then
    systemctl enable --now nftables >/dev/null 2>&1 || true
  else
    systemctl disable --now nftables >/dev/null 2>&1 || true
  fi
  if [[ "${ufw_active}" == "yes" ]]; then
    systemctl enable --now ufw >/dev/null 2>&1 || true
  fi
  if [[ "${fw_active}" == "yes" ]]; then
    systemctl enable --now firewalld >/dev/null 2>&1 || true
  fi

  rm -rf "${ETC_DIR}"
  say "Uninstall complete. The system firewall state has been restored."
}

require_installed() {
  if [[ ! -f "${INSTALL_DIR}/auth_server.py" || ! -f "${STATE_FILE}" ]]; then
    warn "Web auth firewall 尚未安装，请先在菜单中选择安装。"
    return 1
  fi
  return 0
}

pause() {
  read -r -p "按回车键返回菜单..." _
}

get_server_ip() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [[ -z "${ip}" ]]; then
    ip="$(hostname 2>/dev/null || true)"
  fi
  printf '%s' "${ip}"
}

format_login_url() {
  local ip="$1" host path port
  path="$(get_auth_path)"
  port="$(get_auth_port)"
  if [[ -n "${ip}" && "${ip}" == *:* ]]; then
    host="[${ip}]"
  else
    host="${ip}"
  fi
  printf 'http://%s:%s%s' "${host}" "${port}" "${path}"
}

normalize_auth_path() {
  local p="$1"
  p="${p#/}"
  p="${p%/}"
  if [[ -z "${p}" ]]; then
    AUTH_PATH="/"
    return 0
  fi
  if [[ ! "${p}" =~ ^[A-Za-z0-9/_-]+$ ]]; then
    die "路径只能包含字母、数字、斜杠、横线和下划线。"
  fi
  AUTH_PATH="/${p}"
}

get_auth_path() {
  if [[ -f "${ETC_DIR}/auth_path" ]]; then
    cat "${ETC_DIR}/auth_path"
  else
    printf '%s' "${AUTH_PATH}"
  fi
}

write_auth_path_file() {
  install -d -m 700 "${ETC_DIR}"
  printf '%s\n' "${AUTH_PATH}" > "${ETC_DIR}/auth_path"
  chown root:root "${ETC_DIR}/auth_path"
  chmod 600 "${ETC_DIR}/auth_path"
}

normalize_auth_port() {
  local p="$1"
  if [[ ! "${p}" =~ ^[0-9]+$ || "${p}" -lt 1 || "${p}" -gt 65535 ]]; then
    warn "端口必须为 1-65535 的数字。"
    return 1
  fi
  AUTH_PORT="${p}"
}

get_auth_port() {
  if [[ -f "${ETC_DIR}/auth_port" ]]; then
    cat "${ETC_DIR}/auth_port"
  else
    printf '%s' "${AUTH_PORT}"
  fi
}

write_auth_port_file() {
  install -d -m 700 "${ETC_DIR}"
  printf '%s\n' "${AUTH_PORT}" > "${ETC_DIR}/auth_port"
  chown root:root "${ETC_DIR}/auth_port"
  chmod 600 "${ETC_DIR}/auth_port"
}

change_credentials() {
  local new_user new_pass new_pass2 pwd_hash
  require_installed || die "Web auth firewall 尚未安装，无法修改登录凭据。"
  if [[ -z "${CLI_USER}" ]]; then
    read -r -p "请输入新的用户名: " new_user
  else
    new_user="${CLI_USER}"
  fi
  new_user="$(printf '%s' "${new_user}" | tr -d '\r\n')"
  if [[ -z "${new_user}" ]]; then
    die "用户名不能为空。"
  fi
  if [[ ! "${new_user}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    die "用户名只能包含字母、数字、点、横线和下划线。"
  fi
  if [[ -z "${CLI_PASSWORD}" ]]; then
    read -r -s -p "请输入新的密码: " new_pass
    echo ""
    read -r -s -p "请再次输入新的密码: " new_pass2
    echo ""
    if [[ "${new_pass}" != "${new_pass2}" ]]; then
      die "两次输入的密码不一致。"
    fi
  else
    new_pass="${CLI_PASSWORD}"
  fi
  if [[ ${#new_pass} -lt 8 ]]; then
    die "密码长度不能少于 8 个字符。"
  fi
  pwd_hash="$(printf '%s' "${new_pass}" | sha256sum | cut -d' ' -f1)"
  if command -v chattr >/dev/null 2>&1; then
    chattr -i "${CRED_FILE}" 2>/dev/null || true
    chattr -i "${INSTALL_DIR}/auth_server.py" 2>/dev/null || true
  fi
  printf '%s\n%s\n' "${new_user}" "${pwd_hash}" > "${CRED_FILE}"
  chown root:root "${CRED_FILE}"
  chmod 600 "${CRED_FILE}"
  python3 - "${CRED_FILE}" "${INSTALL_DIR}/auth_server.py" <<'PYEOF'
import re
import sys

cred_file, server_file = sys.argv[1], sys.argv[2]
with open(cred_file, "r", encoding="ascii") as fh:
    lines = [line.strip() for line in fh if line.strip()]
if len(lines) != 2:
    sys.exit("invalid credentials file")
username, pwd_hash = lines[0], lines[1]
with open(server_file, "r", encoding="utf-8") as fh:
    content = fh.read()
content = re.sub(r'^EXPECTED_USER = ".*"$', 'EXPECTED_USER = "%s"' % username, content, flags=re.M)
content = re.sub(r'^EXPECTED_PASSWORD_HASH = ".*"$', 'EXPECTED_PASSWORD_HASH = "%s"' % pwd_hash, content, flags=re.M)
with open(server_file, "w", encoding="utf-8") as fh:
    fh.write(content)
PYEOF
  chmod 700 "${INSTALL_DIR}/auth_server.py"
  if command -v chattr >/dev/null 2>&1; then
    chattr +i "${CRED_FILE}" 2>/dev/null || true
    chattr +i "${INSTALL_DIR}/auth_server.py" 2>/dev/null || true
  fi
  systemctl restart "${SERVICE}" >/dev/null 2>&1 || true
  say "登录凭据已更新。"
  say "新用户名: ${new_user}"
  say "新密码: 已设置（不在终端回显）"
}

show_credentials() {
  require_installed || return 1
  local user hash default_hash
  if [[ ! -f "${CRED_FILE}" ]]; then
    warn "未找到凭据文件：${CRED_FILE}"
    return 1
  fi
  user="$(sed -n '1p' "${CRED_FILE}")"
  hash="$(sed -n '2p' "${CRED_FILE}")"
  default_hash="$(printf '%s' "${AUTH_PASSWORD}" | sha256sum | cut -d' ' -f1)"
  echo "================ 当前登录凭据 ================"
  echo "  登录用户名 : ${user:-（空）}"
  if [[ -z "${hash}" ]]; then
    echo "  登录密码   : 未知（凭据文件中没有密码哈希）"
  elif [[ "${hash}" == "${default_hash}" ]]; then
    echo "  登录密码   : ${AUTH_PASSWORD}（当前为默认密码）"
  else
    echo "  登录密码   : 已修改（非默认密码；出于安全只保存 SHA-256，无法显示明文）"
  fi
  echo "  密码哈希   : ${hash:-（无）}"
  echo "  登录地址   : $(format_login_url "$(get_server_ip)")"
  echo "=============================================="
}

custom_auth_path() {
  local new_path
  require_installed || return 1
  echo "当前登录路径: $(get_auth_path)"
  echo "当前登录地址: $(format_login_url "$(get_server_ip)")"
  echo ""
  read -r -p "输入新的自定义路径（如 /sdfcxsd；输入 random 自动生成；输入 / 恢复根路径）: " new_path
  if [[ -z "${new_path}" ]]; then
    warn "路径不能为空，未修改。"
    return 1
  fi
  if [[ "${new_path}" == "random" ]]; then
    new_path="/$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 12)"
  fi
  normalize_auth_path "${new_path}"
  write_auth_path_file
  write_systemd_unit
  systemctl daemon-reload
  systemctl restart "${SERVICE}" >/dev/null 2>&1 || true
  say "登录路径已更新。"
  say "新登录地址: $(format_login_url "$(get_server_ip)")"
}

custom_auth_port() {
  local new_port
  require_installed || return 1
  echo "当前认证端口: $(get_auth_port)"
  echo "当前登录地址: $(format_login_url "$(get_server_ip)")"
  echo ""
  read -r -p "输入新的认证端口（1-65535）: " new_port
  normalize_auth_port "${new_port}" || return 1
  write_auth_port_file
  write_nft_conf
  write_systemd_unit
  systemctl daemon-reload
  nft -f "${NFT_CONF}"
  systemctl restart "${SERVICE}" >/dev/null 2>&1 || true
  say "认证端口已更新。"
  say "新登录地址: $(format_login_url "$(get_server_ip)")"
}

update_geoip() {
  require_installed || return 1
  warn "正在部署最新 GeoIP 工具..."
  write_geoip_scripts
  say "Updating GeoIP database (about 84MB, may take a few minutes)..."
  python3 "${INSTALL_DIR}/geoip_update.py" || die "GeoIP 数据库更新失败。"
  chmod 644 "${ETC_DIR}/geoip.dat"
  say "GeoIP 数据库更新完成。"
  systemctl restart "${SERVICE}" >/dev/null 2>&1 \
    || warn "GeoIP 更新完成，但认证服务重启失败，请手动执行：systemctl restart ${SERVICE}"
  say "认证服务已重启，新的 GeoIP 数据已生效。"
}

manage_whitelist() {
  local action ip
  require_installed || return 1
  while true; do
    clear 2>/dev/null || true
    echo "============== 手动管理白名单 =============="
    echo "当前白名单 IP："
    python3 "${INSTALL_DIR}/manage.py" list whitelist
    echo ""
    echo "  a) 添加 IP 到白名单"
    echo "  d) 从白名单删除 IP"
    echo "  q) 返回上级菜单"
    read -r -p "请选择 [a/d/q]: " action
    case "${action}" in
      a|A)
        read -r -p "请输入要加入白名单的 IP: " ip
        python3 "${INSTALL_DIR}/manage.py" add whitelist "${ip}"
        ;;
      d|D)
        read -r -p "请输入要从白名单删除的 IP: " ip
        python3 "${INSTALL_DIR}/manage.py" remove whitelist "${ip}"
        ;;
      q|Q|0)
        return 0
        ;;
      *) warn "无效选项，请重新输入。" ;;
    esac
  done
}

manage_blacklist() {
  local action ip
  require_installed || return 1
  while true; do
    clear 2>/dev/null || true
    echo "============== 手动管理黑名单 =============="
    echo "当前黑名单 IP："
    python3 "${INSTALL_DIR}/manage.py" list blacklist
    echo ""
    echo "  a) 添加 IP 到黑名单"
    echo "  d) 从黑名单删除 IP"
    echo "  q) 返回上级菜单"
    read -r -p "请选择 [a/d/q]: " action
    case "${action}" in
      a|A)
        read -r -p "请输入要加入黑名单的 IP: " ip
        python3 "${INSTALL_DIR}/manage.py" add blacklist "${ip}"
        ;;
      d|D)
        read -r -p "请输入要从黑名单删除的 IP: " ip
        python3 "${INSTALL_DIR}/manage.py" remove blacklist "${ip}"
        ;;
      q|Q|0)
        return 0
        ;;
      *) warn "无效选项，请重新输入。" ;;
    esac
  done
}

show_menu() {
  local server_ip
  server_ip="$(get_server_ip)"
  clear 2>/dev/null || true
  echo "====================================================="
  echo "        Web Authentication Firewall v${VERSION} 管理面板"
  echo "====================================================="
  echo "  登录地址: $(format_login_url "${server_ip}")"
  echo "====================================================="
  echo "  1) 安装 / 更新 Web 认证防火墙"
  echo "  2) 显示白名单 IP"
  echo "  3) 显示黑名单 IP"
  echo "  4) 手动管理白名单（添加 / 删除）"
  echo "  5) 手动管理黑名单（添加 / 删除）"
  echo "  6) 重置 / 修改用户名和密码"
  echo "  7) 显示当前登录账户 / 密码状态"
  echo "  8) 查看服务状态与防火墙规则"
  echo "  9) 卸载 Web 认证防火墙"
  echo " 10) 自定义登录地址"
  echo " 11) 自定义服务端口"
  echo " 12) 更新 GeoIP 数据库"
  echo "  0) 退出"
  echo "====================================================="
}

menu() {
  local choice ip
  while true; do
    show_menu
    read -r -p "请选择操作 [0-12]: " choice
    case "${choice}" in
      1) install_web_auth ;;
      2) if require_installed; then python3 "${INSTALL_DIR}/manage.py" list whitelist; fi ;;
      3) if require_installed; then python3 "${INSTALL_DIR}/manage.py" list blacklist; fi ;;
      4) manage_whitelist ;;
      5) manage_blacklist ;;
      6) change_credentials ;;
      7) show_credentials ;;
      8) if require_installed; then systemctl status "${SERVICE}" --no-pager || true; echo ""; nft list table inet "${NFT_TABLE}" || true; fi ;;
      9) read -r -p "确定要卸载吗？输入 yes 确认: " confirm; if [[ "${confirm}" == "yes" ]]; then uninstall; fi ;;
      10) custom_auth_path ;;
      11) custom_auth_port ;;
      12) update_geoip ;;
      0|q|Q) say "退出管理面板。"; exit 0 ;;
      *) warn "无效选项，请重新输入。" ;;
    esac
    if [[ "${choice}" != "0" && "${choice}" != "q" && "${choice}" != "Q" ]]; then
      pause
    fi
  done
}

install_web_auth() {
  ensure_tools
  backup_existing_ruleset
  save_pre_install_state
  stop_conflicting_firewalls
  install -d -m 755 "${INSTALL_DIR}"
  write_credentials
  write_auth_path_file
  write_auth_port_file
  write_auth_server
  write_manage_script
  write_geoip_scripts
  write_nft_conf
  write_systemd_unit
  write_state_file
  seed_ssh_ip
  apply_firewall
  start_service
  print_summary
}

main() {
  require_root
  parse_args "$@"
  case "${ACTION}" in
    install) install_web_auth; exit 0 ;;
    uninstall) uninstall; exit 0 ;;
    change_credentials) change_credentials; exit 0 ;;
    update_geoip) update_geoip; exit 0 ;;
    *) menu ;;
  esac
}

main "$@"
