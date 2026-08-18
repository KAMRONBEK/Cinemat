#!/usr/bin/env bash
# Nightly Jellyfin config backup. Installed to /usr/local/bin by 04-backup.sh.
set -euo pipefail

STACK=/opt/jellyfin
DEST=/mnt/storage/backups/jellyfin
KEEP=7
STAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$DEST"

# Jellyfin keeps its state in SQLite with WAL enabled. tar'ing that while the
# server is writing yields a snapshot that may not restore cleanly, so we take
# ~10s of downtime at 4am rather than gamble on the backup being valid.
WAS_RUNNING=0
if docker ps --format '{{.Names}}' | grep -qx jellyfin; then
  WAS_RUNNING=1
  docker stop jellyfin >/dev/null
fi

# Excluded: metadata/ and log/ are regenerable, transcodes/ is scratch.
# What matters is data/ (users, watch progress, library) and config/ (settings).
tar -C "$STACK" \
    --exclude='config/log' \
    --exclude='config/metadata' \
    --exclude='config/transcodes' \
    -czf "$DEST/jellyfin-config-$STAMP.tar.gz" config

[ "$WAS_RUNNING" -eq 1 ] && docker start jellyfin >/dev/null

# Retain the most recent $KEEP archives.
ls -1t "$DEST"/jellyfin-config-*.tar.gz 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm --

echo "backup ok: $DEST/jellyfin-config-$STAMP.tar.gz ($(du -h "$DEST/jellyfin-config-$STAMP.tar.gz" | cut -f1))"
