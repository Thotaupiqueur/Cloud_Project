#!/bin/sh
set -eu

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

log() {
  echo "[wiki-seed] $*"
}

find_pages_dir() {
  find /config -maxdepth 4 -type d -path '*/data/pages' 2>/dev/null | head -n 1
}

log "waiting for DokuWiki initialisation"
n=0
PAGES=""
while [ -z "$PAGES" ]; do
  PAGES=$(find_pages_dir)
  if [ -z "$PAGES" ]; then
    n=$((n + 1))
    if [ "$n" -ge 120 ]; then
      log "timeout waiting for DokuWiki data directory"
      exit 1
    fi
    sleep 5
  fi
done
sleep 10

for src in /seed/*.txt; do
  dest="$PAGES/$(basename "$src")"
  if [ ! -f "$dest" ]; then
    cp "$src" "$dest"
    chown "$PUID:$PGID" "$dest"
    chmod 644 "$dest"
    log "created $dest"
  fi
done

log "seed complete"
