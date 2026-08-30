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
set -Eeuo pipefail

VERSION="1.0.0"

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
    apt) pkgs=(nftables python3) ;;
    dnf|yum) pkgs=(nftables python3) ;;
    zypper) pkgs=(nftables python3) ;;
    pacman) pkgs=(nftables python) ;;
    apk) pkgs=(nftables python3) ;;
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

AUTH_PORT = int(os.environ.get("AUTH_PORT", "18622"))
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

# Immutable defaults. The service refuses to start if the on-disk
# credentials file does not match these exact values.
EXPECTED_USER = "admin"
EXPECTED_PASSWORD_HASH = "b03ddf3ca2e714a6548e7495e2a03f5e824eaac9837cd7f159c67b90fb4b7342"

# Whitelist and blacklist entries are kept for 48 hours and then removed.
WHITELIST_TTL_SECONDS = 48 * 60 * 60
BLACKLIST_TTL_SECONDS = 48 * 60 * 60

# A client is blacklisted after 3 failed logins within 5 minutes.
FAIL_WINDOW_SECONDS = 5 * 60
MAX_FAILED_ATTEMPTS = 3
FAILED_ATTEMPTS = {}
FAIL_LOCK = threading.RLock()

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


def grant_access(ip, family):
    with STATE_LOCK:
        if ip in STATE["blacklist"][family]:
            del STATE["blacklist"][family][ip]
            nft_ok("delete", "element", "inet", NFT_TABLE, set_name("blacklist", family), "{", ip, "}")
        STATE["whitelist"][family][ip] = time.time() + WHITELIST_TTL_SECONDS
        nft_ok("add", "element", "inet", NFT_TABLE, set_name("whitelist", family), "{", ip, "}")
        save_state(STATE)
        LOG.info(
            "granted access to %s (family %s) for %d seconds",
            ip, family, WHITELIST_TTL_SECONDS,
        )


