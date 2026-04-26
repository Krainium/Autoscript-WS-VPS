# 🌐🔒 ws-setup — Autoscript WebSocket VPN Installer

A one-file Bash installer that turns any Ubuntu or Debian VPS into a full WebSocket VPN server in minutes. It sets up Xray Core behind Nginx with proper TLS, wires up every protocol you need, and generates ready-to-import connection links the moment it finishes.

```git
git clone https://github.com/Krainium/Autoscript-WS-VPS.git

```

---

## 🎯 What it does

You get a working VPN server with multiple protocols running over WebSocket, all behind Nginx on port 443 with a real TLS certificate. Clients connect through standard HTTPS — so it looks like normal web traffic to anyone watching the network.

Pick the protocols you want during setup. Mix and match. Everything runs on the same server at the same time.

---

## ⚡ Protocols

| Protocol | Transport | Port | Use case |
|----------|-----------|------|----------|
| 🟣 VLESS | WebSocket + TLS | 443 | Fast, lightweight, low overhead |
| 🔵 VMess | WebSocket + TLS | 443 | Compatible with all v2ray clients |
| 📡 VLESS | gRPC + TLS | 443 | Multiplexed, low latency, great for CDN |
| 🔑 SSH | WebSocket (HTTP tunnel) | 443 / 2086 | SSH-over-HTTP for Android VPN apps |

---

## 🌍 CDN Tunneling — ISP Bypass

When you point your domain through a CDN in proxy mode, your real server IP is hidden behind the CDN's edge network. Clients connect to the CDN — the CDN forwards to your server. This breaks ISP deep packet inspection that targets your IP directly.

ws-setup generates separate connection links for direct use and CDN use out of the box.

**Supported CDN providers:**

### ☁️ Cloudflare
The most common setup. Set your A record to orange-cloud proxy in Cloudflare DNS. Traffic flows: client → CF edge → your origin. Use port `443` or `2087` (HTTPS alt-port) for VLESS/VMess. Use port `2086` (HTTP alt-port) for SSH-WS. No extra config on the server needed — nginx already handles the right headers.

### 🟠 Amazon CloudFront
Point a CloudFront distribution to your domain as the origin. Set the origin protocol to HTTPS and forward the `Host` header. Your VLESS/VMess WebSocket path goes in the CloudFront behavior path pattern. Clients connect to the CloudFront domain or a custom domain you attach to the distribution.

### 🔵 Google Cloud CDN
Set up a Google Cloud external HTTP(S) load balancer with your server as a backend. Enable WebSocket support in the backend service — Google Cloud CDN forwards WebSocket upgrade requests transparently. Use a Google-managed certificate or attach your own.

### 🟡 Fastly
Create a Fastly service with your VPS as the origin backend. Set the origin hostname to your domain, enable TLS to origin, set the Host header override to your domain. WebSocket connections pass through Fastly edge with no custom VCL needed for basic setups.

### 🔴 Imperva (Incapsula)
Add your site to Imperva Cloud WAF. Imperva proxies WebSocket connections without any special configuration for the upgrade request. Point the DNS to Imperva's provided CNAME. Your origin still handles TLS via nginx — or disable TLS between Imperva and origin if you prefer HTTP-only internally.

---

## 🔧 What gets installed

- **Xray Core** — pulled from the official release, installed to `/usr/local/bin/xray`
- **Nginx** — configured as a TLS reverse proxy with WebSocket support
- **TLS certificate** — tries certbot first, falls back to acme.sh, falls back to self-signed
- **ssh-http-bridge** — a tiny Python TCP bridge for SSH-WS (no WebSocket framing, raw SSH passthrough)
- **badvpn-udpgw** — UDP gateway for game/video support in SSH tunnel apps

---

## 📋 Menu options

```
  1  🚀  Install All-in-One      Full stack in one shot
  2  ⬇   Install Xray Core       Xray only
  3  🌐  Configure Nginx          Nginx vhost only
  4  🔒  Issue TLS Certificate    certbot → acme.sh → self-signed
  5  🟣  VLESS + WebSocket
  6  🔵  VMess + WebSocket
  7  📡  VLESS + gRPC
  8  🔑  SSH over WebSocket
  9  📋  Show Connection Links
 10  📊  Status Dashboard
 11  🔄  Restart Services
 12  🗑   Uninstall Everything
```

---

## 📱 Compatible clients

| Client | Platform | Protocols |
|--------|----------|-----------|
| v2rayNG | Android | VLESS VMess |
| v2rayN | Windows | VLESS VMess gRPC |
| NekoBox | Android / Windows | VLESS VMess gRPC |
| Streisand | iOS | VLESS VMess |
| HTTP Custom | Android | SSH-WS |
| HTTP Injector | Android | SSH-WS |
| NapsternetV | Android / iOS | VLESS VMess |
| Hiddify | Android / Windows / Mac | VLESS VMess gRPC |
| Shadowrocket | iOS | VLESS VMess |

---

## 🚀 Quick start

**Requirements:** Ubuntu 20.04+ or Debian 11+. Root access. A domain pointing at your server IP.

```git
git clone https://github.com/Krainium/Autoscript-WS-VPS.git
cd Autoscript-WS-VPS
sudo bash ws-setup.sh
```

Pick option `1` for a full install. Enter your domain when prompted. Done. Connection links are saved to `/root/xray-ws-setup/` and printed on screen.

---

## 📡 SSH-WS setup for HTTP Custom / HTTP Injector

The SSH-WS setup uses a raw-TCP bridge instead of websockify. The bridge accepts the HTTP upgrade request from the app, sends back a `101` response, then passes raw SSH bytes directly to the SSH daemon — no WebSocket framing. This is what HTTP Custom and similar apps actually expect.

**Profile settings:**

```
Server   : your-domain.com          ← your actual domain, OR a bug host
Port     : 443                      ← direct TLS
  or     : 2086                     ← Cloudflare HTTP CDN (when orange-cloud is on)
  or     : 2087                     ← Cloudflare HTTPS CDN
SSL      : ON for 443/2087, OFF for 2086
Payload  : GET /ssh-ws HTTP/1.1[crlf]Host: your-domain.com[crlf]Upgrade: websocket[crlf][crlf]
UDPGW    : 127.0.0.1:7300
```

---

## 🗂 File locations

| Path | Contents |
|------|----------|
| `/etc/xray-ws-setup/state` | Saved config — domain UUID ports |
| `/etc/xray/config.json` | Active Xray config |
| `/etc/nginx/sites-available/xray-ws` | Nginx vhost |
| `/root/xray-ws-setup/` | Connection link files |
| `/usr/local/bin/ssh-http-bridge` | SSH-WS bridge script |
| `/var/log/xray/` | Xray access and error logs |

---

## 🛠 Troubleshooting

**VLESS/VMess connects but no browsing**
Run option `11` — this regenerates the Xray config with DNS servers and restarts everything.

**SSH-WS — handshake failed: EOF**
Run option `8` — this rewrites the bridge script and the systemd unit. Then check:
```bash
systemctl status ssh-ws
journalctl -u ssh-ws -n 30 --no-pager
```

**Nginx not starting**
```bash
nginx -t
systemctl status nginx
```

**Check everything at once**
```bash
systemctl status xray nginx ssh-ws udpgw
