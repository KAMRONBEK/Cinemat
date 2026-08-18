#!/usr/bin/env bash
set -euo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install -d -o 1000 -g 1000 -m 755 /opt/arr /opt/arr/radarr /opt/arr/sonarr /opt/arr/prowlarr
install -o 1000 -g 1000 -m 644 "$SRC_DIR/arr-compose.yml" /opt/arr/docker-compose.yml
echo "/opt/arr ready:"; ls -la /opt/arr/
