#!/usr/bin/env bash
# Root setup for the Jellyfin stack. Run once:  sudo bash 01-gpu-and-stack.sh
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK=/opt/jellyfin
LAN=192.168.0.0/24
KEYRING=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "run me with sudo"; exit 1; }

say "1/5  NVIDIA Container Toolkit repo"
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | gpg --yes --dearmor -o "$KEYRING"
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed "s#deb https://#deb [signed-by=$KEYRING] https://#g" \
  > /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt-get update -qq
apt-get install -y nvidia-container-toolkit

say "2/5  Register the nvidia runtime with Docker"
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker
# Give dockerd a moment to come back before anything else touches it.
for i in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 1; done

say "3/5  Create $STACK (owned by uid 1000, so the container can write)"
install -d -o 1000 -g 1000 -m 755 "$STACK" "$STACK/config" "$STACK/cache"
install -o 1000 -g 1000 -m 644 "$SRC_DIR/docker-compose.yml" "$STACK/docker-compose.yml"

say "4/5  Firewall: allow Jellyfin from the LAN only"
ufw allow from "$LAN" to any port 8096 proto tcp comment 'Jellyfin web (LAN)'
# Optional -- only if you want DLNA discovery from smart TVs:
# ufw allow from "$LAN" to any port 1900 proto udp comment 'Jellyfin DLNA'
# ufw allow from "$LAN" to any port 7359 proto udp comment 'Jellyfin auto-discovery'
ufw status verbose | head -20

say "5/5  Verify the GPU is visible inside a container"
docker run --rm --runtime=nvidia \
  -e NVIDIA_VISIBLE_DEVICES=all \
  -e NVIDIA_DRIVER_CAPABILITIES=compute,utility,video \
  ubuntu:24.04 nvidia-smi -L

say "Done. Now (as softwhere, no sudo):  cd $STACK && docker compose up -d"
