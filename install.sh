#!/usr/bin/env bash
#
# Prowlarr + search endpoint, on a fresh server, in one command.
#
#   bash install.sh                           → HTTPS on a name made from your IP
#   DOMAIN=search.example.com bash install.sh  → HTTPS on your own name
#   NO_TLS=1 bash install.sh                   → plain HTTP, no certificate
#
# Run it again any time: it keeps your keys and your indexers, and picks up a
# newer Prowlarr and a newer bridge.

set -euo pipefail

cd "$(dirname "$0")"

DOMAIN_GIVEN="${DOMAIN:-}"
BRIDGE_SOURCE="https://raw.githubusercontent.com/momzv2022-ctrl/prowlarr-bridge/main/worker/src/worker.js"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run this as root: sudo bash install.sh"

# A timer runs update.sh as root every day. If this directory belongs to an
# ordinary user — which it does when you `git clone` before `sudo bash` — then
# that user can rewrite what root is about to execute. Take ownership.
if [ "$(stat -c %u . 2>/dev/null || echo 0)" != "0" ]; then
  say "Taking ownership of this directory, since root runs update.sh from it"
  chown -R root:root .
  chmod -R go-w .
  echo "  (use sudo git pull here from now on)"
fi

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
  # A domain on the command line beats the one remembered here, so it can be
  # changed. Only an explicitly given domain is ever stored: the one derived
  # from your IP is worked out afresh each run, so moving server just works.
  DOMAIN="${DOMAIN_GIVEN:-${DOMAIN:-}}"
else
  say "Making your keys"
  # If Prowlarr already exists, its key is the one that counts — minting a new
  # one here would leave the bridge holding a key Prowlarr has never heard of,
  # and every search would come back 401 for no visible reason.
  # `|| true` matters: with pipefail, sed failing on a missing config.xml would
  # take the whole pipeline's status, and set -e would end the script here.
  PROWLARR_API_KEY="$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' \
    prowlarr/config/config.xml 2>/dev/null | head -1 || true)"
  if [ -n "$PROWLARR_API_KEY" ]; then
    echo "  adopting the API key Prowlarr already has"
  else
    PROWLARR_API_KEY="$(rand 16)"
  fi
  BRIDGE_API_KEY="$(rand 16)"
  PROWLARR_USER="admin"
  PROWLARR_PASSWORD="$(rand 9)"
  DOMAIN="${DOMAIN_GIVEN}"
fi


# ---------------------------------------------------------------------------
# 3. What name to answer on, and the file that remembers it
# ---------------------------------------------------------------------------
# A phone will not talk to a plain-HTTP endpoint — Android has refused cleartext
# by default since Android 9 — so a certificate is not a nicety here, it is the
# difference between working and not. A certificate needs a name, and a bare IP
# cannot get one from Let's Encrypt through Caddy today.
#
# So when you have not given a name, one is made from your address: sslip.io
# resolves 1-2-3-4.sslip.io to 1.2.3.4, with no account and no signup. It costs
# one dependency worth knowing about — see README.
PUBLIC_IP="$(curl -fsS --max-time 10 https://api.ipify.org \
  || curl -fsS --max-time 10 https://ifconfig.me/ip \
  || echo '')"
PUBLIC_IP="$(printf '%s' "$PUBLIC_IP" | tr -dc '0-9.')"

# NO_TLS is checked FIRST so it still works on a box that has a DOMAIN stored.
if [ "${NO_TLS:-}" = "1" ]; then
  HOST=""; TLS=no
elif [ -n "$DOMAIN" ]; then
  HOST="$DOMAIN"; TLS=yes
elif [ -n "$PUBLIC_IP" ]; then
  HOST="$(echo "$PUBLIC_IP" | tr '.' '-').sslip.io"; TLS=yes
