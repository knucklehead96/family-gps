#!/usr/bin/env bash
# Family GPS installer. Safe to re-run: it updates files and keeps data/ and .env.
#
# Fresh install:
#   curl -fsSL https://raw.githubusercontent.com/knucklehead96/family-gps/main/install.sh | sudo bash
# Move to a new server (restore a `fgps backup` file):
#   curl -fsSL https://raw.githubusercontent.com/knucklehead96/family-gps/main/install.sh | sudo bash -s -- --restore ./family-gps-backup.tgz
set -euo pipefail

REPO="${FGPS_REPO:-knucklehead96/family-gps}"
BRANCH="${FGPS_BRANCH:-main}"
DIR="${FGPS_DIR:-/opt/family-gps}"
RESTORE=""

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
# stdin is the script itself under `curl | bash`, so prompts read from the terminal.
ask() { local v=""; [ -r /dev/tty ] && read -r -p "$1" v </dev/tty; printf '%s' "$v"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --restore) RESTORE="$(readlink -f "$2")"; shift 2 ;;
    --dir) DIR="$2"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root: curl ... | sudo bash"
[ -z "$RESTORE" ] || [ -f "$RESTORE" ] || die "backup not found: $RESTORE"

# --- dependencies -----------------------------------------------------------
if command -v apt-get >/dev/null; then
  missing=""
  for p in curl qrencode python3; do command -v "$p" >/dev/null || missing="$missing $p"; done
  if [ -n "$missing" ]; then
    log "Installing$missing"
    apt-get update -qq && apt-get install -y -qq $missing >/dev/null
  fi
fi
if ! command -v docker >/dev/null; then
  log "Installing Docker"
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker >/dev/null 2>&1 || true

# --- files ------------------------------------------------------------------
log "Downloading $REPO@$BRANCH to $DIR"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH" | tar -xz -C "$tmp" --strip-components=1
mkdir -p "$DIR"
cp -a "$tmp/." "$DIR/"
chmod +x "$DIR/fgps" "$DIR/install.sh"
ln -sf "$DIR/fgps" /usr/local/bin/fgps
cd "$DIR"

if [ -n "$RESTORE" ]; then
  if [ -d data ] && [ -n "$(ls -A data 2>/dev/null)" ]; then
    die "$DIR/data already exists; remove it first (or use: fgps restore <file>)"
  fi
  log "Restoring $RESTORE"
  tar -xzf "$RESTORE" -C "$DIR"
fi

mkdir -p data/store data/tailscale data/auth data/caddy data/ntfy data/secrets
chmod 700 data
[ -f data/users.txt ] || : > data/users.txt
[ -f data/auth/users.caddy ] || echo 'respond "no users yet" 403' > data/auth/users.caddy

if [ ! -f .env ]; then
  tz="$(cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone --value 2>/dev/null || echo UTC)"
  cat > .env <<EOF
TS_HOSTNAME=mrn-pi
TZ=$tz
FGPS_REPO=$REPO
FGPS_BRANCH=$BRANCH
EOF
  chmod 600 .env
fi

# --- tailscale login (first run only; identity then lives in data/tailscale) --
if [ ! -s data/tailscale/tailscaled.state ] && [ -z "${TS_AUTHKEY:-}" ]; then
  cat <<'EOF'

Tailscale needs a one-time auth key for this server:
  https://login.tailscale.com/admin/settings/keys  ->  "Generate auth key"
  (not reusable, not ephemeral, no tags)
Before continuing, in the admin console also enable:
  DNS page -> MagicDNS and HTTPS Certificates
  Access controls -> Funnel (the console offers to add it on first use)

EOF
  TS_AUTHKEY="$(ask 'Auth key (tskey-auth-...): ')"
  [ -n "$TS_AUTHKEY" ] || die "no auth key given"
fi
export TS_AUTHKEY="${TS_AUTHKEY:-}"

# --- start ------------------------------------------------------------------
log "Starting containers"
docker compose pull -q
docker compose up -d --remove-orphans

log "Waiting for Tailscale"
domain=""
for _ in $(seq 60); do
  domain="$(fgps domain 2>/dev/null || true)"
  [ -n "$domain" ] && break
  sleep 2
done
[ -n "$domain" ] || die "Tailscale did not come up; check: fgps logs tailscale"

log "Configuring logins and alerts"
fgps init

if [ ! -s data/users.txt ] && [ -r /dev/tty ]; then
  echo
  log "Add family members (one per phone). Leave blank to finish."
  while name="$(ask 'Name (lowercase, e.g. alice): ')" && [ -n "$name" ]; do
    fgps add "$name" || true
  done
fi

log "Checking the public endpoint (first HTTPS certificate can take a minute)"
code=""
for _ in $(seq 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "https://$domain/pub" || true)"
  [ "$code" = 401 ] || [ "$code" = 403 ] && break
  sleep 5
done
if [ "$code" = 401 ] || [ "$code" = 403 ]; then
  log "Funnel OK"
else
  warn "https://$domain/pub not reachable yet (got '$code'). Funnel DNS can take ~10 min; check: fgps status"
fi

cat <<EOF

Done.
  Phones send to : https://$domain/pub    (public via Funnel, password protected)
  Alerts (ntfy)  : https://$domain        (public, login required)
  Map (tailnet)  : https://$domain:8443   (open from a device on your tailnet)

Next:
  fgps place add "Home" <lat> <lon>   geofences for arrive/leave alerts
  fgps notify add <name>              who receives the alerts
  fgps qr <name>                      re-scan on each phone after adding places
  fgps help                           all commands (backup, restore, uninstall, ...)

Tip: in the Tailscale admin console, "Disable key expiry" for this machine
so Funnel doesn't stop in 180 days.
EOF
