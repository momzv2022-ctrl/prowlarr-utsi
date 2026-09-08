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
  Search endpoint   http://203.0.113.10
  Key               3f9a2c8e7b1d4056a9c3e5f7b2d81460

  Prowlarr          http://203.0.113.10/prowlarr
  Username          admin
  Password          8c41f7e29b
────────────────────────────────────────────────────────────────────
```

Open the Prowlarr link, add the indexers you want, and the endpoint searches
them immediately. Nothing to restart and nothing to re-copy — the URL and the
key never change.

## With a domain

Point a domain at the server first, then:

```sh
DOMAIN=search.example.com sudo bash install.sh
```

You get a real certificate, automatically, and everything moves to `https://`.
Without a domain it is plain HTTP, so the password and the key cross the network
in the clear — fine on a private network, not fine on the open internet.

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

```sh
sudo bash install.sh
```

Run it again whenever. It keeps your keys, your password and your indexers, and
pulls a newer Prowlarr and a newer bridge.

Do that every month or so, because **Prowlarr ships its indexer definitions
inside the release**. There is no separate "update indexers" step: when a
tracker changes its site and the community fixes the definition, that fix
reaches you in the next Prowlarr image. A Prowlarr left pinned for a year is a
Prowlarr whose indexers have quietly stopped working.

Your keys are in `.env`. Back up `prowlarr/config/` and you can rebuild the
whole thing anywhere.

```sh
docker compose logs -f       # what is it doing
docker compose restart       # turn it off and on again
docker compose down          # stop everything
```

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
