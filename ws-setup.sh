#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  🌐🔒  ws-setup  —  Autoscript WebSocket VPN Installer
#  Xray Core · VLESS-WS · VMess-WS · VLESS-gRPC · SSH-WS · Nginx TLS
#  krainium
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ─── Colours ──────────────────────────────────────────────────────────────────
R="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"
RED="\033[31m"
GRN="\033[32m"
YLW="\033[33m"
BLU="\033[34m"
MAG="\033[35m"
CYN="\033[36m"
WHT="\033[97m"
PUR="\033[38;5;135m"
ORG="\033[38;5;208m"

# ─── Logging helpers ──────────────────────────────────────────────────────────
info()       { echo -e "${BLU}${BOLD}  ℹ  ${R}${WHT}$*${R}"; }
ok()         { echo -e "${GRN}${BOLD}  ✔  ${R}${GRN}$*${R}"; }
skip()       { echo -e "${CYN}${BOLD}  ↷  ${R}${CYN}$*  — already done, skipping${R}"; }
warn()       { echo -e "${YLW}${BOLD}  ⚠  ${R}${YLW}$*${R}"; }
err()        { echo -e "${RED}${BOLD}  ✖  ${R}${RED}$*${R}"; }
step()       { echo -e "\n${CYN}${BOLD}  ▶  $*${R}"; }
divider()    { echo -e "${DIM}  ──────────────────────────────────────────────────${R}"; }
installing() { echo -e "${MAG}${BOLD}  ⬇  ${R}${MAG}Installing $*...${R}"; }
proto()      { echo -e "${PUR}${BOLD}  🔧  ${R}${PUR}$*${R}"; }
link_line()  { echo -e "${ORG}${BOLD}  🔗  ${R}${WHT}$*${R}"; }

# ─── Root check ───────────────────────────────────────────────────────────────
require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        err "This action requires root. Re-run with: sudo $0"
        exit 1
    fi
}

# ─── OS + package manager detection ──────────────────────────────────────────
detect_os() {
    OS="unknown"; PKG=""; PKG_UPDATE=""; PKG_INSTALL=""; SVC_CMD=""
    [[ -f /etc/os-release ]] && { source /etc/os-release; OS="${ID:-unknown}"; }

    if   command -v apt-get &>/dev/null; then
        PKG="apt"; PKG_UPDATE="apt-get update -qq"
        PKG_INSTALL="DEBIAN_FRONTEND=noninteractive apt-get install -y -qq"
    elif command -v dnf &>/dev/null; then
        PKG="dnf"; PKG_UPDATE="dnf check-update -q || true"
        PKG_INSTALL="dnf install -y -q"
    elif command -v yum &>/dev/null; then
        PKG="yum"; PKG_UPDATE="yum check-update -q || true"
        PKG_INSTALL="yum install -y -q"
    elif command -v pacman &>/dev/null; then
        PKG="pacman"; PKG_UPDATE="pacman -Sy --noconfirm --quiet"
        PKG_INSTALL="pacman -S --noconfirm --quiet"
    else
        PKG="unknown"
    fi

    command -v systemctl &>/dev/null && SVC_CMD="systemctl" || SVC_CMD="service"
}

pkg_install() {
    [[ -z "$PKG_UPDATE" ]] && { warn "No package manager found — install $* manually"; return 1; }
    eval "$PKG_UPDATE" &>/dev/null || true
    eval "$PKG_INSTALL $*"
}

svc() {   # svc enable|start|restart|stop|is-active <name>
    local action="$1" name="$2"
    if [[ "$SVC_CMD" == "systemctl" ]]; then
        systemctl "$action" "$name" &>/dev/null || true
    else
        service "$name" "$action" &>/dev/null || true
    fi
}

# Like svc() but prints ok/warn and shows journal tail on failure — use for restarts
svc_or_warn() {   # svc_or_warn <action> <name> <label>
    local action="$1" name="$2" label="${3:-$2}"
    if [[ "$SVC_CMD" != "systemctl" ]]; then
        svc "$action" "$name"; return   # non-systemd: silent fallback same as before
    fi
    if systemctl "$action" "$name" 2>/dev/null; then
        ok "${label} ${action}ed"
    else
        warn "${label} failed to ${action} — check logs below:"
        systemctl status "$name" --no-pager -l 2>/dev/null | head -20 || true
        echo -e "  ${DIM}Run:  journalctl -u ${name} -n 50 --no-pager${R}"
    fi
}

# ─── State persistence ────────────────────────────────────────────────────────
STATE_DIR="/etc/xray-ws-setup"
STATE_FILE="${STATE_DIR}/state.conf"
OUT_DIR="/root/xray-ws-setup"

save_state() {
    mkdir -p "$STATE_DIR" "$OUT_DIR"
    chmod 700 "$STATE_DIR"
    cat > "$STATE_FILE" <<EOF
DOMAIN="${DOMAIN:-}"
WS_PATH="${WS_PATH:-/vless-ws}"
VMESS_PATH="${VMESS_PATH:-/vmess-ws}"
GRPC_SVC="${GRPC_SVC:-xray-grpc}"
UUID="${UUID:-}"
VMESS_UUID="${VMESS_UUID:-}"
CERT_FILE="${CERT_FILE:-}"
KEY_FILE="${KEY_FILE:-}"
XRAY_PORT_VLESS="${XRAY_PORT_VLESS:-10000}"
XRAY_PORT_VMESS="${XRAY_PORT_VMESS:-10001}"
XRAY_PORT_GRPC="${XRAY_PORT_GRPC:-10002}"
SSH_WS_PORT="${SSH_WS_PORT:-9022}"
VLESS_ENABLED="${VLESS_ENABLED:-0}"
VMESS_ENABLED="${VMESS_ENABLED:-0}"
GRPC_ENABLED="${GRPC_ENABLED:-0}"
SSH_WS_ENABLED="${SSH_WS_ENABLED:-0}"
EOF
    chmod 600 "$STATE_FILE"
}

load_state() {
    DOMAIN=""; WS_PATH="/vless-ws"; VMESS_PATH="/vmess-ws"; GRPC_SVC="xray-grpc"
    UUID=""; VMESS_UUID=""; CERT_FILE=""; KEY_FILE=""
    XRAY_PORT_VLESS=10000; XRAY_PORT_VMESS=10001; XRAY_PORT_GRPC=10002
    SSH_WS_PORT=9022  # internal websockify port — nginx listens externally on 80/443/2086/2087
    VLESS_ENABLED=0; VMESS_ENABLED=0; GRPC_ENABLED=0; SSH_WS_ENABLED=0
    [[ -f "$STATE_FILE" ]] && source "$STATE_FILE" || true
}

# ─── UUID generation ──────────────────────────────────────────────────────────
gen_uuid() {
    if   command -v uuidgen &>/dev/null; then uuidgen | tr '[:upper:]' '[:lower:]'
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid
    else
        python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null || \
        printf '%08x-%04x-%04x-%04x-%012x\n' \
            $RANDOM $RANDOM $RANDOM $RANDOM $((RANDOM*RANDOM))
    fi
}

# ─── Architecture detection ───────────────────────────────────────────────────
xray_arch() {
    case "$(uname -m)" in
        x86_64|amd64)       echo "64" ;;
        aarch64|arm64)      echo "arm64-v8a" ;;
        armv7l|armv7)       echo "arm32-v7a" ;;
        s390x)              echo "s390x" ;;
        *)                  echo "64" ;;
    esac
}

# ─── Domain prompt + validation ───────────────────────────────────────────────
prompt_domain() {
    while true; do
        echo -en "${CYN}${BOLD}  ➤  ${R}${WHT}Your domain (e.g. sub.example.com): ${R}"
        read -r DOMAIN
        DOMAIN="${DOMAIN// /}"
        if [[ -z "$DOMAIN" ]]; then err "Domain cannot be empty."; continue; fi
        if echo "$DOMAIN" | grep -qE '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'; then break; fi
        err "Invalid domain. Use a valid hostname (no http://, no trailing dot)."
    done
}

prompt_ws_path() {
    echo -en "${CYN}${BOLD}  ➤  ${R}${WHT}VLESS WebSocket path [default: /vless-ws]: ${R}"
    read -r _inp; _inp="${_inp// /}"
    [[ -z "$_inp" ]] && _inp="/vless-ws"
    [[ "${_inp:0:1}" != "/" ]] && _inp="/$_inp"
    WS_PATH="$_inp"
}

prompt_vmess_path() {
    echo -en "${CYN}${BOLD}  ➤  ${R}${WHT}VMess WebSocket path [default: /vmess-ws]: ${R}"
    read -r _inp; _inp="${_inp// /}"
    [[ -z "$_inp" ]] && _inp="/vmess-ws"
    [[ "${_inp:0:1}" != "/" ]] && _inp="/$_inp"
    VMESS_PATH="$_inp"
}

# ─── Banner ───────────────────────────────────────────────────────────────────
banner() {
    clear 2>/dev/null || true
    echo -e "${PUR}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║  🌐🔒  ws-setup   WebSocket VPN Installer              ║"
    echo "  ║  🟣 VLESS  🔵 VMess  📡 gRPC  🔑 SSH-WS  🛡️ TLS       ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo -e "${R}"
    load_state
    if [[ -n "$DOMAIN" ]]; then
        echo -e "  ${DIM}Domain : ${WHT}${BOLD}${DOMAIN}${R}"
        [[ -n "$UUID" ]]       && echo -e "  ${DIM}UUID   : ${WHT}${UUID}${R}"
        echo ""
    fi
}

