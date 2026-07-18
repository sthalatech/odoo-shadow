#!/usr/bin/env bash
# 14: Caddy HTTPS reverse proxy in front of the existing Coder HTTP server.
#
# Simplest non-disruptive TLS: install Caddy on the Coder server as a SEPARATE
# service. It terminates TLS on :443 (auto Let's Encrypt) and reverse-proxies
# to the already-running Coder server at 127.0.0.1:8943. Coder itself is NEVER
# touched -- its plain HTTP on :8943 keeps running; HTTPS on :443 is added
# alongside. No Coder restart, no config change to coder-server.service.
#
# Domain: nip.io wildcard DNS (coder.<IP>.nip.io -> <IP>), so Let's Encrypt can
# issue a real cert with no purchased domain.
#
# Why a Host rewrite: Coder validates the request Host against CODER_ACCESS_URL
# (http://<IP>:8943). Caddy rewrites Host to <IP>:8943 so Coder accepts it; the
# browser-facing hostname (<IP>.nip.io) is preserved via X-Forwarded-Host.
#
# NOTE: the per-app subdomain host (CODER_WILDCARD_ACCESS_URL=*.<IP>.nip.io:8943)
# still points at the HTTP port and would need a Coder restart to move to HTTPS
# -- out of scope here. This secures the dashboard + API + webhook listener path,
# which is what issue->env and human login use.
#
# Prereqs: deploy/11_coder_server.sh (CODER_SERVER_IP + CODER_SG_ID in state.env).
#   Reach the box via SSH (EC2 Instance Connect push or an authorized key).
#
# Usage:
#   deploy/14_caddy_https.sh                # install + enable
#   deploy/14_caddy_https.sh --status       # show caddy + cert
source "$(dirname "$0")/lib.sh"

PORT=8080
DOSTATUS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --status) DOSTATUS=1; shift ;;
    *) log "unknown arg: $1"; exit 2 ;;
  esac
done

: "${CODER_SERVER_IP:?CODER_SERVER_IP not in deploy/state.env -- run deploy/11_coder_server.sh first}"
: "${CODER_SG_ID:?CODER_SG_ID not in deploy/state.env -- run deploy/11_coder_server.sh first}"

# 1. open SG 80/443 for Let's Encrypt HTTP-01 + HTTPS
log "opening inbound tcp/80 + tcp/443 on Coder SG $CODER_SG_ID ..."
for p in 80 443; do
  aws ec2 authorize-security-group-ingress --region "$AWS_REGION" \
    --group-id "$CODER_SG_ID" --protocol tcp --port "$p" --cidr 0.0.0.0/0 \
    >/dev/null 2>&1 || true
done

HOSTNAME="coder.${CODER_SERVER_IP}.nip.io"
SSH_TARGET="${CODER_SSH_USER:-ubuntu}@${CODER_SERVER_IP}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

# GitHub hook IP ranges (from api.github.com/meta) -- only these may POST
# /webhook. Everyone else gets 403 on that path; the rest of the site is open.
# Fetched locally so the heredoc below can expand ${GITHUB_HOOK_IPS}.
GITHUB_HOOK_IPS="$(curl -fsS --max-time 15 https://api.github.com/meta 2>/dev/null \
  | python3 -c "import sys,json; print(' '.join(json.load(sys.stdin).get('hooks',[])))" 2>/dev/null \
  || true)"
if [ -z "$GITHUB_HOOK_IPS" ]; then
  GITHUB_HOOK_IPS="192.30.252.0/22 185.199.108.0/22 140.82.112.0/20 143.55.64.0/20"
fi
log "GitHub hook IP ranges: $GITHUB_HOOK_IPS"

log "installing Caddy on $SSH_TARGET and writing Caddyfile (hostname=$HOSTNAME) ..."
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "bash -s" -- <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
sudo install -d -m 0755 /usr/share/keyrings
curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key 2>/dev/null \
  | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null || true
echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" \
  | sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
sudo apt-get update -qq 2>/dev/null
sudo apt-get install -y -qq caddy >/dev/null 2>&1 || sudo apt-get install -y -qq caddy