elif [ -n "${LAST_HOST:-}" ]; then
  # Both address lookups failed. Falling back to plain HTTP here would put
  # Prowlarr's admin page — password and all — on an unencrypted port, so keep
  # the name that already works instead.
  warn "Could not look up this server's address; keeping ${LAST_HOST}."
  HOST="$LAST_HOST"; TLS=yes
else
  warn "Could not work out this server's public address; staying on plain HTTP."
  HOST=""; TLS=no
fi

# Anything else already in .env — speed settings you have tuned, or an image
# pinned by a rollback — is carried across. Rewriting only the keys this script
# owns means re-running it never undoes your own edits.
KEPT=""
if [ -f .env ]; then
  KEPT="$(grep -vE '^\s*(#|$)|^(DOMAIN|LAST_HOST|PROWLARR_API_KEY|BRIDGE_API_KEY|PROWLARR_USER|PROWLARR_PASSWORD)=' .env || true)"
fi

cat > .env <<ENV
# Made by install.sh. Keep it: it is the only copy of your keys.
DOMAIN=${DOMAIN}
PROWLARR_API_KEY=${PROWLARR_API_KEY}
BRIDGE_API_KEY=${BRIDGE_API_KEY}
PROWLARR_USER=${PROWLARR_USER}
PROWLARR_PASSWORD=${PROWLARR_PASSWORD}
LAST_HOST=${HOST}

# Speed. Unset means the default in the comment.
#PROWLARR_INDEXER_IDS=      # only these indexer ids, comma separated. Empty = all
#BRIDGE_MAX_ROWS=100        # rows asked of each indexer
#BRIDGE_MAX_RESOLVE=12      # .torrent files read per page, for private trackers
#BRIDGE_TIMEOUT_S=45        # how long to wait for Prowlarr
ENV
[ -z "$KEPT" ] || printf '\n%s\n' "$KEPT" >> .env
chmod 600 .env

# ---------------------------------------------------------------------------
# 4. Caddy's config
# ---------------------------------------------------------------------------
# Written here rather than shipped, because the password hash belongs in it and
# a bcrypt hash is full of `$` — which compose would read as variables.
say "Configuring the front door"
# Fed on stdin, not as an argument: an argument is visible to anyone who runs
# `ps` on this box for as long as the command lasts.
# The trailing newline matters: without it caddy sits waiting for the rest of
# the line and gives up with "Error: EOF".
PROWLARR_PASSWORD_HASH="$(printf '%s\n' "$PROWLARR_PASSWORD" \
  | docker run --rm -i caddy:2-alpine caddy hash-password)"
[ -n "$PROWLARR_PASSWORD_HASH" ] || die "Could not hash the Prowlarr password."

{
  cat <<CADDY
(bridge_routes) {
	# The search endpoint. No password: it carries its own key, and an app
	# cannot send a browser login.
	handle {
		reverse_proxy bridge:8788
	}
	encode gzip
}

CADDY

  if [ "$TLS" = "yes" ]; then
    cat <<CADDY
${HOST} {
	# Prowlarr's own interface, behind a password. Prowlarr is set to
	# \`External\` auth, which means it does no checking of its own and
	# trusts whatever reaches it — so this block is the only thing standing
	# in front of it. Do not remove it.
	handle /prowlarr* {
		basic_auth {
			${PROWLARR_USER} ${PROWLARR_PASSWORD_HASH}
		}
		reverse_proxy prowlarr:9696
	}
	import bridge_routes
}

# Plain HTTP, reachable by IP, so a client that cannot do TLS still has a way in
# and a failed certificate does not leave you with nothing. Prowlarr is
# deliberately absent here: its password must never cross an unencrypted link.
http:// {
	import bridge_routes
}
CADDY
  else
    cat <<CADDY
:80 {
	handle /prowlarr* {
		basic_auth {
			${PROWLARR_USER} ${PROWLARR_PASSWORD_HASH}
		}
		reverse_proxy prowlarr:9696
	}
	import bridge_routes
}
CADDY
  fi
} > caddy/Caddyfile