# ─── Menu ─────────────────────────────────────────────────────────────────────
print_menu() {
    local vless_tag="" vmess_tag="" grpc_tag="" ssh_tag=""
    [[ "$VLESS_ENABLED"  == "1" ]] && vless_tag="${GRN}✔${R}"  || vless_tag="${DIM}○${R}"
    [[ "$VMESS_ENABLED"  == "1" ]] && vmess_tag="${GRN}✔${R}"  || vmess_tag="${DIM}○${R}"
    [[ "$GRPC_ENABLED"   == "1" ]] && grpc_tag="${GRN}✔${R}"   || grpc_tag="${DIM}○${R}"
    [[ "$SSH_WS_ENABLED" == "1" ]] && ssh_tag="${GRN}✔${R}"    || ssh_tag="${DIM}○${R}"

    echo -e "${CYN}${BOLD}  ┌─ Install ─────────────────────────────────────────────┐${R}"
    echo -e "  ${WHT}  1${R}  🚀  Install All-in-One   ${DIM}(Xray+Nginx+TLS+all protocols)${R}"
    echo -e "  ${WHT}  2${R}  ⬇   Install Xray Core"
    echo -e "  ${WHT}  3${R}  🌐  Install & Configure Nginx"
    echo -e "  ${WHT}  4${R}  🔒  Issue SSL/TLS Certificate   ${DIM}(certbot → acme.sh → self-signed)${R}"
    echo -e "${CYN}${BOLD}  ├─ Protocols ───────────────────────────────────────────┤${R}"
    echo -e "  ${WHT}  5${R}  🟣  Configure VLESS + WebSocket   ${vless_tag}"
    echo -e "  ${WHT}  6${R}  🔵  Configure VMess + WebSocket   ${vmess_tag}"
    echo -e "  ${WHT}  7${R}  📡  Configure VLESS + gRPC        ${grpc_tag}"
    echo -e "  ${WHT}  8${R}  🔑  Configure SSH over WebSocket  ${ssh_tag}"
    echo -e "${CYN}${BOLD}  ├─ Manage ──────────────────────────────────────────────┤${R}"
    echo -e "  ${WHT}  9${R}  📋  Show Connection Links & Payloads"
    echo -e "  ${WHT} 10${R}  📊  Status Dashboard"
    echo -e "  ${WHT} 11${R}  🔄  Restart Xray + Nginx"
    echo -e "  ${WHT} 12${R}  🗑   Uninstall Everything"
    echo -e "${CYN}${BOLD}  └────────────────────────────────────────────────────────┘${R}"
    echo -e "  ${WHT}  0${R}  ❌  Exit"
    echo ""
    echo -en "${CYN}${BOLD}  Choice: ${R}"
}

# ─── 2 · Install Xray Core ────────────────────────────────────────────────────
install_xray() {
    require_root; detect_os
    step "Install Xray Core"

    if command -v xray &>/dev/null; then
        local ver; ver=$(xray version 2>&1 | head -1 | grep -o '[0-9][0-9.]*' | head -1 || echo "?")
        skip "Xray ${ver}"
    else
        installing "dependencies (curl, wget, unzip, jq)"
        pkg_install curl wget unzip jq &>/dev/null || true

        local arch; arch=$(xray_arch)
        local api_url="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
        local dl_url ver_tag

        info "Fetching latest Xray release..."
        # Get the version tag from the API; parse tag_name only (avoids grepping the whole JSON)
        ver_tag=$(curl -fsSL --max-time 15 "$api_url" 2>/dev/null \
            | grep '"tag_name"' | head -1 | cut -d '"' -f4) || true

        if [[ -n "$ver_tag" ]]; then
            # Construct the exact versioned URL — no redirect chain, no HTML surprises
            dl_url="https://github.com/XTLS/Xray-core/releases/download/${ver_tag}/Xray-linux-${arch}.zip"
            info "Latest release: ${ver_tag}"
        else
            warn "GitHub API unavailable — falling back to latest redirect"
            dl_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip"
        fi

        info "Downloading Xray-linux-${arch}.zip..."
        local tmp_zip="/tmp/xray_$$.zip" tmp_dir="/tmp/xray_$$"
        mkdir -p "$tmp_dir"

        curl -fSL --retry 3 --retry-delay 3 --max-time 120 \
            -H "User-Agent: Mozilla/5.0" \
            "$dl_url" -o "$tmp_zip" || {
            err "Download failed. Check your internet connection."
            rm -f "$tmp_zip"; rmdir "$tmp_dir" 2>/dev/null || true
            return 1
        }

        # Validate: a real zip starts with PK (bytes 50 4B) and must be > 1 MB
        local zip_size; zip_size=$(stat -c%s "$tmp_zip" 2>/dev/null || echo 0)
        local zip_magic; zip_magic=$(xxd -l2 -p "$tmp_zip" 2>/dev/null || od -A n -N 2 -t x1 "$tmp_zip" 2>/dev/null | tr -d ' \n' || echo "")
        if [[ "$zip_size" -lt 1048576 ]] || [[ "$zip_magic" != "504b"* ]]; then
            err "Downloaded file is not a valid zip (size: ${zip_size} bytes, magic: ${zip_magic})."
            err "This usually means GitHub returned an HTML page. Try again in a moment."
            rm -f "$tmp_zip"; rmdir "$tmp_dir" 2>/dev/null || true
            return 1
        fi

        unzip -oq "$tmp_zip" -d "$tmp_dir"
        install -m 755 "$tmp_dir/xray" /usr/local/bin/xray

        # Install geodata — Xray resolves geoip.dat/geosite.dat from the same
        # directory as its binary (/usr/local/bin/) unless XRAY_LOCATION_ASSET overrides it.
        # The release zip ships both files; copy them if present, otherwise download.
        for dat in geoip.dat geosite.dat; do
            if [[ -f "$tmp_dir/$dat" ]]; then
                install -m 644 "$tmp_dir/$dat" "/usr/local/bin/$dat"
            fi
        done

        # Fallback: download any dat file still missing
        local geo_base="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
        for dat in geoip.dat geosite.dat; do
            if [[ ! -f "/usr/local/bin/$dat" ]]; then
                info "Downloading ${dat} from Loyalsoldier/v2ray-rules-dat..."
                curl -fsSL --retry 3 --max-time 60 \
                    "${geo_base}/${dat}" -o "/usr/local/bin/${dat}" 2>/dev/null || \
                    warn "Could not download ${dat} — routing rules that reference it will fail"
            fi
        done

        rm -rf "$tmp_zip" "$tmp_dir"
        mkdir -p /usr/local/etc/xray /var/log/xray
        touch /var/log/xray/access.log /var/log/xray/error.log
        chmod 640 /var/log/xray/access.log /var/log/xray/error.log

        local ver; ver=$(xray version 2>&1 | head -1 | grep -o '[0-9][0-9.]*' | head -1 || echo "?")
        ok "Xray ${ver} installed at /usr/local/bin/xray"
    fi

    # systemd service
    if [[ ! -f /etc/systemd/system/xray.service ]]; then
        cat > /etc/systemd/system/xray.service <<'SYSD'
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls/xray-core
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SYSD
        systemctl daemon-reload &>/dev/null || true
        systemctl enable xray &>/dev/null || true
        ok "Xray systemd service created"
    fi

    # Bootstrap empty config if none exists
    if [[ ! -f /usr/local/etc/xray/config.json ]]; then
        echo '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom"}]}' \
            > /usr/local/etc/xray/config.json
    fi
}

# ─── 3 · Install Nginx ────────────────────────────────────────────────────────
install_nginx() {
    require_root; detect_os
    step "Install Nginx"

    if command -v nginx &>/dev/null; then
        local ver; ver=$(nginx -v 2>&1 | grep -o '[0-9][0-9.]*' | head -1 || echo "?")
        skip "Nginx ${ver}"
    else
        installing "Nginx"
        pkg_install nginx
        ok "Nginx installed"
    fi

    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    # Remove the default site — it conflicts on port 80 with our vhost and ACME challenge
    rm -f /etc/nginx/sites-enabled/default
    # Ensure sites-enabled included in nginx.conf
    if ! grep -q "sites-enabled" /etc/nginx/nginx.conf 2>/dev/null; then
        sed -i '/http {/a\\tinclude /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf || true
    fi

    # Evict anything holding port 80 (apache2, httpd, etc.) — nginx must own it exclusively
    free_port_80
    svc enable nginx
    svc_or_warn start nginx "Nginx"
}

