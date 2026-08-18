#!/usr/bin/env bash
# Nightly *arr stack config backup. Installed to /usr/local/bin by 06-arr.sh.
set -euo pipefail

STACK=/opt/arr
DEST=/mnt/storage/backups/arr
KEEP=7
STAMP="$(date +%Y%m%d-%H%M%S)"
CONTAINERS=(qbittorrent radarr sonarr prowlarr jellyseerr)

mkdir -p "$DEST"

# Radarr/Sonarr/Prowlarr use SQLite with WAL; qBittorrent persists settings in
# qBittorrent.conf; Jellyseerr keeps its user account, its generated Jellyfin API
# key and the whole request history in db.sqlite3 -- losing it means redoing the
# setup wizard. Stop the stack briefly so tar snapshots restore cleanly.
WAS_RUNNING=()
for c in "${CONTAINERS[@]}"; do
  if docker ps --format '{{.Names}}' | grep -qx "$c"; then
    WAS_RUNNING+=("$c")
    docker stop "$c" >/dev/null
  fi
done

tar -C "$STACK" \
    --exclude='*/logs' \
    --exclude='*/log' \
    --exclude='*/Backups' \
    -czf "$DEST/arr-config-$STAMP.tar.gz" \
    radarr sonarr prowlarr qbittorrent jellyseerr

for c in "${WAS_RUNNING[@]}"; do
  docker start "$c" >/dev/null
done

ls -1t "$DEST"/arr-config-*.tar.gz 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm --

echo "backup ok: $DEST/arr-config-$STAMP.tar.gz ($(du -h "$DEST/arr-config-$STAMP.tar.gz" | cut -f1))"