def revoke_access(ip, family):
    with STATE_LOCK:
        if ip in STATE["whitelist"][family]:
            del STATE["whitelist"][family][ip]
            nft_ok("delete", "element", "inet", NFT_TABLE, set_name("whitelist", family), "{", ip, "}")
        STATE["blacklist"][family][ip] = time.time() + BLACKLIST_TTL_SECONDS
        nft_ok("add", "element", "inet", NFT_TABLE, set_name("blacklist", family), "{", ip, "}")
        save_state(STATE)
        LOG.warning(
            "revoked access from %s (family %s) for %d seconds",
            ip, family, BLACKLIST_TTL_SECONDS,
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


def port_badges(ports):
    if not ports:
        return '<span class="port">无</span>'
    return "".join('<span class="port">%d</span>' % port for port in ports)


def render_list_rows(kind):
    rows = []
    action = "remove_whitelist" if kind == "whitelist" else "remove_blacklist"
    for family in FAMILIES:
        family_label = "IPv4" if family == "4" else "IPv6"
        for ip in STATE[kind][family]:
            safe_ip = escape(ip)
            rows.append(
                '<div class="iprow">'
                '<span class="ipaddr">%s</span>'
                '<span class="family">%s</span>'
                '<form method="post" action="%s">'
                '<input type="hidden" name="action" value="%s">'
                '<input type="hidden" name="ip" value="%s">'
                '<button type="submit" class="small danger">删除</button>'
                "</form>"
                "</div>" % (safe_ip, family_label, MANAGE_ACTION, action, safe_ip)
            )
    if not rows:
        return '<div class="empty">无</div>'
    return "".join(rows)


def render_success_page(client_ip, message=""):
    tcp_ports = collect_tcp_ports()
    udp_ports = collect_udp_ports()
    msg_html = ""
    if message:
        msg_html = '<div class="msg">%s</div>' % escape(message)
    return (
        SUCCESS_PAGE
        .replace("__CLIENT_IP__", escape(client_ip))
        .replace("__TCP_PORTS__", port_badges(tcp_ports))
        .replace("__UDP_PORTS__", port_badges(udp_ports))
        .replace("__WHITELIST_ROWS__", render_list_rows("whitelist"))
        .replace("__BLACKLIST_ROWS__", render_list_rows("blacklist"))
        .replace("__MANAGE_MESSAGE__", msg_html)
        .replace("__MANAGE_ACTION__", MANAGE_ACTION)
        .replace("__LOGOUT_ACTION__", LOGOUT_ACTION)
    )


def render_failure_page(message):
    return FAILURE_PAGE.replace("__FAIL_MESSAGE__", escape(message))


def render_login_page(logout=False):
    notice = ""
    if logout:
        notice = '<div class="notice">您已退出登录，IP 仍保留在白名单中，可重新登录其它账号。</div>'
    return LOGIN_PAGE.replace("__LOGIN_NOTICE__", notice).replace("__AUTH_ACTION__", LOGIN_ACTION)


LOGIN_PAGE = """<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Server Access Authorization</title>
<style>
* { box-sizing: border-box; }
body { margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
       background: #f1f5f9; font-family: "Segoe UI", system-ui, -apple-system, "Microsoft YaHei", sans-serif; color: #0f172a; }
.card { width: min(92vw, 380px); background: #ffffff; border: 1px solid #cbd5e1; border-radius: 8px;
        padding: 32px 28px; box-shadow: 0 10px 30px rgba(15, 23, 42, .08); }
h1 { font-size: 20px; margin: 0 0 6px; }
p { color: #475569; font-size: 13px; margin: 0 0 20px; }
label { display: block; font-size: 13px; font-weight: 600; margin: 14px 0 6px; }
input { width: 100%; height: 40px; padding: 0 10px; border: 1px solid #94a3b8; border-radius: 6px; font-size: 14px; }
button { width: 100%; height: 42px; margin-top: 20px; border: 0; border-radius: 6px;
         background: #0f766e; color: #ffffff; font-size: 14px; font-weight: 600; cursor: pointer; }
button:hover { background: #115e59; }
.notice { margin-bottom: 16px; padding: 10px 12px; border-radius: 6px; font-size: 13px;
          background: #f0fdf4; color: #166534; border: 1px solid #a7f3d0; }
.muted { margin-top: 18px; text-align: center; color: #64748b; }
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
       background: #f1f5f9; font-family: "Segoe UI", system-ui, -apple-system, "Microsoft YaHei", sans-serif; color: #0f172a; padding: 24px; }
.card { width: min(94vw, 780px); background: #ffffff; border: 1px solid #cbd5e1; border-radius: 8px;
        padding: 32px 28px; box-shadow: 0 10px 30px rgba(15, 23, 42, .08); }
.topbar { display: flex; justify-content: flex-end; margin-bottom: 10px; }
.logoutbtn { display: inline-block; padding: 7px 14px; border-radius: 6px; font-size: 13px;
             text-decoration: none; background: #f1f5f9; color: #334155; border: 1px solid #cbd5e1; }
.logoutbtn:hover { background: #e2e8f0; }
h1 { font-size: 20px; margin: 0 0 4px; color: #047857; }
.subtitle { color: #475569; font-size: 13px; margin: 0 0 20px; }
.ipbox { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap;
         background: #ecfdf5; border: 1px solid #a7f3d0; border-radius: 8px; padding: 12px 14px; margin-bottom: 20px; }
.ipbox .label { font-size: 12px; color: #065f46; }
.ipbox .value { font-family: Consolas, monospace; font-size: 16px; font-weight: 700; color: #065f46; }
.ports { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }
.section { border: 1px solid #e2e8f0; border-radius: 8px; padding: 14px; }
.section h2 { font-size: 13px; margin: 0 0 10px; }
.section .tag { display: inline-block; font-size: 11px; font-weight: 700; border-radius: 4px; padding: 2px 6px; margin-right: 6px; }
.tcp .tag { background: #dbeafe; color: #1d4ed8; }
.udp .tag { background: #fef3c7; color: #92400e; }
.portlist { display: flex; flex-wrap: wrap; gap: 6px; }
.port { background: #f8fafc; border: 1px solid #e2e8f0; border-radius: 4px; padding: 3px 7px;
        font-family: Consolas, monospace; font-size: 12px; }
.manage { margin-top: 22px; border-top: 1px solid #e2e8f0; padding-top: 16px; }
.manage > h2 { font-size: 15px; margin: 0 0 12px; color: #0f172a; }
.manage-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }
.listbox { border: 1px solid #e2e8f0; border-radius: 8px; padding: 12px; }
.listbox h3 { font-size: 12px; margin: 0 0 8px; color: #334155; }
.iprow { display: flex; align-items: center; gap: 8px; padding: 6px 0; border-bottom: 1px dashed #e2e8f0; }
.iprow:last-child { border-bottom: 0; }
.ipaddr { font-family: Consolas, monospace; font-size: 12px; flex: 1; overflow-wrap: anywhere; }
.family { font-size: 10px; color: #64748b; }
.empty { color: #94a3b8; font-size: 12px; padding: 4px 0; }
button.small { height: 26px; padding: 0 10px; font-size: 12px; border: 0; border-radius: 5px; cursor: pointer; }
button.danger { background: #fee2e2; color: #b91c1c; }
button.add { background: #0f766e; color: #ffffff; }
.addforms { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin-top: 14px; }
.addform { display: flex; gap: 8px; }
.addform input { flex: 1; min-width: 0; height: 36px; padding: 0 10px; border: 1px solid #94a3b8; border-radius: 6px; font-size: 13px; }
.addform button { flex-shrink: 0; height: 36px; }
.msg { margin-top: 14px; padding: 10px 12px; border-radius: 6px; font-size: 13px; background: #f0fdf4; color: #166534; }
.note { margin-top: 10px; font-size: 11px; color: #94a3b8; }
.muted { margin-top: 18px; text-align: center; color: #64748b; font-size: 12px; }
@media (max-width: 640px) { .ports, .manage-grid, .addforms { grid-template-columns: 1fr; } }
</style>
</head>
<body>
<div class="card">
  <div class="topbar"><a class="logoutbtn" href="__LOGOUT_ACTION__">退出登录 / Log Out</a></div>
  <h1>登录成功 / Login Successful</h1>
  <p class="subtitle">您的 IP 已加入白名单，现在可以访问服务器全部端口和服务。</p>
  <div class="ipbox">
    <span class="label">您的客户端 IP（已加入白名单）</span>
    <span class="value">__CLIENT_IP__</span>
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
        <h3>白名单 IP（48 小时有效）</h3>
        __WHITELIST_ROWS__
      </div>
      <div class="listbox">
        <h3>黑名单 IP（48 小时有效）</h3>
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
    <p class="note">删除自己的 IP 后将立即失去服务器访问权限。</p>
  </div>
  <p class="muted">白名单有效期 48 小时，到期后需重新登录。Your IP address has been whitelisted.</p>
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
       background: #fef2f2; font-family: "Segoe UI", system-ui, -apple-system, "Microsoft YaHei", sans-serif; color: #0f172a; }
.card { width: min(92vw, 420px); background: #ffffff; border: 1px solid #fecaca; border-radius: 8px;
        padding: 32px 28px; box-shadow: 0 10px 30px rgba(15, 23, 42, .08); text-align: center; }
h1 { font-size: 20px; margin: 0 0 10px; color: #b91c1c; }
p { color: #334155; font-size: 14px; margin: 0 0 16px; }
a { color: #0f766e; }
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
       background: #fef2f2; font-family: "Segoe UI", system-ui, -apple-system, "Microsoft YaHei", sans-serif; color: #0f172a; }
.card { width: min(92vw, 420px); background: #ffffff; border: 1px solid #fecaca; border-radius: 8px;
        padding: 32px 28px; box-shadow: 0 10px 30px rgba(15, 23, 42, .08); text-align: center; }
h1 { font-size: 20px; margin: 0 0 10px; color: #b91c1c; }
p { color: #334155; font-size: 14px; margin: 0; }
.muted { margin-top: 18px; color: #64748b; font-size: 12px; }
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
    server_version = "WebAuthFirewall/1.0"

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
                message = "您已连续 3 次登录失败，IP 已被加入黑名单（48 小时有效），服务器所有端口（包括认证端口）将拒绝访问；请联系管理员解除或等待自动过期。"
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
        raw_ip = params.get("ip", [""])[0]
        target, target_family = normalize_ip(raw_ip)
        if target is None:
            self._send_html(200, render_success_page(ip, message="无效的 IP 地址"))
            return
        if action == "add_whitelist":
            grant_access(target, target_family)
            message = "已将 %s 加入白名单，有效期 48 小时。" % target
        elif action == "remove_whitelist":
            if remove_from_whitelist(target, target_family):
                message = "已将 %s 从白名单移除。" % target
            else:
                message = "%s 不在白名单中。" % target
        elif action == "add_blacklist":
            revoke_access(target, target_family)
            message = "已将 %s 加入黑名单。" % target
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
        time.sleep(60)
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

    if action == "add":
        if kind == "whitelist":
            auth.grant_access(ip, family)
        else:
            auth.revoke_access(ip, family)
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
  systemctl disable --now nftables >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${SERVICE}.service"
  systemctl daemon-reload

  if command -v chattr >/dev/null 2>&1; then
    chattr -i "${CRED_FILE}" 2>/dev/null || true
    chattr -i "${INSTALL_DIR}/auth_server.py" 2>/dev/null || true
    chattr -i "${INSTALL_DIR}/manage.py" 2>/dev/null || true
  fi
  rm -rf "${INSTALL_DIR}" "${ETC_DIR}" "${STATE_DIR}"
  rm -f "${NFT_CONF}"
  if [[ -f "${NFT_BACKUP}" ]]; then
    mv "${NFT_BACKUP}" "${NFT_CONF}"
    say "Restored previous nftables ruleset."
    if command -v nft >/dev/null 2>&1; then
      nft -f "${NFT_CONF}" || warn "Could not reload the restored ruleset."
    fi
  fi
  say "Uninstall complete."
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
  local ip="$1" host path
  path="$(get_auth_path)"
  if [[ -n "${ip}" && "${ip}" == *:* ]]; then
    host="[${ip}]"
  else
    host="${ip}"
  fi
  printf 'http://%s:%s%s' "${host}" "${AUTH_PORT}" "${path}"
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
  echo "        Web Authentication Firewall 管理面板"
  echo "====================================================="
  echo "  登录地址: $(format_login_url "${server_ip}")"
  echo "====================================================="
  echo "  1) 安装 / 更新 Web 认证防火墙"
  echo "  2) 显示白名单 IP"
  echo "  3) 显示黑名单 IP"
  echo "  4) 手动管理白名单（添加 / 删除）"
  echo "  5) 手动管理黑名单（添加 / 删除）"
  echo "  6) 重置 / 修改用户名和密码"
  echo "  7) 查看服务状态与防火墙规则"
  echo "  8) 卸载 Web 认证防火墙"
  echo "  9) 自定义登录地址"
  echo "  0) 退出"
  echo "====================================================="
}

menu() {
  local choice ip
  while true; do
    show_menu
    read -r -p "请选择操作 [0-9]: " choice
    case "${choice}" in
      1) install_web_auth ;;
      2) if require_installed; then python3 "${INSTALL_DIR}/manage.py" list whitelist; fi ;;
      3) if require_installed; then python3 "${INSTALL_DIR}/manage.py" list blacklist; fi ;;
      4) manage_whitelist ;;
      5) manage_blacklist ;;
      6) change_credentials ;;
      7) if require_installed; then systemctl status "${SERVICE}" --no-pager || true; echo ""; nft list table inet "${NFT_TABLE}" || true; fi ;;
      8) read -r -p "确定要卸载吗？输入 yes 确认: " confirm; if [[ "${confirm}" == "yes" ]]; then uninstall; fi ;;
      9) custom_auth_path ;;
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
  stop_conflicting_firewalls
  install -d -m 755 "${INSTALL_DIR}"
  write_credentials
  write_auth_path_file
  write_auth_server
  write_manage_script
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
    *) menu ;;
  esac
}

main "$@"