# ─── 3b · UFW Firewall rules ──────────────────────────────────────────────────
configure_ufw() {
    require_root
    step "Configure UFW Firewall"

    # Install ufw if missing
    if ! command -v ufw &>/dev/null; then
        installing "ufw"
        pkg_install ufw &>/dev/null || { warn "ufw not available on this system — skip"; return 0; }
    fi

    info "Applying firewall rules..."

    # Always allow SSH first — never risk locking yourself out
    ufw allow 22/tcp  comment "SSH management"       &>/dev/null
    ok  "22/tcp  — SSH"

    # HTTP — required for Let's Encrypt ACME standalone challenge
    ufw allow 80/tcp  comment "HTTP / ACME challenge" &>/dev/null
    ok  "80/tcp  — HTTP (ACME challenge + redirect)"

    # HTTPS — direct TLS entry point for all VPN protocols
    ufw allow 443/tcp comment "HTTPS direct TLS (VLESS/VMess/gRPC/SSH-WS)" &>/dev/null
    ok  "443/tcp — HTTPS direct TLS"
    ufw allow 443/udp comment "QUIC / HTTP3"          &>/dev/null
    ok  "443/udp — QUIC / HTTP3"

    # Cloudflare CDN-compatible ports:
    #   2086/tcp — Cloudflare HTTP alt port (ws://)  → nginx port 80 proxy, direct non-TLS
    #   2087/tcp — Cloudflare HTTPS alt port (wss://) → nginx port 443 proxy with TLS
    # Both are proxied by Cloudflare CDN and must be open for direct connections too.
    ufw allow 2086/tcp comment "CF CDN HTTP ws:// alt port (non-TLS WebSocket)" &>/dev/null
    ok  "2086/tcp — Cloudflare HTTP WebSocket port"
    ufw allow 2087/tcp comment "CF CDN HTTPS wss:// alt port (TLS WebSocket)" &>/dev/null
    ok  "2087/tcp — Cloudflare HTTPS WebSocket port"

    # Internal-only ports — blocked externally (nginx proxies them on localhost):
    #   10000 (VLESS-WS), 10001 (VMess-WS), 10002 (gRPC), ${SSH_WS_PORT} (websockify)
    info "Internal backend ports (10000/10001/10002/websockify) remain firewalled — nginx proxies them"

    # Set sensible default policies
    ufw default deny incoming  &>/dev/null
    ufw default allow outgoing &>/dev/null

    # Enable (non-interactive — SSH rule already in place)
    if ufw status | grep -q "Status: active"; then
        ufw reload &>/dev/null
        ok "UFW reloaded"
    else
        echo "y" | ufw enable &>/dev/null
        ok "UFW enabled"
    fi

    echo ""
    ufw status verbose 2>/dev/null | grep -v "^$" | sed 's/^/    /'
}

# ─── Port-80 eviction (called before ACME challenge and before nginx start) ───
free_port_80() {
    info "Freeing port 80 for ACME challenge..."

    # Stop (and permanently disable) any competing HTTP daemon that holds port 80.
    # We disable them because nginx is taking over port 80 — apache2/etc cannot coexist.
    local daemon
    for daemon in apache2 apache httpd lighttpd caddy h2o; do
        if systemctl is-active "$daemon" &>/dev/null 2>&1 \
           || systemctl is-enabled "$daemon" &>/dev/null 2>&1; then
            warn "  Disabling $daemon (conflicts with nginx on port 80)..."
            systemctl disable --now "$daemon" 2>/dev/null || true
        fi
    done
    # Always stop nginx too (we restart it after cert issuance)
    systemctl stop nginx 2>/dev/null || true
    sleep 1

    # Nuclear option: if something still owns port 80, kill it by PID
    local pids
    pids=$(ss -tlnp 'sport = :80' 2>/dev/null \
        | awk 'NR>1 && /LISTEN/ {match($0,/pid=([0-9]+)/,a); if(a[1]) print a[1]}' | sort -u)
    if [[ -n "$pids" ]]; then
        warn "  Port 80 still held by PIDs: $pids — sending SIGTERM..."
        echo "$pids" | xargs -r kill 2>/dev/null || true
        sleep 2
        # Remaining? SIGKILL
        pids=$(ss -tlnp 'sport = :80' 2>/dev/null \
            | awk 'NR>1 && /LISTEN/ {match($0,/pid=([0-9]+)/,a); if(a[1]) print a[1]}' | sort -u)
        [[ -n "$pids" ]] && echo "$pids" | xargs -r kill -9 2>/dev/null || true
        sleep 1
    fi

    # Final check
    if ss -tlnp 'sport = :80' 2>/dev/null | grep -q LISTEN; then
        warn "  Port 80 still in use — ACME challenge may fail"
    else
        ok "  Port 80 is free"
    fi
}

# ─── 4 · SSL Certificate ──────────────────────────────────────────────────────
issue_cert() {
    require_root; detect_os; load_state
    step "Issue SSL/TLS Certificate"

    if [[ -z "$DOMAIN" ]]; then prompt_domain; fi

    CERT_DIR="/etc/ssl/xray-ws/${DOMAIN}"
    CERT_FILE="${CERT_DIR}/fullchain.pem"
    KEY_FILE="${CERT_DIR}/privkey.pem"
    mkdir -p "$CERT_DIR"

    # Skip only if a CA-signed (non-self-signed) cert is already valid for 7+ days
    local is_selfsigned=0
    if [[ -f "$CERT_FILE" ]]; then
        local issuer subject
        issuer=$(openssl x509 -issuer -noout -in "$CERT_FILE" 2>/dev/null | sed 's/^issuer=//' || echo "")
        subject=$(openssl x509 -subject -noout -in "$CERT_FILE" 2>/dev/null | sed 's/^subject=//' || echo "")
        [[ "$issuer" == "$subject" ]] && is_selfsigned=1
    fi
    if [[ "$is_selfsigned" -eq 0 && -f "$CERT_FILE" && -f "$KEY_FILE" ]] \
       && openssl x509 -checkend $((7 * 86400)) -noout -in "$CERT_FILE" 2>/dev/null; then
        skip "CA-signed certificate already valid — skipping issuance"
        svc start nginx 2>/dev/null || true
        save_state
        return 0
    fi

    local got=0
    local cb_log="/tmp/certbot_$$.log"
    local acme_log="/tmp/acme_$$.log"

    free_port_80

    # 1. certbot
    if ! command -v certbot &>/dev/null; then
        installing "certbot"; pkg_install certbot &>/dev/null || true
    fi
    if command -v certbot &>/dev/null; then
        info "Trying certbot standalone..."
        # If cert already in LE store, try --reinstall first to avoid rate limit
        local le="/etc/letsencrypt/live/${DOMAIN}"
        local certbot_flags="--standalone --agree-tos --register-unsafely-without-email --non-interactive"
        if [[ -f "${le}/fullchain.pem" ]]; then
            certbot_flags+=" --reinstall"
        fi
        if certbot certonly $certbot_flags -d "$DOMAIN" >"$cb_log" 2>&1; then
            if [[ -f "${le}/fullchain.pem" && -f "${le}/privkey.pem" ]]; then
                cp "${le}/fullchain.pem" "$CERT_FILE"
                cp "${le}/privkey.pem"  "$KEY_FILE"
                got=1; ok "Certificate issued via certbot"
            fi
        else
            warn "certbot failed — reason:"
            tail -10 "$cb_log" | sed 's/^/    /'
            warn "Trying acme.sh..."
        fi
        rm -f "$cb_log"
    fi

    # 2. acme.sh
    if [[ $got -eq 0 ]]; then
        if ! command -v acme.sh &>/dev/null && [[ ! -x ~/.acme.sh/acme.sh ]]; then
            installing "acme.sh"
            curl -fsSL https://get.acme.sh | sh -s email="admin@${DOMAIN}" &>/dev/null || true
        fi
        if [[ -x ~/.acme.sh/acme.sh ]]; then
            export PATH="$HOME/.acme.sh:$PATH"
            acme.sh --set-default-ca --server letsencrypt &>/dev/null || true
            if acme.sh --issue --standalone -d "$DOMAIN" >"$acme_log" 2>&1 \
               || acme.sh --renew -d "$DOMAIN" --standalone >"$acme_log" 2>&1; then
                acme.sh --install-cert -d "$DOMAIN" \
                    --fullchain-file "$CERT_FILE" \
                    --key-file "$KEY_FILE" &>/dev/null && got=1
                [[ $got -eq 1 ]] && ok "Certificate issued via acme.sh"
            else
                warn "acme.sh failed — reason:"
                tail -10 "$acme_log" | sed 's/^/    /'
                warn "Falling back to self-signed"
            fi
        fi
        rm -f "$acme_log"
    fi

    # 3. Self-signed fallback
    if [[ $got -eq 0 ]]; then
        warn "Generating self-signed certificate (clients will see a TLS warning)"
        warn "To get a trusted cert, ensure port 80 is open and DNS points to this server"
        openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
            -keyout "$KEY_FILE" -out "$CERT_FILE" \
            -subj "/CN=${DOMAIN}" &>/dev/null
        ok "Self-signed certificate generated at ${CERT_FILE}"
    fi

    chmod 600 "$KEY_FILE"
    svc start nginx 2>/dev/null || true
    save_state
}

