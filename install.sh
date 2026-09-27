#!/usr/bin/env bash
# Family GPS installer. Safe to re-run: it updates files and keeps data/ and .env.
#
# Fresh install (auth key from https://login.tailscale.com/admin/settings/keys):
#   curl -fsSL https://raw.githubusercontent.com/knucklehead96/family-gps/main/install.sh | sudo bash -s -- --authkey tskey-auth-XXXX
# Move to a new server (restore a `fgps backup` file; no key needed):
#   curl -fsSL https://raw.githubusercontent.com/knucklehead96/family-gps/main/install.sh | sudo bash -s -- --restore ./family-gps-backup.tgz
# Update an existing install:
#   fgps update
set -euo pipefail

# Everything runs inside main() so bash has read the whole script before any
# command can consume stdin (which is the script itself under `curl | bash`).
main() {
  REPO="${FGPS_REPO:-knucklehead96/family-gps}"
  BRANCH="${FGPS_BRANCH:-main}"
  DIR="${FGPS_DIR:-/opt/family-gps}"
  RESTORE=""
  TS_AUTHKEY="${TS_AUTHKEY:-}"

  while [ $# -gt 0 ]; do
    case "$1" in
      --authkey) TS_AUTHKEY="$2"; shift 2 ;;
      --restore) RESTORE="$(readlink -f "$2")"; shift 2 ;;
      --dir) DIR="$2"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done

  [ "$(id -u)" -eq 0 ] || die "run as root: curl ... | sudo bash -s -- ..."
  [ -z "$RESTORE" ] || [ -f "$RESTORE" ] || die "backup not found: $RESTORE"

  # Tailscale identity comes from an existing install, a backup, or a fresh auth key.
  # Check before anything slow happens.
  if [ ! -s "$DIR/data/tailscale/tailscaled.state" ] && [ -z "$RESTORE" ] && [ -z "$TS_AUTHKEY" ]; then
    if [ -t 0 ]; then
      auth_help
      read -r -p 'Auth key (tskey-auth-...): ' TS_AUTHKEY
    fi
    if [ -z "$TS_AUTHKEY" ]; then
      auth_help
      cat >&2 <<EOF
Then run:
  curl -fsSL https://raw.githubusercontent.com/$REPO/$BRANCH/install.sh | sudo bash -s -- --authkey tskey-auth-XXXX
EOF
      exit 1
    fi
  fi
  export TS_AUTHKEY

  install_deps
  fetch_files
  cd "$DIR"
  prepare_data

  log "Downloading container images (a few minutes on a Pi)"
  docker compose pull
  log "Starting containers"
  docker compose up -d --remove-orphans

  log "Waiting for Tailscale"
  local domain=""
  for _ in $(seq 60); do
    domain="$(fgps domain 2>/dev/null || true)"
    [ -n "$domain" ] && break
    sleep 2
  done
  [ -n "$domain" ] || die "Tailscale did not come up (bad or used auth key?). Check: fgps logs tailscale"
  log "Tailscale up: $domain"
  if ! docker compose exec -T tailscale tailscale status --json </dev/null \
      | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("CertDomains") else 1)'; then
    warn "HTTPS certificates are not enabled, so Funnel can't start."
    warn "Enable them: https://login.tailscale.com/admin/dns -> HTTPS Certificates, then run: fgps restart"
  fi

  log "Configuring logins and alerts"
  fgps init </dev/null

  if [ ! -s data/users.txt ] && [ -t 0 ]; then
    echo
    log "Add family members (one per phone). Leave blank to finish."
    local name
    while read -r -p 'Name (lowercase, e.g. alice): ' name && [ -n "$name" ]; do
      fgps add "$name" || true
    done
  fi

  log "Checking the public endpoint (first HTTPS certificate can take a minute)"
  local code=""
  for _ in $(seq 30); do
    code="$(curl -s -m 10 -o /dev/null -w '%{http_code}' "https://$domain/pub" || true)"
    { [ "$code" = 401 ] || [ "$code" = 403 ]; } && break
    sleep 5
  done
  if [ "$code" = 401 ] || [ "$code" = 403 ]; then
    log "Funnel OK"
  else
    warn "https://$domain/pub not reachable yet (got '$code'). Check Funnel is allowed in the policy; then: fgps status"
  fi

  cat <<EOF

Done.
  Phones send to : https://$domain/pub    (public via Funnel, password protected)
  Alerts (ntfy)  : https://$domain        (public, login required)
  Map (tailnet)  : https://$domain:8443   (open from a device on your tailnet)

Next:
  fgps add <name>                     add a family phone (shows its setup QR code)
  fgps place add "Home" <lat> <lon>   geofences for arrive/leave alerts
  fgps notify add <name>              who receives the alerts
  fgps qr <name>                      re-scan on each phone after adding places
  fgps help                           all commands (backup, restore, uninstall, ...)

Tip: in the Tailscale admin console, "Disable key expiry" for this machine
so Funnel doesn't stop in 180 days.
EOF
}

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

auth_help() {
  cat >&2 <<'EOF'

Tailscale needs a one-time auth key for this server:
  https://login.tailscale.com/admin/settings/keys  ->  "Generate auth key"
  (not reusable, not ephemeral, no tags)
Also in the admin console:
  DNS             -> enable MagicDNS and HTTPS Certificates
  Access controls -> JSON editor: nodeAttrs must grant "funnel" to autogroup:member

EOF
}

install_deps() {
  if command -v apt-get >/dev/null; then
    local p missing=""
    for p in curl qrencode python3; do command -v "$p" >/dev/null || missing="$missing $p"; done
    if [ -n "$missing" ]; then
      log "Installing$missing"
      apt-get update -qq </dev/null && apt-get install -y -qq $missing </dev/null >/dev/null
    fi
  fi
  if ! command -v docker >/dev/null; then
    log "Installing Docker (a few minutes)"
    curl -fsSL https://get.docker.com | sh
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
}

fetch_files() {
  log "Downloading $REPO@$BRANCH to $DIR"
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH" | tar -xz -C "$tmp" --strip-components=1
  mkdir -p "$DIR"
  cp -a "$tmp/." "$DIR/"
  rm -rf "$tmp"
  chmod +x "$DIR/fgps" "$DIR/install.sh"
  ln -sf "$DIR/fgps" /usr/local/bin/fgps
}

prepare_data() {
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
    local tz
    tz="$(cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone --value 2>/dev/null || echo UTC)"
    cat > .env <<EOF
TS_HOSTNAME=mrn-pi
TZ=$tz
FGPS_REPO=$REPO
FGPS_BRANCH=$BRANCH
EOF
    chmod 600 .env
  fi
}

main "$@"
