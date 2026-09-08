#!/usr/bin/env bash
#
# Pull a newer Prowlarr and a newer bridge, and put them back if they break.
#
# install.sh runs this daily on a timer. It is safe to run by hand any time.
#
# Why this matters more than an ordinary update: Prowlarr ships its indexer
# definitions INSIDE the release image. There is no separate "update indexers"
# step, and the built-in updater is disabled under Docker. So pulling a new
# image is how a broken tracker gets fixed, and how a definition schema bump
# reaches you. A Prowlarr pinned for a year is a Prowlarr whose indexers have
# quietly stopped working.

set -euo pipefail

cd "$(dirname "$0")"

BRIDGE_SOURCE="https://raw.githubusercontent.com/momzv2022-ctrl/prowlarr-bridge/main/worker/src/worker.js"
BACKUPS=backups
KEEP=10
STAMP="$(date +%Y%m%d-%H%M%S)"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# Is this actually the bridge, and not an error page or half a download?
bridge_sane() {
  [ -s "$1" ] || return 1
  [ "$(wc -c < "$1")" -gt 40000 ] || return 1
  grep -q 'Prowlarr bridge' "$1" || return 1
}

[ -f .env ] || { log "no .env here — run install.sh first"; exit 1; }

mkdir -p "$BACKUPS"
chmod 700 "$BACKUPS"   # every tracker credential Prowlarr holds is in here

# ---------------------------------------------------------------------------
# 1. Remember what works, so there is something to go back to
# ---------------------------------------------------------------------------
# The container knows its image id; the digest lives on the image, not the
# container, so this is two lookups rather than one.
image_digest() {
  local id
  id="$(docker inspect --format '{{.Image}}' "$1" 2>/dev/null)" || return 0
  [ -n "$id" ] || return 0
  docker image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$id" 2>/dev/null || true
}

OLD_IMAGE="$(image_digest prowlarr)"
log "currently running ${OLD_IMAGE:-unknown}"

# Prowlarr is stopped for this. Its config is a live SQLite database with a
# write-ahead log; tarring it while it runs can capture the .db and the .db-wal
# from different moments, and the archive the rollback depends on would then be
# one Prowlarr refuses to open. A few seconds down beats an unrestorable backup.
BACKUP="${BACKUPS}/config-${STAMP}.tar.gz"
docker compose stop prowlarr >/dev/null 2>&1 || true
if tar czf "$BACKUP" prowlarr/config; then
  docker compose start prowlarr >/dev/null 2>&1 || true
  log "backed up config to ${BACKUP}"
else
  # Always bring it back up, then stop: without a good backup the rollback
  # below has nothing to restore, so there is no safe way to continue.
  rm -f "$BACKUP"
  docker compose start prowlarr >/dev/null 2>&1 || true
  log "ERROR: could not back up the config, so not updating. Check disk space."
  exit 1
fi
# shellcheck disable=SC2012
ls -1t "${BACKUPS}"/config-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm --

# ---------------------------------------------------------------------------
# 2. The bridge is one file, so updating it is fetching it
# ---------------------------------------------------------------------------
if curl -fsSL --max-time 30 -o bridge/worker.js.new "$BRIDGE_SOURCE"; then
  if ! bridge_sane bridge/worker.js.new; then
    rm -f bridge/worker.js.new
    log "what came back does not look like the bridge; keeping the copy that works"
  elif ! cmp -s bridge/worker.js.new bridge/worker.js 2>/dev/null; then
    cp bridge/worker.js "${BACKUPS}/worker-${STAMP}.js" 2>/dev/null || true
    # Written INTO the existing file rather than moved over it. Docker binds a
    # single-file mount to the inode, so `mv` would give the container a file
    # the host can no longer see it through, and it would keep serving the old
    # one forever.
    cat bridge/worker.js.new > bridge/worker.js
    rm -f bridge/worker.js.new
    BRIDGE_CHANGED=1
    log "bridge updated"
  else
    rm -f bridge/worker.js.new
  fi
else
  rm -f bridge/worker.js.new
  log "could not fetch the bridge; keeping the copy that works"
fi

# ---------------------------------------------------------------------------
# 3. Pull
# ---------------------------------------------------------------------------
docker compose pull --quiet 2>/dev/null || docker compose pull || \
  log "could not pull; carrying on with what is here"

