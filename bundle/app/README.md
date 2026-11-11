# OpenCast — Nostr Publisher test build

OpenCast is a testable creator-hosting stack for articles and podcasts where the creator's Nostr identity remains portable. This build wires together Nostr publishing, hosted pages, podcast RSS, Blossom media uploads, Monero tipping metadata, discovery and cross-post previews.

## What works in this test build

- NIP-07 browser signer login.
- NIP-55 Android signer callback flow.
- **TEST_MODE disposable signer** for testing the whole app without a signer. It produces real BIP-340 Schnorr-signed Nostr events, but is intentionally unsafe for production identity use.
- NIP-98 authenticated writes to the backend.
- NIP-23 `kind:30023` article events + hosted article pages.
- Podcast metadata event (`kind:10154`) and episode events (`kind:54`) for the Nostr podcast test path.
- RSS 2.0 podcast feed.
- Podcasting 2.0 namespace with `podcast:medium` and `podcast:funding`.
- Direct Monero tip page using a public receiving address. The platform never asks for wallet seeds/spend keys.
- Optional XMRChat creator URL shown on the tip page and included as Podcasting 2.0 funding metadata.
- Blossom media upload flow using short-lived `kind:24242` signed authorization.
- Hosted Explore index.
- NIP-50 search across configured relays.
- Optional Podcast Index search when API credentials are configured.
- Cross-post text previews for Bluesky, Mastodon and X.
- Bluesky/X pre-filled compose links and copy-ready Mastodon text.
- Simulated cross-post queue so the paid automation workflow can be tested before OAuth credentials are stored.
- Privacy-preserving creator Insights: Today / 7 days / 30 days / lifetime, top content, coarse country map, listening-app categories and referrer categories.
- Podcast enclosure redirect for aggregate download-request counting without proxying or storing listener request records.
- Installable PWA when served over HTTPS.
- Rootless-Podman-friendly container with capabilities dropped.

## Intentionally NOT production yet

The following are deliberately not faked as “done”:

- Automatic OAuth posting to Bluesky/Mastodon/X. The test build previews/opens compose pages and simulates the queue; production will use per-user encrypted OAuth/app credentials in a separate worker.
- Monero subscription invoice monitoring. This build handles creator tip routing only.
- XMRPod-specific creator registration API. We expose XMRChat and Podcasting 2.0 funding in the feed; a direct XMRPod/XMRChat integration should be added against their supported API rather than reverse-engineering it.
- Decentralized Garage storage, multi-Blossom replication, PostgreSQL, custom domains and multi-node relays.
- A native APK wrapper. This is an installable PWA over HTTPS and can use Android NIP-55 signers.

## Fast local test on the server itself

Requires Node.js 22+.

```sh
cd opencast-nostr-publisher
npm test
TEST_MODE=1 PUBLIC_BASE_URL=http://localhost:8787 npm start
```

Open:

```text
http://localhost:8787
```

Tap **Test identity**, then **Fill sample data**.

Recommended test order:

1. Publication → save publication.
2. Article → sign & publish.
3. Podcast → publish an episode.
4. Monero → enter a public XMR address and/or XMRChat URL, then save.
5. Open RSS and confirm the episode + funding tags.
6. Discover → search the hosted index; optionally query NIP-50.
7. Insights → refresh aggregate analytics. In TEST_MODE, use **Seed private demo data** to exercise the charts/map.
8. Cross-post → generate previews and simulate a queue job.

## Android testing

Modern browser cryptography, service workers, PWA installation and signer integrations work best from a **trusted HTTPS origin**.

For a real Android test, put the server behind Caddy/Nginx on a test domain with HTTPS and set `PUBLIC_BASE_URL` to the exact public origin. NIP-98 authorization is intentionally bound to that exact origin.

Example:

```sh
TEST_MODE=1 \
PUBLIC_BASE_URL=https://test.example.com \
node server.mjs
```

Then reverse proxy `https://test.example.com` to `127.0.0.1:8787`. An example `Caddyfile.example` is included.