# A broken Caddyfile takes the whole thing down, so check it before starting.
docker run --rm -v "$PWD/caddy/Caddyfile:/etc/caddy/Caddyfile:ro" caddy:2-alpine \
  caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile >/dev/null 2>&1 \
  || die "The generated caddy/Caddyfile is not valid. Please open an issue with it attached."

# ---------------------------------------------------------------------------
# 5. Prowlarr's config, written before its first start
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
# 6. The bridge — one file, no dependencies
# ---------------------------------------------------------------------------
say "Fetching the bridge"
# To a temporary file first: a failed download must not truncate the copy that
# works. Then written INTO the existing file rather than moved over it, because
# Docker binds a single-file mount to the inode and would not follow a move.
curl -fsSL -o bridge/worker.js.new "$BRIDGE_SOURCE" \
  || die "Could not fetch the bridge from $BRIDGE_SOURCE"
if [ ! -s bridge/worker.js.new ] || [ "$(wc -c < bridge/worker.js.new)" -lt 40000 ] \
   || ! grep -q 'Prowlarr bridge' bridge/worker.js.new; then
  rm -f bridge/worker.js.new
  [ -s bridge/worker.js ] || die "What came back from $BRIDGE_SOURCE is not the bridge."
  warn "What came back does not look like the bridge; keeping the copy that works."
else
  cat bridge/worker.js.new > bridge/worker.js
  rm -f bridge/worker.js.new
fi

# ---------------------------------------------------------------------------
# 7. Firewall, if this box has one
# ---------------------------------------------------------------------------
# Rules are added only to a firewall that is ALREADY on. Turning ufw on here
# would apply its default deny-incoming with only these rules — and if sshd
# listens anywhere but 22, which is a common hardening step, that locks you out
# of your own server with no way back in.
if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'; then
  say "Adding ufw rules for 80 and 443"
  ufw allow 80/tcp >/dev/null || warn "could not add the ufw rule for 80"
  ufw allow 443/tcp >/dev/null || warn "could not add the ufw rule for 443"
elif command -v ufw >/dev/null 2>&1; then
  echo "  ufw is installed but not active; leaving it alone."
  echo "  If you turn it on, allow 80 and 443 — and your SSH port."
fi

# ---------------------------------------------------------------------------
# 8. Keep it up to date by itself
# ---------------------------------------------------------------------------
# Prowlarr's indexer definitions ship inside its image, so "update Prowlarr" and
# "fix the indexers that broke this month" are the same action. Left alone, this
# rots. update.sh backs up and rolls back on failure, so it is safe unattended.
if [ "${NO_AUTOUPDATE:-}" = "1" ]; then
  say "Automatic updates off (NO_AUTOUPDATE=1). Run bash update.sh yourself."
elif command -v systemctl >/dev/null 2>&1; then
  say "Setting up daily updates"
  cat > /etc/systemd/system/prowlarr-utsi-update.service <<UNIT
[Unit]
Description=Update Prowlarr and the search bridge
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
WorkingDirectory=${PWD}
ExecStart=/usr/bin/env bash ${PWD}/update.sh
UNIT

  # Spread out across the day so everyone running this does not hit the
  # registry at midnight together.
  cat > /etc/systemd/system/prowlarr-utsi-update.timer <<UNIT
[Unit]
Description=Update Prowlarr and the search bridge daily

[Timer]
OnCalendar=daily
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
UNIT

  systemctl daemon-reload
  systemctl enable --now prowlarr-utsi-update.timer >/dev/null 2>&1 || true
elif command -v crontab >/dev/null 2>&1; then
  say "Setting up daily updates (cron)"
  ( crontab -l 2>/dev/null | grep -v 'prowlarr-utsi update' || true
    printf '%s\n' "$((RANDOM % 60)) 4 * * * cd ${PWD} && /usr/bin/env bash update.sh >> ${PWD}/update.log 2>&1 # prowlarr-utsi update"
  ) | crontab -