# Deliberately not fatal. `bridge` waits on Prowlarr being healthy, so if the
# new Prowlarr is broken this call fails — and that is precisely the case the
# rollback below exists for. Letting `set -e` kill the script here would mean
# the rollback never ran on the one occasion it is needed.
docker compose up -d || log "compose up reported a problem; checking health anyway"

# `node` read worker.js when it started and will not read it again, and compose
# does not recreate a container just because a mounted file changed. Without
# this the bridge reports itself updated and goes on running the old code.
if [ -n "${BRIDGE_CHANGED:-}" ]; then
  docker compose up -d --force-recreate --no-deps bridge \
    || log "could not restart the bridge"
fi

NEW_IMAGE="$(image_digest prowlarr)"
if [ "$OLD_IMAGE" = "$NEW_IMAGE" ] && [ -z "${BRIDGE_CHANGED:-}" ]; then
  log "already current; nothing to do"
  exit 0
fi
[ "$OLD_IMAGE" = "$NEW_IMAGE" ] || log "prowlarr now ${NEW_IMAGE}"

# ---------------------------------------------------------------------------
# 4. Did it survive?
# ---------------------------------------------------------------------------
HEALTHY=0
for _ in $(seq 1 90); do
  if [ "$(docker inspect --format '{{.State.Health.Status}}' prowlarr 2>/dev/null)" = "healthy" ]; then
    HEALTHY=1; break
  fi
  sleep 2
done

# Prowlarr being well says nothing about the bridge, which is the thing clients
# actually talk to — and it is the half this script just replaced.
BRIDGE_OK=0
if [ "$HEALTHY" = "1" ]; then
  for _ in $(seq 1 15); do
    if docker compose exec -T bridge wget -qO- http://127.0.0.1:8788/healthz >/dev/null 2>&1 \
       || docker compose exec -T bridge node -e \
            'fetch("http://127.0.0.1:8788/healthz").then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))' >/dev/null 2>&1; then
      BRIDGE_OK=1; break
    fi
    sleep 2
  done
  [ "$BRIDGE_OK" = "1" ] || log "ERROR: the bridge is not answering after the update"
fi

if [ "$HEALTHY" = "1" ] && [ "$BRIDGE_OK" = "1" ]; then
  log "update ok"
  docker image prune -f >/dev/null 2>&1 || true
  exit 0
fi

# ---------------------------------------------------------------------------
# 5. It did not. Put back what worked.
# ---------------------------------------------------------------------------
# An unattended update that breaks and then stays broken is worse than no
# unattended update at all, so this is the part that earns the whole script.
log "ERROR: Prowlarr did not come back healthy — rolling back"

roll_back_bridge() {
  # The bridge is updated by replacing a mounted file, so putting it back means
  # putting the old bytes back and recreating the container.
  if [ -n "${BRIDGE_CHANGED:-}" ] && [ -s "${BACKUPS}/worker-${STAMP}.js" ]; then
    cat "${BACKUPS}/worker-${STAMP}.js" > bridge/worker.js
    docker compose up -d --force-recreate --no-deps bridge >/dev/null 2>&1 || true
    log "put the previous bridge back"
  fi
}
roll_back_bridge

if [ -n "$OLD_IMAGE" ]; then
  # Compose reads PROWLARR_IMAGE from .env, so pinning it here is the rollback.
  # Rewritten rather than sed -i'd, because that flag differs between GNU and
  # BSD and this file is worth keeping portable.
  { grep -v '^PROWLARR_IMAGE=' .env || true; printf 'PROWLARR_IMAGE=%s\n' "$OLD_IMAGE"; } > .env.tmp
  mv .env.tmp .env
  chmod 600 .env
  log "pinned back to ${OLD_IMAGE}"
fi

docker compose down >/dev/null 2>&1 || true
rm -rf prowlarr/config
tar xzf "${BACKUPS}/config-${STAMP}.tar.gz"
docker compose up -d || log "compose up reported a problem during rollback"

for _ in $(seq 1 90); do
  if [ "$(docker inspect --format '{{.State.Health.Status}}' prowlarr 2>/dev/null)" = "healthy" ]; then
    log "rolled back and healthy again. Prowlarr is pinned in .env — remove the"
    log "PROWLARR_IMAGE line to resume updates once the problem is fixed."
    exit 1
  fi
  sleep 2
done

log "ERROR: still unhealthy after rollback. Look at: docker compose logs prowlarr"
exit 1