# ─── Shared: write combined Xray config ───────────────────────────────────────
write_xray_config() {
    local cfg="/usr/local/etc/xray/config.json"
    mkdir -p /usr/local/etc/xray
    # Xray refuses to start if log files are missing — always ensure they exist
    mkdir -p /var/log/xray
    touch /var/log/xray/access.log /var/log/xray/error.log
    chmod 640 /var/log/xray/access.log /var/log/xray/error.log 2>/dev/null || true

    # Build inbounds array based on enabled flags
    local inbounds="["
    local first=1

    if [[ "$VLESS_ENABLED" == "1" ]]; then
        [[ $first -eq 0 ]] && inbounds+=","
        inbounds+="{
      \"listen\": \"127.0.0.1\",
      \"port\": ${XRAY_PORT_VLESS},
      \"protocol\": \"vless\",
      \"settings\": {
        \"clients\": [{\"id\": \"${UUID}\", \"flow\": \"\", \"email\": \"${DOMAIN}\"}],
        \"decryption\": \"none\"
      },
      \"streamSettings\": {
        \"network\": \"ws\",
        \"security\": \"none\",
        \"wsSettings\": {\"path\": \"${WS_PATH}\"}
      },
      \"tag\": \"vless-ws\"
    }"
        first=0
    fi

    if [[ "$VMESS_ENABLED" == "1" ]]; then
        [[ $first -eq 0 ]] && inbounds+=","
        inbounds+="{
      \"listen\": \"127.0.0.1\",
      \"port\": ${XRAY_PORT_VMESS},
      \"protocol\": \"vmess\",
      \"settings\": {
        \"clients\": [{\"id\": \"${VMESS_UUID}\", \"alterId\": 0, \"email\": \"${DOMAIN}\"}]
      },
      \"streamSettings\": {
        \"network\": \"ws\",
        \"security\": \"none\",
        \"wsSettings\": {\"path\": \"${VMESS_PATH}\"}
      },
      \"tag\": \"vmess-ws\"
    }"
        first=0
    fi

    if [[ "$GRPC_ENABLED" == "1" ]]; then
        [[ $first -eq 0 ]] && inbounds+=","
        inbounds+="{
      \"listen\": \"127.0.0.1\",
      \"port\": ${XRAY_PORT_GRPC},
      \"protocol\": \"vless\",
      \"settings\": {
        \"clients\": [{\"id\": \"${UUID}\", \"flow\": \"\", \"email\": \"${DOMAIN}-grpc\"}],
        \"decryption\": \"none\"
      },
      \"streamSettings\": {
        \"network\": \"grpc\",
        \"security\": \"none\",
        \"grpcSettings\": {\"serviceName\": \"${GRPC_SVC}\"}
      },
      \"tag\": \"vless-grpc\"
    }"
        first=0
    fi

    inbounds+="]"

    cat > "$cfg" <<XRAYCFG
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "dns": {
    "servers": ["8.8.8.8", "8.8.4.4", "1.1.1.1", "1.0.0.1"]
  },
  "inbounds": ${inbounds},
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {"domainStrategy": "UseIP"},
      "tag": "direct"
    },
    {"protocol": "blackhole", "settings": {}, "tag": "blocked"}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "ip": [
          "127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12",
          "192.168.0.0/16", "100.64.0.0/10",
          "::1/128", "fc00::/7", "fe80::/10"
        ],
        "outboundTag": "blocked"
      }
    ]
  }
}
XRAYCFG
    ok "Xray config written → ${cfg}"
}

