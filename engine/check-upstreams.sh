#!/bin/sh
# Deliberate-upgrade check (EMBEDDED-ENGINE.md §9.2). Prints the vendored
# libtorrent tag next to the latest upstream release and qBittorrent's latest
# tag (the release line we track for Web API parity). No auto-updates.
set -eu
cd "$(dirname "$0")"

pinned="$(git -C third_party/libtorrent describe --tags --exact-match 2>/dev/null || echo unknown)"
latest_libtorrent="$(
  curl -fsSL https://api.github.com/repos/arvidn/libtorrent/releases/latest \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1
)"
latest_qbittorrent="$(
  curl -fsSL https://api.github.com/repos/qbittorrent/qBittorrent/releases/latest \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1
)"

echo "libtorrent vendored: ${pinned}"
echo "libtorrent latest:   ${latest_libtorrent:-unknown}"
echo "qBittorrent latest:  ${latest_qbittorrent:-unknown}"
[ "$pinned" = "${latest_libtorrent:-$pinned}" ] || echo "upgrade available (deliberate, documented change)"
