# prowlarr-utsi

Your own torrent search endpoint, on your own server, in one command.

Prowlarr does the searching and knows how to talk to hundreds of indexers. This
puts it on a server, puts a search endpoint in front of it, and hands you both
URLs and both passwords.

```sh
git clone https://github.com/momzv2022-ctrl/prowlarr-utsi
cd prowlarr-utsi
sudo bash install.sh
```

It prints:

```
────────────────────────────────────────────────────────────────────
  Search endpoint   https://203-0-113-10.sslip.io
  Key               3f9a2c8e7b1d4056a9c3e5f7b2d81460

  Prowlarr          https://203-0-113-10.sslip.io/prowlarr
  Username          admin
  Password          8c41f7e29b
────────────────────────────────────────────────────────────────────
```

Open the Prowlarr link, add the indexers you want, and the endpoint searches
them immediately. Nothing to restart and nothing to re-copy — the URL and the
key never change.

## Where that name came from

You need HTTPS whether you wanted it or not: **Android has refused plain HTTP by
default since Android 9**, so a phone will not talk to an `http://` endpoint at
all. A certificate needs a name, and a bare IP address cannot have one here.

So if you do not give a name, one is made from your address.
[sslip.io](https://sslip.io) is a public DNS service that resolves
`203-0-113-10.sslip.io` to `203.0.113.10` — no account, no signup, nothing to
configure. Caddy then gets a normal Let's Encrypt certificate for it.

Two things to know about leaning on it:

- **It is in the path forever.** Every request from your app resolves that name
  through sslip.io. If that service is down, your endpoint is unreachable even
  though your server is fine.
- **First issuance can fail.** Its Let's Encrypt quota is shared by everyone
  using it and occasionally runs dry. Renewals are exempt, so a working install
  keeps working — this only ever bites a fresh one. `install.sh` checks whether
  the certificate actually arrived and tells you what to do if it did not.

Neither matters much for trying this out. Both are reasons to use your own name
once you care.

## With your own domain

Point a domain or subdomain at the server, then:

```sh
DOMAIN=search.example.com sudo bash install.sh
```

Same one command, no third-party DNS in the path. This is the better setup and
the only difference is that you had to own a name.

To skip certificates altogether — a private network, say:

```sh
NO_TLS=1 sudo bash install.sh
```

## What your app gets

```sh
curl -H "X-API-Key: YOUR-KEY" \
  "https://search.example.com/api/v1/search?q=big+buck+bunny&limit=5"
```

JSON: names, sizes, seeders, leechers, `magnet` links, and whatever the release
name gives up — year, resolution, codec, source, season, episode. It also takes
`cat`, `year`, `res`, `min_seeders`, `sort`, `limit` and `offset`.

Which indexers get searched is whatever you have enabled in Prowlarr.

`/healthz` needs no key and reports configuration. `/healthz?probe=1` needs the
key and asks Prowlarr which of your indexers are currently failing.

## When search is slow

**A Prowlarr search waits for its slowest indexer.** It asks all of them at once
and cannot answer until the last one has, so one unreachable indexer sets the
pace for every query you make. Cloudflare-protected public indexers are the
usual cause: they do not fail quickly, they time out.

Find out which ones first, rather than guessing:

```sh
cd prowlarr-utsi && . ./.env
curl -s -H "X-API-Key: $BRIDGE_API_KEY" \
  "https://YOUR-ADDRESS/healthz?probe=1" | python3 -m json.tool
```

That names the indexers Prowlarr currently has blocked. Prowlarr's own
*Indexers* page shows the same thing, and its log has per-indexer timings:

```sh
docker compose logs prowlarr | grep -iE "timeout|timed out|failed"
```

Then, in order of how much they help:

1. **Turn off the indexers that are failing.** In Prowlarr, untick them. This is
   almost always the entire fix, and it costs nothing — an indexer that times
   out was contributing no results anyway.
2. **Ask fewer indexers.** Set `PROWLARR_INDEXER_IDS=3,7` in `.env` to search
   only those, keeping the rest available for anything else using Prowlarr.
3. **Ask for fewer rows.** `BRIDGE_MAX_ROWS=40` instead of 100. Each indexer
   returns less and answers sooner.
4. **Read fewer `.torrent` files.** `BRIDGE_MAX_RESOLVE=6` instead of 12. This
   only affects private trackers, where the bridge fetches the file to get an
   infohash — good results, but a round trip each.
5. **Fail sooner.** `BRIDGE_TIMEOUT_S=20` puts a firm ceiling on the wait. It
   does not make anything faster; it stops you waiting on what will not answer.

After editing `.env`:

```sh
docker compose up -d bridge
```

Your edits survive re-running `install.sh` — it only rewrites the keys it owns.

## What is running

Three containers, and only one of them has a port open.

| | |
|---|---|
| **Caddy** | The only thing on 80 and 443. Passwords Prowlarr, certificates everything. |
| **Prowlarr** | Your indexers. No published port; Caddy is the only way in. |
| **bridge** | Turns Prowlarr's API into plain JSON, so an app never holds Prowlarr's key. |

The split matters. Prowlarr's API key opens Prowlarr's whole admin interface —
your indexers, your tracker logins, your other keys. Handing that to a phone app
means handing over all of it. The bridge holds that key and gives your app a
key of its own that can only search.

Prowlarr is set to `External` authentication, meaning it does no checking of its
own and trusts whatever reaches it. That is safe **only** because it has no
published port and Caddy asks for a password first. If you edit
`caddy/Caddyfile`, do not remove the `basic_auth` block, and do not add a
`ports:` entry to Prowlarr in `docker-compose.yml`.

## Keeping it working

**It updates itself, daily.** You do not have to do anything.

That matters more here than for most things you install, because **Prowlarr
ships its indexer definitions inside the release**. There is no separate "update
indexers" step: when a tracker changes its site and somebody fixes the
definition, that fix reaches you in the next Prowlarr image. A Prowlarr left
pinned for a year is a Prowlarr whose indexers have quietly stopped working. So
updating is not housekeeping — it *is* the maintenance.

`install.sh` sets up a systemd timer (or a cron job) that runs `update.sh` once
a day, at a random time so everyone is not pulling at midnight together. Each run:

1. backs up `prowlarr/config` and keeps the last ten
2. re-fetches the bridge and pulls newer images
3. waits for Prowlarr to report healthy
4. **and if it does not, puts the old version back** — pinning the previous
   image in `.env`, restoring the config it just backed up, and starting again

An unattended update that breaks and then stays broken would be worse than no
unattended update at all, which is why step 4 exists.

```sh
bash update.sh                            # update now
journalctl -u prowlarr-utsi-update        # how the last ones went
NO_AUTOUPDATE=1 sudo bash install.sh      # set it up without the timer
```

If a rollback happens you will find a `PROWLARR_IMAGE=` line pinned in `.env`.
Updates stay on that version until you delete the line, so nothing keeps
retrying a broken release behind your back.

Your keys are in `.env`. Back up `prowlarr/config/` and you can rebuild the
whole thing anywhere.

```sh
docker compose logs -f       # what is it doing
docker compose restart       # turn it off and on again
docker compose down          # stop everything
```

**Not `docker compose down -v`.** That deletes the volume holding your
certificate, and Let's Encrypt issues at most five per name per week — wipe it a
few times while debugging and you are locked out of your own address for a day
at a time, with a perfectly healthy server.

## Requirements

A server with a public IP, running a Linux Docker supports, and root. Debian and
Ubuntu are what this is tested on. Docker gets installed if it is missing.

## Built from

- [Prowlarr](https://github.com/Prowlarr/Prowlarr) — the indexer manager
- [prowlarr-bridge](https://github.com/momzv2022-ctrl/prowlarr-bridge) — the endpoint
- [Caddy](https://caddyserver.com) — the front door

## Your responsibility

This installs software for searching indexers you choose. What you point it at,
and what you do with what you find, is on you — check what is legal where you
live, and read the rules of any private tracker before you connect it.
