# OpenCast privacy analytics design

This build intentionally measures **content activity**, not people.

## Stored analytics data

Only aggregate buckets are persisted:

- UTC day
- content ID/type/title
- aggregate count
- coarse country code
- coarse client category (for example `AntennaPod` or `XMRPod`)
- coarse referrer category (for example `Nostr`, `Search`, `Bluesky`)

## Not stored

- raw IP addresses
- full User-Agent strings
- raw referrer URLs
- city/region/coordinates
- cookies or advertising IDs
- device fingerprints
- per-listener IDs or histories
- links between analytics and Monero tips

## Duplicate reduction

For a GET request, the application transiently reads the connection address and User-Agent and calculates an HMAC containing publication + content ID. The HMAC secret is random, lives only in RAM, rotates daily, and is not persisted. This design prevents the in-memory token from being used to correlate a listener across different content items or across days. The raw inputs are not written to the analytics database.

## Small-group protection

Country, client and referrer breakdowns are only returned when a bucket has at least five events. Smaller buckets are combined into `Other`. The code enforces a minimum threshold of 5 even if a lower environment value is supplied.

## Geography

The app never sends listener IP addresses to an external GeoIP web API. Country data is accepted only from a trusted local/edge header when `ANALYTICS_TRUST_PROXY=1`. Otherwise geography is `Unknown`.

For maximum privacy, use a locally hosted IP-to-country database at your reverse proxy/edge and inject only a two-letter country code.

## Media hosting caveat

The podcast analytics route redirects to the configured Blossom/media URL. The media host necessarily sees the listener connection when it serves the bytes. For the strongest privacy, operate the Blossom/media nodes yourself and disable their access logs, or later add a privacy media proxy if using third-party origins.

## Infrastructure caveat

A public server and network provider necessarily observe connection metadata while traffic is in flight. OpenCast can avoid retaining that metadata, but it cannot prevent the underlying VPS/network provider from observing network traffic. The included Caddy example discards access logs. Review logging at every proxy, load balancer and storage node before making a zero-retention promise.

## PWA cache

The service worker caches only the static creator app shell. It does not cache API responses, analytics responses, publication pages or media redirects.