else
  warn "No systemd or cron here, so updates are manual: bash update.sh"
fi

# ---------------------------------------------------------------------------
# 9. Up
# ---------------------------------------------------------------------------
say "Starting"
docker compose pull --quiet 2>/dev/null || docker compose pull
docker compose up -d
# node read worker.js at startup and compose will not recreate the container
# just because a mounted file changed, so a re-run would otherwise keep serving
# whichever bridge happened to be running.
docker compose up -d --force-recreate --no-deps bridge >/dev/null 2>&1 || true

# Caddy parses its config once, at start, and compose will not recreate the
# container just because a mounted file changed — so without this a re-run that
# changed DOMAIN or NO_TLS would write a correct Caddyfile that Caddy never
# reads, then spend nine minutes failing to find a certificate for a site it
# was never told about. Reloading in place keeps the certificate store.
docker compose exec -T caddy caddy reload --adapter caddyfile --config /etc/caddy/Caddyfile >/dev/null 2>&1 \
  || docker compose up -d --force-recreate --no-deps caddy >/dev/null 2>&1 \
  || warn "Could not reload Caddy; run: docker compose up -d --force-recreate --no-deps caddy"

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
# 10. Did the certificate actually arrive?
# ---------------------------------------------------------------------------
# Worth checking rather than assuming. Caddy keeps serving plain HTTP whatever
# happens, so a silent failure here looks like a working install right up until
# the app says it cannot connect.
CERT_OK=0
if [ "$TLS" = "yes" ]; then
  printf '  getting a certificate for %s' "$HOST"
  for _ in $(seq 1 45); do
    # --resolve sends the right name to our own Caddy, without depending on
    # this server being able to reach its own public address.
    if curl -sS --max-time 8 --resolve "${HOST}:443:127.0.0.1" \
        -o /dev/null "https://${HOST}/healthz" 2>/dev/null; then
      CERT_OK=1; break
    fi
    printf '.'; sleep 4
  done
  printf '\n'
fi

if [ "$TLS" = "yes" ] && [ "$CERT_OK" = "1" ]; then
  PUBLIC_URL="https://${HOST}"
else
  PUBLIC_URL="http://${PUBLIC_IP:-YOUR-SERVER-IP}"
fi

# ---------------------------------------------------------------------------
# 11. What you came for
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

if [ "$TLS" = "yes" ] && [ "$CERT_OK" != "1" ]; then
  warn "  ⚠  No certificate arrived for ${HOST}, so this is plain HTTP."
  echo "     Phones will refuse it: Android blocks cleartext by default."
  echo
  echo "     Usually one of:"
  echo "       • port 80 is not reachable from the internet — check your"
  echo "         provider's firewall as well as this server's"
  echo "       • ${HOST} does not resolve here yet"
  echo "       • sslip.io's weekly certificate quota is used up, which"
  echo "         happens occasionally and is shared by everyone using it"
  echo
  echo "     What Caddy thought:   docker compose logs caddy | grep -i acme"
  echo "     Try again:            bash install.sh"
  echo "     Or use your own name: DOMAIN=search.example.com bash install.sh"
  echo
elif [ "$TLS" != "yes" ]; then
  warn "  ⚠  Plain HTTP, so that password and that key cross the network in"
  echo "     the clear, and phones will refuse it outright."
  echo "     Re-run without NO_TLS=1 to get a certificate automatically."
  echo
fi

cat <<'NOTE'
  Keys are in .env. Prowlarr and the bridge update themselves daily;
  run `bash update.sh` to do it now, or read update.log / journalctl
  -u prowlarr-utsi-update to see how it went.

  Stopping: use `docker compose down`. Not `docker compose down -v` — that
  deletes the certificate along with everything else, and Let's Encrypt
  allows only five per name per week, so repeated wipes lock you out of
  your own address for a day at a time.

NOTE