# ─── Shared: write Nginx vhost ────────────────────────────────────────────────
write_nginx_config() {
    [[ -z "$DOMAIN" || -z "$CERT_FILE" || -z "$KEY_FILE" ]] && {
        warn "Domain/cert not set — run options 4 first"; return 1
    }

    local vhost="/etc/nginx/sites-available/${DOMAIN}"
    local enabled="/etc/nginx/sites-enabled/${DOMAIN}"
    local web_root="/var/www/html"

    # Fake cover page
    if [[ ! -f "${web_root}/index.html" ]]; then
        mkdir -p "$web_root"
        cat > "${web_root}/index.html" <<HTML
<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"><title>${DOMAIN}</title>
<style>body{font-family:sans-serif;max-width:800px;margin:60px auto;color:#333}h1{color:#1a1a2e}</style>
</head>
<body><h1>${DOMAIN}</h1><p>Secure web services.</p></body>
</html>
HTML
    fi

    # Build location blocks for enabled protocols
    local locations=""

    [[ "$VLESS_ENABLED"  == "1" ]] && locations+="
    location ${WS_PATH} {
        proxy_pass http://127.0.0.1:${XRAY_PORT_VLESS};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"Upgrade\";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_connect_timeout 10s;
        proxy_buffering off;
        proxy_cache_bypass \$http_upgrade;
    }
"
    [[ "$VMESS_ENABLED"  == "1" ]] && locations+="
    location ${VMESS_PATH} {
        proxy_pass http://127.0.0.1:${XRAY_PORT_VMESS};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"Upgrade\";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_connect_timeout 10s;
        proxy_buffering off;
        proxy_cache_bypass \$http_upgrade;
    }
"
    [[ "$GRPC_ENABLED"   == "1" ]] && locations+="
    location /${GRPC_SVC} {
        grpc_pass grpc://127.0.0.1:${XRAY_PORT_GRPC};
        grpc_set_header Host \$host;
        grpc_read_timeout 86400s;
        grpc_send_timeout 86400s;
        client_max_body_size 0;
        client_body_buffer_size 512k;
    }
"
    [[ "$SSH_WS_ENABLED" == "1" ]] && locations+="
    location /ssh-ws {
        proxy_pass http://127.0.0.1:${SSH_WS_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"Upgrade\";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_connect_timeout 10s;
        proxy_buffering off;
        proxy_cache_bypass \$http_upgrade;
    }
"

    cat > "$vhost" <<NGINXCFG
# ── HTTP / Non-TLS block: port 80 (Cloudflare CDN HTTP) + port 2086 (CF alt / direct) ──
# Cloudflare CDN sends plain HTTP to the origin on port 80 even when the client
# connects on 443/2086/2087.  WebSocket upgrade locations must appear BEFORE the
# catch-all redirect, otherwise Cloudflare gets 301 instead of 101.
server {
    listen 80;
    listen 2086;
    server_name ${DOMAIN};

${locations}
    location / {
        return 301 https://\$host\$request_uri;
    }
}

# ── HTTPS / TLS block: port 443 (direct TLS) + port 2087 (Cloudflare HTTPS alt) ──
server {
    listen 443 ssl;
    listen 2087 ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate     ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    root  ${web_root};
    index index.html;

${locations}
    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGINXCFG

    ln -sf "$vhost" "$enabled" 2>/dev/null || true

    if nginx -t &>/dev/null; then
        svc restart nginx
        ok "Nginx vhost configured for ${DOMAIN}"
    else
        err "Nginx config test failed — check ${vhost}"
        nginx -t
    fi
}

# ─── 5 · VLESS + WebSocket ────────────────────────────────────────────────────
configure_vless_ws() {
    require_root; load_state
    step "Configure VLESS + WebSocket"

    if [[ -z "$DOMAIN" ]]; then prompt_domain; fi
    prompt_ws_path

    [[ -z "$UUID" ]] && UUID=$(gen_uuid)
    VLESS_ENABLED=1
    save_state; write_xray_config

    if [[ -n "$CERT_FILE" && -f "$CERT_FILE" ]]; then
        write_nginx_config
    else
        warn "No cert yet — run option 4 then option 9 to apply Nginx config"
    fi

    svc_or_warn restart xray "Xray"
    _write_vless_txt
    ok "VLESS+WS configured"
    echo -e "  ${DIM}Output: ${CYN}${OUT_DIR}/vless-ws.txt${R}"
    echo ""
}

_vless_link() {
    local encoded_path
    encoded_path=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${WS_PATH}', safe=''))" 2>/dev/null \
        || echo "${WS_PATH//\//%2F}")   # pure-bash fallback: replace / with %2F
    echo "vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&type=ws&path=${encoded_path}&host=${DOMAIN}#${DOMAIN}-VLESS-WS"
}

# CDN links — Cloudflare orange-cloud proxied domain.
# CF blocks SNI mismatch (domain fronting) since 2020 — SNI must equal the proxied domain.
# Two variants:
#   CDN-443  : standard port via CF edge  (same resolution as direct when orange-cloud)
#   CDN-2087 : CF HTTPS alt-port (wss://) — bypasses ISP port-443 blocking
_vless_link_cdn() {
    local encoded_path
    encoded_path=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${WS_PATH}', safe=''))" 2>/dev/null \
        || echo "${WS_PATH//\//%2F}")
    echo "vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&type=ws&path=${encoded_path}&host=${DOMAIN}#${DOMAIN}-VLESS-CDN-443"
}

_vless_link_cdn_2087() {
    local encoded_path
    encoded_path=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${WS_PATH}', safe=''))" 2>/dev/null \
        || echo "${WS_PATH//\//%2F}")
    echo "vless://${UUID}@${DOMAIN}:2087?encryption=none&security=tls&sni=${DOMAIN}&type=ws&path=${encoded_path}&host=${DOMAIN}#${DOMAIN}-VLESS-CDN-2087"
}

_write_vless_txt() {
    mkdir -p "$OUT_DIR"
    local link; link=$(_vless_link)
    local link_cdn; link_cdn=$(_vless_link_cdn)
    local link_cdn_2087; link_cdn_2087=$(_vless_link_cdn_2087)
    cat > "${OUT_DIR}/vless-ws.txt" <<TXT
═══════════════════════════════════════════════════════════
  VLESS + WebSocket + TLS
═══════════════════════════════════════════════════════════
  Server   : ${DOMAIN}
  Port     : 443
  UUID     : ${UUID}
  Path     : ${WS_PATH}
  TLS      : TLS (SNI: ${DOMAIN})
  Transport: WebSocket (ws)

  ── Direct (port 443) — paste into v2rayN / v2rayNG / NekoBox ──
${link}

  ── Manual Settings (Direct TLS, port 443) ──
  Address  : ${DOMAIN}
  Port     : 443
  UUID     : ${UUID}
  Network  : ws
  WS Path  : ${WS_PATH}
  WS Host  : ${DOMAIN}
  TLS      : true
  SNI      : ${DOMAIN}
  AllowInsecure: false

  ── Cloudflare CDN Mode ──
  Requirement: ${DOMAIN} A record must be PROXIED (orange cloud) in Cloudflare DNS.
  How it works: Your domain resolves to CF edge IPs — traffic flows CF → origin.
                This hides your real server IP and routes around ISP blocking.
  NOTE: Cloudflare blocks SNI mismatch (domain fronting) since 2020.
        SNI must equal your domain. Do NOT use speed.cloudflare.com as SNI.

  CDN port 443 (same as direct when orange-cloud active):
${link_cdn}

  CDN port 2087 — Cloudflare HTTPS alt-port (wss://) — bypasses ISP port-443 blocks:
${link_cdn_2087}

  Manual CDN settings (port 2087):
  Address  : ${DOMAIN}   ← CF resolves this to a CF edge IP
  Port     : 2087
  UUID     : ${UUID}
  Network  : ws
  WS Path  : ${WS_PATH}
  WS Host  : ${DOMAIN}
  TLS      : true
  SNI      : ${DOMAIN}   ← MUST match the domain, not a bug host
  AllowInsecure: false

  ── Clash / Sing-Box snippet (direct) ──
  - name: "${DOMAIN}-VLESS"
    type: vless
    server: ${DOMAIN}
    port: 443
    uuid: ${UUID}
    network: ws
    ws-opts:
      path: ${WS_PATH}
      headers:
        Host: ${DOMAIN}
    tls: true
    sni: ${DOMAIN}
═══════════════════════════════════════════════════════════
TXT
}

# ─── 6 · VMess + WebSocket ────────────────────────────────────────────────────
configure_vmess_ws() {
    require_root; load_state
    step "Configure VMess + WebSocket"

    if [[ -z "$DOMAIN" ]]; then prompt_domain; fi
    prompt_vmess_path

    [[ -z "$VMESS_UUID" ]] && VMESS_UUID=$(gen_uuid)
    VMESS_ENABLED=1
    save_state; write_xray_config

    if [[ -n "$CERT_FILE" && -f "$CERT_FILE" ]]; then
        write_nginx_config
    else
        warn "No cert yet — run option 4 then option 9 to apply Nginx config"
    fi

    svc_or_warn restart xray "Xray"
    _write_vmess_txt
    ok "VMess+WS configured"
    echo -e "  ${DIM}Output: ${CYN}${OUT_DIR}/vmess-ws.txt${R}"
    echo ""
}

_vmess_link() {
    local json; json=$(printf '%s' "{\"v\":\"2\",\"ps\":\"${DOMAIN}-VMess-WS\",\"add\":\"${DOMAIN}\",\"port\":\"443\",\"id\":\"${VMESS_UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"${VMESS_PATH}\",\"tls\":\"tls\",\"sni\":\"${DOMAIN}\",\"alpn\":\"\"}")
    local b64; b64=$(echo -n "$json" | base64 -w 0 2>/dev/null || echo -n "$json" | base64)
    echo "vmess://${b64}"
}

# CDN links — same SNI-must-equal-domain rule as VLESS
_vmess_link_cdn() {
    local json; json=$(printf '%s' "{\"v\":\"2\",\"ps\":\"${DOMAIN}-VMess-CDN-443\",\"add\":\"${DOMAIN}\",\"port\":\"443\",\"id\":\"${VMESS_UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"${VMESS_PATH}\",\"tls\":\"tls\",\"sni\":\"${DOMAIN}\",\"alpn\":\"\"}")
    local b64; b64=$(echo -n "$json" | base64 -w 0 2>/dev/null || echo -n "$json" | base64)
    echo "vmess://${b64}"
}

_vmess_link_cdn_2087() {
    local json; json=$(printf '%s' "{\"v\":\"2\",\"ps\":\"${DOMAIN}-VMess-CDN-2087\",\"add\":\"${DOMAIN}\",\"port\":\"2087\",\"id\":\"${VMESS_UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"${VMESS_PATH}\",\"tls\":\"tls\",\"sni\":\"${DOMAIN}\",\"alpn\":\"\"}")
    local b64; b64=$(echo -n "$json" | base64 -w 0 2>/dev/null || echo -n "$json" | base64)
    echo "vmess://${b64}"
}

_write_vmess_txt() {
    mkdir -p "$OUT_DIR"
    local link; link=$(_vmess_link)
    local link_cdn; link_cdn=$(_vmess_link_cdn)
    local link_cdn_2087; link_cdn_2087=$(_vmess_link_cdn_2087)
    cat > "${OUT_DIR}/vmess-ws.txt" <<TXT
═══════════════════════════════════════════════════════════
  VMess + WebSocket + TLS
═══════════════════════════════════════════════════════════
  Server   : ${DOMAIN}
  Port     : 443
  UUID     : ${VMESS_UUID}
  AlterID  : 0
  Path     : ${VMESS_PATH}
  TLS      : TLS (SNI: ${DOMAIN})
  Transport: WebSocket (ws)

  ── Direct (port 443) — paste into v2rayN / v2rayNG / NekoBox ──
${link}

  ── Manual Settings (Direct TLS, port 443) ──
  Address  : ${DOMAIN}
  Port     : 443
  UUID     : ${VMESS_UUID}
  AlterId  : 0
  Network  : ws
  WS Path  : ${VMESS_PATH}
  WS Host  : ${DOMAIN}
  TLS      : true
  SNI      : ${DOMAIN}

  ── Cloudflare CDN Mode ──
  Requirement: ${DOMAIN} A record must be PROXIED (orange cloud) in Cloudflare DNS.
  NOTE: CF blocks SNI mismatch — SNI must equal your domain, not a bug host.

  CDN port 443:
${link_cdn}

  CDN port 2087 — CF HTTPS alt-port, bypasses ISP port-443 blocks:
${link_cdn_2087}

  Manual CDN settings (port 2087):
  Address  : ${DOMAIN}
  Port     : 2087
  UUID     : ${VMESS_UUID}
  AlterId  : 0
  Network  : ws
  WS Path  : ${VMESS_PATH}
  WS Host  : ${DOMAIN}
  TLS      : true
  SNI      : ${DOMAIN}   ← must match the domain

  ── Clash snippet (direct) ──
  - name: "${DOMAIN}-VMess"
    type: vmess
    server: ${DOMAIN}
    port: 443
    uuid: ${VMESS_UUID}
    alterId: 0
    cipher: auto
    network: ws
    ws-opts:
      path: ${VMESS_PATH}
      headers:
        Host: ${DOMAIN}
    tls: true
    sni: ${DOMAIN}
═══════════════════════════════════════════════════════════
TXT
}

# ─── 7 · VLESS + gRPC ────────────────────────────────────────────────────────
configure_vless_grpc() {
    require_root; load_state
    step "Configure VLESS + gRPC"

    if [[ -z "$DOMAIN" ]]; then prompt_domain; fi
    [[ -z "$UUID" ]] && UUID=$(gen_uuid)
    GRPC_ENABLED=1
    save_state; write_xray_config

    if [[ -n "$CERT_FILE" && -f "$CERT_FILE" ]]; then
        write_nginx_config
    else
        warn "No cert yet — run option 4 then option 9 to apply Nginx config"
    fi

    svc_or_warn restart xray "Xray"
    _write_grpc_txt
    ok "VLESS+gRPC configured"
    echo -e "  ${DIM}Output: ${CYN}${OUT_DIR}/vless-grpc.txt${R}"
    echo ""
}

_grpc_link() {
    echo "vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&type=grpc&serviceName=${GRPC_SVC}&mode=gun#${DOMAIN}-VLESS-gRPC"
}

_write_grpc_txt() {
    mkdir -p "$OUT_DIR"
    local link; link=$(_grpc_link)
    cat > "${OUT_DIR}/vless-grpc.txt" <<TXT
═══════════════════════════════════════════════════════════
  VLESS + gRPC + TLS
═══════════════════════════════════════════════════════════
  Server      : ${DOMAIN}
  Port        : 443
  UUID        : ${UUID}
  ServiceName : ${GRPC_SVC}
  TLS         : TLS (SNI: ${DOMAIN})
  Transport   : gRPC

  ── Connection Link (paste into v2rayN / v2rayNG / NekoBox) ──
${link}

  ── Manual Settings ──
  Address     : ${DOMAIN}
  Port        : 443
  UUID        : ${UUID}
  Network     : grpc
  ServiceName : ${GRPC_SVC}
  TLS         : true
  SNI         : ${DOMAIN}

  ── Clash-Meta / Sing-Box snippet ──
  - name: "${DOMAIN}-gRPC"
    type: vless
    server: ${DOMAIN}
    port: 443
    uuid: ${UUID}
    network: grpc
    grpc-opts:
      grpc-service-name: "${GRPC_SVC}"
    tls: true
    sni: ${DOMAIN}
═══════════════════════════════════════════════════════════
TXT
}

# ─── 8 · SSH over WebSocket ───────────────────────────────────────────────────
configure_ssh_ws() {
    require_root; detect_os; load_state
    step "Configure SSH over WebSocket"

    if [[ -z "$DOMAIN" ]]; then prompt_domain; fi

    # ── Port collision guard ───────────────────────────────────────────────────
    local _col_port
    for _col_port in 80 443 2086 2087; do
        if [[ "$SSH_WS_PORT" == "$_col_port" ]]; then
            warn "SSH_WS_PORT=${SSH_WS_PORT} collides with nginx port ${_col_port} — migrating to 9022"
            SSH_WS_PORT=9022
            break
        fi
    done

    # ── Install Python 3 (bridge script dependency) ───────────────────────────
    pkg_install python3 &>/dev/null || true

    SSH_WS_ENABLED=1
    save_state

    # ── Write raw-TCP HTTP bridge script ──────────────────────────────────────
    # SSH-over-WS apps (HTTP Custom, HTTP Injector, etc.) send a plain HTTP
    # upgrade request and then speak *raw* SSH — no WebSocket framing.
    # websockify wraps bytes in WS frames, causing "ssh: handshake failed: EOF".
    # This bridge reads the HTTP headers, replies with 101, then pipes raw TCP
    # to SSH:22 — no framing, no encoding, just a transparent tunnel.
    local bridge_bin="/usr/local/bin/ssh-http-bridge"
    local _py; _py=$(command -v python3 2>/dev/null || echo "/usr/bin/python3")

    cat > "$bridge_bin" <<'PYBRIDGE'
#!/usr/bin/env python3
"""ssh-http-bridge: HTTP-upgrade → raw TCP tunnel to SSH.

Usage: ssh-http-bridge <listen-addr> <listen-port> [ssh-host] [ssh-port]

Accepts any HTTP/1.x request (GET, CONNECT, etc.), replies with
"HTTP/1.1 101 Switching Protocols" and then transparently relays raw
bytes between the client and the SSH daemon. No WebSocket framing.
Compatible with HTTP Custom, HTTP Injector, and similar SSH-over-HTTP apps.
"""
import sys, socket, threading, select, signal

LISTEN_ADDR = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
LISTEN_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 9022
SSH_HOST    = sys.argv[3] if len(sys.argv) > 3 else "127.0.0.1"
SSH_PORT    = int(sys.argv[4]) if len(sys.argv) > 4 else 22

RESPONSE_101 = (
    b"HTTP/1.1 101 Switching Protocols\r\n"
    b"Upgrade: websocket\r\n"
    b"Connection: Upgrade\r\n"
    b"\r\n"
)
BUFSIZE = 65536

def relay(src: socket.socket, dst: socket.socket, leftover: bytes = b"") -> None:
    try:
        if leftover:
            dst.sendall(leftover)
        while True:
            ready, _, _ = select.select([src], [], [], 60)
            if not ready:
                break
            data = src.recv(BUFSIZE)
            if not data:
                break
            dst.sendall(data)
    except Exception:
        pass
    finally:
        for s in (src, dst):
            try: s.shutdown(socket.SHUT_RDWR)
            except Exception: pass
            try: s.close()
            except Exception: pass

def handle(conn: socket.socket) -> None:
    try:
        raw = b""
        while b"\r\n\r\n" not in raw:
            chunk = conn.recv(BUFSIZE)
            if not chunk:
                conn.close()
                return
            raw += chunk
        header_part, leftover = raw.split(b"\r\n\r\n", 1)
        conn.sendall(RESPONSE_101)
        ssh = socket.create_connection((SSH_HOST, SSH_PORT), timeout=10)
        t1 = threading.Thread(target=relay, args=(conn, ssh, leftover), daemon=True)
        t2 = threading.Thread(target=relay, args=(ssh, conn), daemon=True)
        t1.start()
        t2.start()
        t1.join()
        t2.join()
    except Exception:
        try: conn.close()
        except Exception: pass

signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
signal.signal(signal.SIGINT,  lambda *_: sys.exit(0))

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind((LISTEN_ADDR, LISTEN_PORT))
srv.listen(256)
sys.stdout.write(f"ssh-http-bridge listening on {LISTEN_ADDR}:{LISTEN_PORT} → {SSH_HOST}:{SSH_PORT}\n")
sys.stdout.flush()

while True:
    try:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()
    except Exception:
        pass
PYBRIDGE

    chmod +x "$bridge_bin" 2>/dev/null || true
    _py=$(command -v python3 2>/dev/null || echo "/usr/bin/python3")

    # ── Write systemd unit ────────────────────────────────────────────────────
    cat > /etc/systemd/system/ssh-ws.service <<SYSD
[Unit]
Description=SSH over WebSocket (raw-TCP HTTP bridge)
After=network.target ssh.service sshd.service

[Service]
Type=simple
ExecStart=${_py} ${bridge_bin} 127.0.0.1 ${SSH_WS_PORT} 127.0.0.1 22
Restart=always
RestartSec=3s
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SYSD
    systemctl daemon-reload &>/dev/null || true
    systemctl enable ssh-ws  &>/dev/null || true
    systemctl restart ssh-ws 2>/dev/null || true
    sleep 2

    # ── Post-start verification ───────────────────────────────────────────────
    if systemctl is-active ssh-ws &>/dev/null; then
        ok "ssh-ws running  (raw-TCP bridge 127.0.0.1:${SSH_WS_PORT} → 127.0.0.1:22)"
    else
        warn "ssh-ws failed to start — last journal lines:"
        journalctl -u ssh-ws -n 25 --no-pager 2>/dev/null | sed 's/^/    /' || true
        echo -e "  ${YLW}  ↳ Re-run option 8 after fixing the issue above${R}"
        echo -e "  ${DIM}  Full logs: journalctl -u ssh-ws -n 50 --no-pager${R}"
    fi

    # ── Install & start badvpn-udpgw (UDP support for SSH tunnel apps) ──────────
    step "Install UDPGW (UDP over SSH tunnel)"
    local udpgw_bin="/usr/local/bin/badvpn-udpgw"
    if [[ ! -x "$udpgw_bin" ]] && ! command -v badvpn-udpgw &>/dev/null; then
        installing "badvpn-udpgw"
        # Try package manager first (Debian/Ubuntu: badvpn)
        if eval "$PKG_INSTALL badvpn" &>/dev/null 2>&1; then
            ok "badvpn installed via package manager"
        else
            # Build from source
            info "Building badvpn-udpgw from source..."
            pkg_install cmake build-essential &>/dev/null || true
            local tmp_badvpn="/tmp/badvpn_$$"
            mkdir -p "$tmp_badvpn"
            if curl -fsSL --max-time 60 \
                "https://github.com/ambrop72/badvpn/archive/refs/heads/master.tar.gz" \
                | tar -xz -C "$tmp_badvpn" --strip-components=1 2>/dev/null; then
                mkdir -p "$tmp_badvpn/build"
                if (cd "$tmp_badvpn/build" && \
                    cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 -DCMAKE_BUILD_TYPE=Release &>/dev/null && \
                    make -j"$(nproc)" &>/dev/null); then
                    install -m 755 "$tmp_badvpn/build/udpgw/badvpn-udpgw" "$udpgw_bin"
                    ok "badvpn-udpgw built and installed at ${udpgw_bin}"
                else
                    warn "badvpn-udpgw build failed — UDP tunneling will not work"
                fi
            else
                warn "Could not download badvpn source — UDP tunneling will not work"
            fi
            rm -rf "$tmp_badvpn"
        fi
    else
        skip "badvpn-udpgw"
    fi

    # Resolve final udpgw binary path
    local udpgw_exec
    udpgw_exec=$(command -v badvpn-udpgw 2>/dev/null || echo "$udpgw_bin")

    if [[ -x "$udpgw_exec" ]]; then
        cat > /etc/systemd/system/udpgw.service <<UDPSVC
[Unit]
Description=BadVPN UDP Gateway (UDPGW for SSH tunnel)
After=network.target

[Service]
Type=simple
ExecStart=${udpgw_exec} --listen-addr 127.0.0.1:7300 --max-clients 1000 --max-connections-for-client 10
Restart=always
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UDPSVC
        systemctl daemon-reload &>/dev/null || true
        systemctl enable udpgw  &>/dev/null || true
        systemctl restart udpgw &>/dev/null || \
            warn "Could not start udpgw — start manually: systemctl start udpgw"
        ok "UDPGW running on 127.0.0.1:7300"
    fi

    save_state

    if [[ -n "$CERT_FILE" && -f "$CERT_FILE" ]]; then
        write_nginx_config
    else
        warn "No cert yet — run option 4 then option 9 to apply Nginx config"
    fi

    _write_ssh_ws_txt
    ok "SSH-WS configured on port ${SSH_WS_PORT} → ws://${DOMAIN}/ssh-ws"
    echo -e "  ${DIM}Output: ${CYN}${OUT_DIR}/ssh-ws.txt${R}"
    echo ""
}

_write_ssh_ws_txt() {
    mkdir -p "$OUT_DIR"
    cat > "${OUT_DIR}/ssh-ws.txt" <<TXT
═══════════════════════════════════════════════════════════
  SSH over WebSocket  (HTTP Custom / HTTP Injector style)
═══════════════════════════════════════════════════════════
  Bridge  : raw-TCP HTTP bridge (no WebSocket framing)
            127.0.0.1:${SSH_WS_PORT} → 127.0.0.1:22
  Binary  : /usr/local/bin/ssh-http-bridge

  How it works:
    Client sends an HTTP upgrade payload → bridge responds 101 →
    bridge pipes raw TCP between client and SSH:22.
    No WebSocket framing — raw SSH bytes flow through directly.

  Payload (HTTP injection header):
    GET /ssh-ws HTTP/1.1[crlf]Host: ${DOMAIN}[crlf]Upgrade: websocket[crlf][crlf]

  ── Mode A: Direct TLS (port 443) ──
  App            : HTTP Custom / HTTP Injector / SSH Connector / NapsternetV
  Server         : ${DOMAIN}
  Port           : 443
  SSL/TLS        : ON  (SNI: ${DOMAIN})
  Payload        : GET /ssh-ws HTTP/1.1[crlf]Host: ${DOMAIN}[crlf]Upgrade: websocket[crlf][crlf]

  ── Mode B: Cloudflare CDN — HTTP port 2086 (hides real server IP) ──
  Requirement    : ${DOMAIN} A record MUST be PROXIED (orange cloud) in Cloudflare
  How it works   : Client → CF edge:2086 → origin:80 → nginx → bridge → SSH
  Server         : ${DOMAIN}   ← must be YOUR domain, not a bug host
  Port           : 2086
  SSL/TLS        : OFF  (CF terminates TLS; plain HTTP to origin)
  Payload        : GET /ssh-ws HTTP/1.1[crlf]Host: ${DOMAIN}[crlf]Upgrade: websocket[crlf][crlf]
  NOTE: "Bug host" tricks (bc.game, speed.cloudflare.com, etc.) do NOT work here.
        Cloudflare routes each zone independently — connecting to a foreign CF site
        with Host: ${DOMAIN} will reach THAT site's origin, not yours.
        Always use ${DOMAIN} as the Server address.

  ── Mode C: Cloudflare CDN — HTTPS port 2087 ──
  Requirement    : Same as Mode B (orange cloud)
  Server         : ${DOMAIN}
  Port           : 2087
  SSL/TLS        : ON  (SNI: ${DOMAIN})
  Payload        : GET /ssh-ws HTTP/1.1[crlf]Host: ${DOMAIN}[crlf]Upgrade: websocket[crlf][crlf]

  ── UDPGW (UDP support for games / video calls) ──
  UDPGW Host : 127.0.0.1
  UDPGW Port : 7300
  Enable in your app settings under "UDPGW" or "UDP Gateway"

  ── Service check ──
  systemctl status ssh-ws udpgw sshd nginx
  journalctl -u ssh-ws -n 30 --no-pager
═══════════════════════════════════════════════════════════
TXT
}

# ─── 1 · Install All-in-One ───────────────────────────────────────────────────
install_all() {
    require_root; detect_os
    step "Install All-in-One  (Xray + Nginx + TLS + VLESS-WS + VMess-WS + gRPC)"
    divider

    # Collect inputs up front
    if [[ -z "$DOMAIN" ]]; then prompt_domain; fi

    info "Generate or reuse UUIDs..."
    [[ -z "$UUID" ]]       && UUID=$(gen_uuid)
    [[ -z "$VMESS_UUID" ]] && VMESS_UUID=$(gen_uuid)
    save_state   # persist UUIDs NOW — issue_cert calls load_state internally and would wipe them

    echo -en "${CYN}${BOLD}  ➤  ${R}${WHT}VLESS WebSocket path [default: /vless-ws]: ${R}"
    read -r _inp; WS_PATH="${_inp:-/vless-ws}"
    [[ "${WS_PATH:0:1}" != "/" ]] && WS_PATH="/$WS_PATH"

    echo -en "${CYN}${BOLD}  ➤  ${R}${WHT}VMess WebSocket path [default: /vmess-ws]: ${R}"
    read -r _inp; VMESS_PATH="${_inp:-/vmess-ws}"
    [[ "${VMESS_PATH:0:1}" != "/" ]] && VMESS_PATH="/$VMESS_PATH"

    echo -en "${CYN}${BOLD}  ➤  ${R}${WHT}Include SSH-WS? [y/N]: ${R}"
    read -r _ssh; _ssh="${_ssh,,}"
    [[ "$_ssh" == "y" || "$_ssh" == "yes" ]] && _do_ssh=1 || _do_ssh=0

    divider

    install_xray
    install_nginx
    configure_ufw   # open ports 22/80/443 before ACME challenge
    issue_cert

    VLESS_ENABLED=1; VMESS_ENABLED=1; GRPC_ENABLED=1
    [[ $_do_ssh -eq 1 ]] && SSH_WS_ENABLED=1 || SSH_WS_ENABLED=0
    save_state

    write_xray_config
    write_nginx_config || warn "Nginx config skipped — cert not ready (run option 4 first)"

    [[ $_do_ssh -eq 1 ]] && configure_ssh_ws

    svc_or_warn restart xray  "Xray"
    svc_or_warn restart nginx "Nginx"

    _write_vless_txt; _write_vmess_txt; _write_grpc_txt
    [[ $_do_ssh -eq 1 ]] && _write_ssh_ws_txt

    divider
    show_links
}

# ─── 9 · Show links ───────────────────────────────────────────────────────────
show_links() {
    load_state
    step "Connection Links & Payloads"

    if [[ -z "$DOMAIN" ]]; then
        warn "No domain configured yet. Run option 1 or 5 first."; return
    fi

    echo ""
    if [[ "$VLESS_ENABLED" == "1" ]]; then
        proto "VLESS + WebSocket"
        link_line "$(_vless_link)"
        echo -e "  ${DIM}Saved: ${CYN}${OUT_DIR}/vless-ws.txt${R}"
        echo ""
    fi

    if [[ "$VMESS_ENABLED" == "1" ]]; then
        proto "VMess + WebSocket"
        link_line "$(_vmess_link)"
        echo -e "  ${DIM}Saved: ${CYN}${OUT_DIR}/vmess-ws.txt${R}"
        echo ""
    fi

    if [[ "$GRPC_ENABLED" == "1" ]]; then
        proto "VLESS + gRPC"
        link_line "$(_grpc_link)"
        echo -e "  ${DIM}Saved: ${CYN}${OUT_DIR}/vless-grpc.txt${R}"
        echo ""
    fi

    if [[ "$SSH_WS_ENABLED" == "1" ]]; then
        proto "SSH over WebSocket"
        link_line "wss://${DOMAIN}/ssh-ws"
        echo -e "  ${DIM}Saved: ${CYN}${OUT_DIR}/ssh-ws.txt${R}"
        echo ""
    fi

    if [[ "$VLESS_ENABLED" != "1" && "$VMESS_ENABLED" != "1" && "$GRPC_ENABLED" != "1" ]]; then
        warn "No protocols configured yet."
    fi
}

# ─── Helpers for status dashboard ─────────────────────────────────────────────
_chk_bin() {   # _chk_bin label cmd [version_arg]
    local label="$1" cmd="$2" varg="${3:---version}"
    if command -v "$cmd" &>/dev/null; then
        local ver; ver=$("$cmd" "$varg" 2>&1 | grep -o '[0-9][0-9.]*' | head -1 || echo "?")
        echo -e "    ${GRN}✔${R}  ${WHT}$(printf '%-12s' "$label")${R}  ${DIM}${ver}${R}"
    else
        echo -e "    ${DIM}✖  $(printf '%-12s' "$label")  not installed${R}"
    fi
}

_chk_svc() {   # _chk_svc label service
    local label="$1" svc="$2"
    if systemctl is-active "$svc" &>/dev/null; then
        echo -e "    ${GRN}●${R}  ${WHT}$(printf '%-12s' "$label")${R}  ${GRN}running${R}"
    elif systemctl is-enabled "$svc" &>/dev/null 2>&1; then
        echo -e "    ${YLW}●${R}  ${WHT}$(printf '%-12s' "$label")${R}  ${YLW}inactive (enabled)${R}"
    else
        echo -e "    ${DIM}○  $(printf '%-12s' "$label")  not running${R}"
    fi
}

_chk_proto() {
    local label="$1" flag="$2"
    [[ "$flag" == "1" ]] && echo -e "    ${GRN}✔${R}  ${label}" || \
                            echo -e "    ${DIM}○  ${label}${R}"
}

# ─── 10 · Status dashboard ────────────────────────────────────────────────────
status_dashboard() {
    load_state
    step "Status Dashboard"
    divider

    echo -e "  ${CYN}${BOLD}Binaries${R}"
    _chk_bin "Xray"     xray     "version"
    _chk_bin "Nginx"    nginx    "-v"
    _chk_bin "certbot"  certbot  "--version"
    echo ""

    echo -e "  ${CYN}${BOLD}Services${R}"
    if command -v systemctl &>/dev/null; then
        _chk_svc "xray"    xray
        _chk_svc "nginx"   nginx
        _chk_svc "ssh-ws"  ssh-ws
        _chk_svc "udpgw"   udpgw
    else
        warn "systemd not available — service status unknown"
    fi
    echo ""

    echo -e "  ${CYN}${BOLD}Protocols${R}"
    _chk_proto "VLESS + WebSocket    (path: ${WS_PATH})"    "$VLESS_ENABLED"
    _chk_proto "VMess + WebSocket    (path: ${VMESS_PATH})" "$VMESS_ENABLED"
    _chk_proto "VLESS + gRPC         (svc: ${GRPC_SVC})"    "$GRPC_ENABLED"
    _chk_proto "SSH over WebSocket   (port: ${SSH_WS_PORT})" "$SSH_WS_ENABLED"
    echo ""

    echo -e "  ${CYN}${BOLD}Config${R}"
    if [[ -n "$DOMAIN" ]]; then
        echo -e "    ${DIM}Domain  : ${WHT}${DOMAIN}${R}"
        echo -e "    ${DIM}UUID    : ${WHT}${UUID}${R}"
        [[ -n "$VMESS_UUID" ]] && echo -e "    ${DIM}VMess  : ${WHT}${VMESS_UUID}${R}"
        [[ -n "$CERT_FILE"  ]] && echo -e "    ${DIM}Cert    : ${WHT}${CERT_FILE}${R}"
        [[ -n "$KEY_FILE"   ]] && echo -e "    ${DIM}Key     : ${WHT}${KEY_FILE}${R}"
        echo -e "    ${DIM}Outputs : ${WHT}${OUT_DIR}/${R}"
    else
        warn "Not configured yet"
    fi

    echo ""
    echo -e "  ${CYN}${BOLD}Output files${R}"
    for f in vless-ws.txt vmess-ws.txt vless-grpc.txt ssh-ws.txt; do
        if [[ -f "${OUT_DIR}/${f}" ]]; then
            echo -e "    ${GRN}✔${R}  ${OUT_DIR}/${f}"
        else
            echo -e "    ${DIM}○  ${OUT_DIR}/${f}${R}"
        fi
    done

    echo ""
    echo -e "  ${DIM}Disk : $(df -h / | awk 'NR==2{print $3"/"$2" ("$5" used)"}')"
    echo -e "  ${DIM}RAM  : $(free -h | awk '/Mem/{print $3"/"$2}')"
    echo ""
    divider
}

# ─── 11 · Restart ─────────────────────────────────────────────────────────────

# Helper: write (or rewrite) the ssh-ws systemd unit to match current SSH_WS_PORT.
# Uses the raw-TCP bridge script (no websockify, no WS framing).
_regen_ssh_ws_unit() {
    local bridge_bin="/usr/local/bin/ssh-http-bridge"
    local _py; _py=$(command -v python3 2>/dev/null || echo "/usr/bin/python3")
    cat > /etc/systemd/system/ssh-ws.service <<SYSD
[Unit]
Description=SSH over WebSocket (raw-TCP HTTP bridge)
After=network.target ssh.service sshd.service

[Service]
Type=simple
ExecStart=${_py} ${bridge_bin} 127.0.0.1 ${SSH_WS_PORT} 127.0.0.1 22
Restart=always
RestartSec=3s
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SYSD
    systemctl daemon-reload &>/dev/null || true
    ok "ssh-ws unit written (port ${SSH_WS_PORT})"
}

restart_services() {
    require_root; load_state
    step "Restart Xray + Nginx + SSH-WS"

    # ── Port collision guard ──────────────────────────────────────────────────
    local _col_port _port_migrated=0
    for _col_port in 80 443 2086 2087; do
        if [[ "$SSH_WS_PORT" == "$_col_port" ]]; then
            warn "SSH_WS_PORT=${SSH_WS_PORT} collides with nginx — migrating to 9022"
            SSH_WS_PORT=9022
            save_state
            _port_migrated=1
            break
        fi
    done

    # ── Always regenerate the ssh-ws unit so its port matches current state ──
    # (Covers: first-time after migration, stale unit from old port, any mismatch)
    if [[ "$SSH_WS_ENABLED" == "1" ]]; then
        _regen_ssh_ws_unit
    fi

    # Regenerate configs from current state before restarting
    if [[ -n "$DOMAIN" && -n "$UUID" ]]; then
        info "Regenerating Xray config..."
        write_xray_config
    fi
    if [[ -n "$DOMAIN" && -n "$CERT_FILE" && -f "$CERT_FILE" ]]; then
        info "Regenerating Nginx config..."
        write_nginx_config || true
    fi

    if command -v systemctl &>/dev/null; then
        systemctl restart xray  2>/dev/null && ok "xray restarted"  || {
            warn "xray restart failed"
            systemctl status xray --no-pager -l 2>/dev/null | head -12 || true
        }
        nginx -t 2>&1 | grep -v "^$" || true
        systemctl restart nginx 2>/dev/null && ok "nginx restarted" || {
            warn "nginx restart failed"
            systemctl status nginx --no-pager -l 2>/dev/null | head -12 || true
        }
        if [[ "$SSH_WS_ENABLED" == "1" ]]; then
            systemctl restart ssh-ws 2>/dev/null && ok "ssh-ws restarted" || {
                warn "ssh-ws restart failed"
                journalctl -u ssh-ws -n 15 --no-pager 2>/dev/null | sed 's/^/    /' || true
            }
            # Verify bridge actually came up
            sleep 2
            if systemctl is-active ssh-ws &>/dev/null; then
                ok "ssh-ws active  (bridge 127.0.0.1:${SSH_WS_PORT} → 127.0.0.1:22)"
            else
                warn "ssh-ws failed — journal:"
                journalctl -u ssh-ws -n 20 --no-pager 2>/dev/null | sed 's/^/    /' || true
                echo -e "  ${YLW}  ↳ Try: journalctl -u ssh-ws -n 50 --no-pager${R}"
            fi
            systemctl restart udpgw  2>/dev/null && ok "udpgw restarted"  || true
        fi
    else
        warn "systemd not available"
    fi
}

# ─── 12 · Uninstall ───────────────────────────────────────────────────────────
uninstall_all() {
    require_root; load_state
    step "Uninstall Everything"
    echo -e "${RED}${BOLD}  This will remove Xray, its config, the Nginx vhost, and state files.${R}"
    echo -en "${YLW}  Are you sure? [y/N]: ${R}"
    read -r _c; [[ "${_c,,}" != "y" ]] && { info "Cancelled."; return; }

    systemctl stop    xray   2>/dev/null || true
    systemctl disable xray   2>/dev/null || true
    systemctl stop    ssh-ws 2>/dev/null || true
    systemctl disable ssh-ws 2>/dev/null || true
    systemctl stop    udpgw  2>/dev/null || true
    systemctl disable udpgw  2>/dev/null || true

    rm -f /usr/local/bin/xray
    rm -f /etc/systemd/system/xray.service
    rm -f /etc/systemd/system/ssh-ws.service
    rm -f /etc/systemd/system/udpgw.service
    rm -rf /usr/local/etc/xray
    rm -rf /var/log/xray
    systemctl daemon-reload 2>/dev/null || true

    [[ -n "$DOMAIN" ]] && {
        rm -f "/etc/nginx/sites-enabled/${DOMAIN}"
        rm -f "/etc/nginx/sites-available/${DOMAIN}"
        svc restart nginx 2>/dev/null || true
    }

    rm -rf "$STATE_DIR"
    warn "Output files kept at ${OUT_DIR} — remove manually if needed"

    ok "Uninstall complete"
}

# ─── Persist Nginx after adding protocol ─────────────────────────────────────
apply_nginx_if_ready() {
    load_state
    if [[ -n "$CERT_FILE" && -f "$CERT_FILE" ]] && command -v nginx &>/dev/null; then
        write_nginx_config
    fi
}

# ─── Main loop ────────────────────────────────────────────────────────────────
main() {
    detect_os
    while true; do
        banner
        print_menu
        read -r CHOICE
        echo ""
        case "$CHOICE" in
            1)  install_all ;;
            2)  install_xray ;;
            3)  install_nginx ;;
            4)  issue_cert ;;
            5)  configure_vless_ws ;;
            6)  configure_vmess_ws ;;
            7)  configure_vless_grpc ;;
            8)  configure_ssh_ws ;;
            9)  show_links ;;
            10) status_dashboard ;;
            11) restart_services ;;
            12) uninstall_all ;;
            0|q|quit|exit)
                echo -e "${CYN}  Bye!${R}"; exit 0 ;;
            *)  err "Invalid choice — pick 0–12" ;;
        esac
        echo ""
        echo -en "${DIM}  Press Enter to return to menu...${R}"
        read -r
    done
}

main "$@"