**Do not expose TEST_MODE publicly for a long-running deployment.** Anyone who can reach `/api/test/sign` while TEST_MODE is on can sign as the disposable demo identity. It cannot spend your Monero, but it is intentionally a shared test identity.

For Android signer testing, disable TEST_MODE and use the **Android signer** button with an installed NIP-55 signer such as Amber-compatible software.

## Podman

```sh
./deploy.sh
```

The script asks whether to enable the disposable test signer.

Or with compose:

```sh
cp .env.example .env
# edit .env
podman compose up -d --build
```

## Podcast Index search

Create Podcast Index API credentials, then set:

```text
PODCAST_INDEX_KEY=...
PODCAST_INDEX_SECRET=...
```

The API secret never goes to the browser. OpenCast signs the Podcast Index request server-side and returns normalized search results.

## Data model in this test build

A small JSON database is intentionally used so the code is easy to audit during prototype testing:

```text
data/db.json
```

It stores public publication metadata, hosted article copies, podcast events, simulated cross-post job metadata, and **aggregate-only analytics buckets**. It does not store raw listener IP addresses, full User-Agent strings, city locations, or per-listener histories. Production should replace it with PostgreSQL before multi-user launch.

## Privacy-preserving analytics

The Insights feature is intentionally designed to avoid creating listener profiles.

What creators can see:

- Today / 7-day / 30-day / lifetime aggregate request counts.
- Top articles and podcast episodes.
- Country-level world reach.
- Coarse listening-app/browser categories.
- Coarse discovery/referrer categories.

What the analytics database **does not store**:

- Raw IP addresses.
- Full User-Agent strings.
- Cities or precise locations.
- Device fingerprints.
- Cookies or advertising IDs.
- Per-listener timelines.
- A join between listener analytics and Monero tips.

For same-day duplicate reduction, the request IP and User-Agent exist only transiently in server memory long enough to create an HMAC token with a random **daily, non-persisted secret**. Only that token lives in RAM during the day; it is never written to the database and the secret/token set is discarded on rotation/restart. Bot-like User-Agents are excluded.

Country codes are accepted only from a **trusted proxy/local edge lookup** when `ANALYTICS_TRUST_PROXY=1`. OpenCast does not call an external GeoIP API with listener addresses. If no trusted country header is available, the request is counted as unknown geography. City tracking is not implemented.

Country, app, and referrer breakdowns use a minimum cell size of **k=5** (the code will not allow a lower threshold). Smaller groups are folded into `Other`. Daily total activity and per-content totals remain aggregate counts only.

The PWA service worker caches only the static app shell. It explicitly does **not** cache API responses, analytics responses, public publication pages, or media redirects.

### Reverse-proxy requirement

A public TCP/HTTP server necessarily sees a source address while serving a connection. For the zero-day raw-IP retention promise to hold end-to-end, the reverse proxy/VPS must also avoid persistent request logging. The included `Caddyfile.example` discards access logs. Do not enable CDN/VPS access logging without accounting for that in the privacy policy.

If a trusted edge provides country codes, configure:

```text
ANALYTICS_TRUST_PROXY=1
ANALYTICS_COUNTRY_HEADER=x-geo-country
ANALYTICS_K=5
```

Only enable `ANALYTICS_TRUST_PROXY=1` when the proxy strips client-supplied forwarding/geography headers and inserts trusted values itself.

## Security model

Production identity path:

```text
Creator signer
    ↓ signed event / NIP-98 authorization
OpenCast API
    ↓
Hosted representation + RSS
    ↓
Nostr relays / Blossom
```

The server does not need the creator's `nsec`.

Monero tips:

```text
Listener → creator's public XMR address / XMRChat page → creator wallet
```

OpenCast does not custody creator tips.

## Tests

```sh
npm test
```

The tests include official BIP-340 verification/invalid vectors, event signing + tamper rejection, coarse client classification, bot rejection, k-anonymity suppression for analytics dimensions, and coarse-country validation.
