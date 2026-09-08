#!/usr/bin/env bash
#
# Prowlarr + search endpoint, on a fresh server, in one command.
#
#   bash install.sh                 → plain HTTP on this server's IP
#   DOMAIN=search.example.com bash install.sh   → HTTPS, certificate and all
#
# Run it again any time: it keeps your keys and your indexers, and picks up a
# newer Prowlarr and a newer bridge.

set -euo pipefail

cd "$(dirname "$0")"

DOMAIN_GIVEN="${DOMAIN:-}"
BRIDGE_SOURCE="https://raw.githubusercontent.com/momzv2022-ctrl/prowlarr-bridge/main/worker/src/worker.js"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run this as root: sudo bash install.sh"

# ---------------------------------------------------------------------------
# 1. Docker
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  say "Installing Docker"
  curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is missing. Install docker-compose-plugin."

# ---------------------------------------------------------------------------
# 2. Secrets — made once, then left alone on every later run
# ---------------------------------------------------------------------------
rand() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

mkdir -p prowlarr/config caddy bridge

if [ -f .env ]; then
  say "Keeping the keys already in .env"
  # shellcheck disable=SC1091
  . ./.env
  DOMAIN="${DOMAIN_GIVEN:-${DOMAIN:-}}"
else
  DOMAIN="${DOMAIN_GIVEN}"
  say "Making your keys"
  PROWLARR_API_KEY="$(rand 16)"
  BRIDGE_API_KEY="$(rand 16)"
  PROWLARR_USER="admin"
  PROWLARR_PASSWORD="$(rand 9)"
fi

# The address Caddy answers on. A domain gets a real certificate; without one
# there is nothing to put a certificate on, so it is plain HTTP.
if [ -n "$DOMAIN" ]; then
  SITE_ADDRESS="$DOMAIN"
  PUBLIC_URL="https://$DOMAIN"
else
  SITE_ADDRESS=":80"
  PUBLIC_URL="http://$(curl -fsS --max-time 10 https://api.ipify.org || echo 'YOUR-SERVER-IP')"
fi

cat > .env <<ENV
# Made by install.sh. Keep it: it is the only copy of your keys.
DOMAIN=${DOMAIN}
SITE_ADDRESS=${SITE_ADDRESS}
PROWLARR_API_KEY=${PROWLARR_API_KEY}
BRIDGE_API_KEY=${BRIDGE_API_KEY}
PROWLARR_USER=${PROWLARR_USER}
PROWLARR_PASSWORD=${PROWLARR_PASSWORD}
ENV
chmod 600 .env

# ---------------------------------------------------------------------------
# 3. Caddy's config
# ---------------------------------------------------------------------------
# Written here rather than shipped, because the password hash belongs in it and
# a bcrypt hash is full of `$` — which compose would read as variables.
say "Configuring the front door"
PROWLARR_PASSWORD_HASH="$(docker run --rm caddy:2-alpine \
  caddy hash-password --plaintext "$PROWLARR_PASSWORD")"

cat > caddy/Caddyfile <<CADDY
${SITE_ADDRESS} {
	# Prowlarr's own interface, behind a password. Prowlarr is set to
	# \`External\` auth, which means it does no checking of its own and trusts
	# whatever reaches it — so this block is the only thing standing in front
	# of it. Do not remove it.
	handle /prowlarr* {
		basic_auth {
			${PROWLARR_USER} ${PROWLARR_PASSWORD_HASH}
		}
		reverse_proxy prowlarr:9696
	}

	# The search endpoint. No password here: it carries its own key, and an
	# app cannot send a browser login.
	handle {
		reverse_proxy bridge:8788
	}

	encode gzip
	log {
		output file /var/log/caddy/access.log
		format console
	}
}
CADDY

# ---------------------------------------------------------------------------
# 4. Prowlarr's config, written before its first start
# ---------------------------------------------------------------------------
# Writing this now rather than clicking through the setup wizard is what makes
# the install one command. It also means Prowlarr never exists in an
# unauthenticated state: `External` says "the proxy in front handles logins",
# and Caddy is already asking for one.
if [ ! -f prowlarr/config/config.xml ]; then
  say "Configuring Prowlarr"
  cat > prowlarr/config/config.xml <<XML
<Config>
  <BindAddress>*</BindAddress>
  <Port>9696</Port>
  <UrlBase>/prowlarr</UrlBase>
  <ApiKey>${PROWLARR_API_KEY}</ApiKey>
  <AuthenticationMethod>External</AuthenticationMethod>
  <AuthenticationRequired>Enabled</AuthenticationRequired>
  <LogLevel>info</LogLevel>
  <InstanceName>Prowlarr</InstanceName>
  <AnalyticsEnabled>False</AnalyticsEnabled>
</Config>
XML
fi

# ---------------------------------------------------------------------------
# 5. The bridge — one file, no dependencies
# ---------------------------------------------------------------------------
say "Fetching the bridge"
curl -fsSL -o bridge/worker.js "$BRIDGE_SOURCE" || die "Could not fetch the bridge from $BRIDGE_SOURCE"

# ---------------------------------------------------------------------------
# 6. Firewall, if this box has one
# ---------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1; then
  say "Opening 80 and 443, and nothing else"
  ufw allow 22/tcp >/dev/null 2>&1 || true
  ufw allow 80/tcp >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# 7. Up
# ---------------------------------------------------------------------------
say "Starting"
docker compose pull --quiet 2>/dev/null || docker compose pull
docker compose up -d

printf '  waiting for Prowlarr'
for _ in $(seq 1 90); do
  if [ "$(docker inspect --format '{{.State.Health.Status}}' prowlarr 2>/dev/null)" = "healthy" ]; then
    READY=1; break
  fi
  printf '.'; sleep 2
done
printf '\n'
[ "${READY:-0}" = "1" ] || die "Prowlarr did not start. Look at: docker compose logs prowlarr"

# ---------------------------------------------------------------------------
# 8. What you came for
# ---------------------------------------------------------------------------
cat <<DONE

────────────────────────────────────────────────────────────────────
  Search endpoint   ${PUBLIC_URL}
  Key               ${BRIDGE_API_KEY}

  Prowlarr          ${PUBLIC_URL}/prowlarr
  Username          ${PROWLARR_USER}
  Password          ${PROWLARR_PASSWORD}
────────────────────────────────────────────────────────────────────

  Add your indexers in Prowlarr. The endpoint searches whatever is
  enabled there, straight away — nothing to restart, nothing to
  re-copy.

  Try it:
    curl -H "X-API-Key: ${BRIDGE_API_KEY}" \\
      "${PUBLIC_URL}/api/v1/search?q=big+buck+bunny&limit=3"

DONE

if [ -z "$DOMAIN" ]; then
  cat <<'WARN'
  ⚠  This is plain HTTP, so that password and that key cross the
     network in the clear. Point a domain at this server and run
     again with DOMAIN=search.example.com for a real certificate.

WARN
fi

echo "  Keys are in .env. Update everything later with: bash install.sh"
echo
