#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
node tools/audit-feed.mjs 'https://feeds.yellowball.fm/7IvrdL' --out="$HOME/yellowball-shadow-audit" "$@"
