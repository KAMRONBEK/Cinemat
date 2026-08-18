#!/usr/bin/env bash
set -euo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

say "Install guard script"
install -m 755 "$SRC_DIR/docker-tailnet-guard.sh" /usr/local/bin/docker-tailnet-guard.sh

say "Re-apply automatically whenever dockerd starts (boot + restarts)"
# DOCKER-USER gets rebuilt by dockerd, so the rule has to be reapplied after
# every daemon start, not just once at boot.
mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/tailnet-guard.conf <<'UNIT'
[Service]
ExecStartPost=/usr/local/bin/docker-tailnet-guard.sh
UNIT
systemctl daemon-reload

say "Apply now"
/usr/local/bin/docker-tailnet-guard.sh
iptables -L DOCKER-USER -n -v --line-numbers
