#!/usr/bin/env bash
set -euo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

say "Install backup script"
install -m 755 "$SRC_DIR/jellyfin-backup.sh" /usr/local/bin/jellyfin-backup.sh
install -d -o 1000 -g 1000 /mnt/storage/backups/jellyfin

say "systemd service + nightly timer (04:00 Asia/Tashkent)"
cat > /etc/systemd/system/jellyfin-backup.service <<'UNIT'
[Unit]
Description=Back up Jellyfin config
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/jellyfin-backup.sh
UNIT

cat > /etc/systemd/system/jellyfin-backup.timer <<'UNIT'
[Unit]
Description=Nightly Jellyfin config backup

[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now jellyfin-backup.timer
systemctl list-timers jellyfin-backup.timer --no-pager

say "Run it once now to prove it works end to end"
/usr/local/bin/jellyfin-backup.sh