sudo tee /etc/caddy/Caddyfile >/dev/null <<CADDY
${HOSTNAME} {
	encode zstd gzip

	# GitHub webhook -> odoo-synth listener (localhost only). Restricted to
	# GitHub's hook IP ranges; everyone else gets 403. The listener additionally
	# verifies the HMAC signature + dedupes by X-GitHub-Delivery.
	@github_webhook {
		path /webhook
		remote_ip ${GITHUB_HOOK_IPS}
	}
	handle @github_webhook {
		reverse_proxy 127.0.0.1:${PORT} {
			flush_interval -1
			header_up X-Forwarded-Proto https
			header_up X-Forwarded-Host ${HOSTNAME}
		}
	}
	# /webhook from a non-GitHub IP -> 403 (must come before the catch-all)
	@webhook_path path /webhook
	handle @webhook_path {
		respond 403
	}
	# everything else -> the Coder HTTP server (dashboard + API)
	handle {
		reverse_proxy 127.0.0.1:8943 {
			flush_interval -1
			header_up Host ${CODER_SERVER_IP}:8943
			header_up X-Forwarded-Proto https
			header_up X-Forwarded-Host ${HOSTNAME}
		}
	}
}
CADDY
sudo caddy validate --config /etc/caddy/Caddyfile 2>&1 | grep -qi "valid" && echo "caddy config valid"
sudo systemctl enable --now caddy >/dev/null 2>&1
sudo systemctl reload caddy 2>/dev/null || sudo systemctl restart caddy
echo "caddy active: \$(sudo systemctl is-active caddy)"
REMOTE

log "HTTPS is live at https://$HOSTNAME/ (Coder HTTP on :8943 untouched)."
log "Point config.yaml / webhooks at: https://$HOSTNAME"

# ---------------------------------------------------------------------------
# 2. install the GitHub-IP auto-refresh renderer + a systemd timer (every 6h +
#    2min after boot). The renderer fetches api.github.com/meta, re-renders the
#    Caddyfile, and reloads Caddy ONLY when the ranges changed (idempotent). On
#    a fetch failure it keeps the existing allowlist (fail-closed/stale > broken).
#    The renderer becomes the source of truth for the Caddyfile, so the inline
#    one above is just the bootstrap.
# ---------------------------------------------------------------------------
log "installing GitHub-IP auto-refresh (refresh-github-ips.timer, every 6h) ..."
scp "${SSH_OPTS[@]}" "$HERE/deploy/refresh/refresh_github_ips.py" \
  "$SSH_TARGET:/tmp/refresh_github_ips.py" 2>/dev/null \
  || rsync -e "ssh ${SSH_OPTS[*]}" -q "$HERE/deploy/refresh/refresh_github_ips.py" \
       "$SSH_TARGET:/tmp/refresh_github_ips.py"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "bash -s" -- "$HOSTNAME" "$PORT" <<'REMOTE'
set -euo pipefail
HOSTNAME="$1"; PORT="$2"; CODER_IP="$(echo "$HOSTNAME" | sed -E 's/^coder\.([0-9.]+)\.nip\.io$/\1/')"
sudo install -m 0755 /tmp/refresh_github_ips.py /usr/local/sbin/refresh_github_ips.py
sudo tee /etc/caddy/refresh.env >/dev/null <<EOF
CODER_SERVER_IP=$CODER_IP
CADDY_HOSTNAME=$HOSTNAME
WEBHOOK_PORT=$PORT
EOF
sudo tee /etc/systemd/system/refresh-github-ips.service >/dev/null <<UNIT
[Unit]
Description=Refresh GitHub hook IP ranges in the Caddy Caddyfile
After=network-online.target caddy.service
Wants=network-online.target
[Service]
Type=oneshot
EnvironmentFile=/etc/caddy/refresh.env
ExecStart=/usr/local/sbin/refresh_github_ips.py
UNIT
sudo tee /etc/systemd/system/refresh-github-ips.timer >/dev/null <<TIMER
[Unit]
Description=Refresh GitHub hook IP ranges every 6h
[Timer]
OnBootSec=2min
OnUnitActiveSec=6h
Persistent=true
[Install]
WantedBy=timers.target
TIMER
sudo systemctl daemon-reload
sudo systemctl enable --now refresh-github-ips.timer >/dev/null 2>&1
sudo systemctl start refresh-github-ips.service || true
echo "refresh timer: $(systemctl is-active refresh-github-ips.timer)"
REMOTE
