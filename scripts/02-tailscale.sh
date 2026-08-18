#!/usr/bin/env bash
set -euo pipefail
say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

say "Tailscale repo (Ubuntu resolute / 26.04)"
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/resolute.noarmor.gpg \
  -o /usr/share/keyrings/tailscale-archive-keyring.gpg
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/resolute.tailscale-keyring.list \
  -o /etc/apt/sources.list.d/tailscale.list
apt-get update -qq
apt-get install -y tailscale

say "Enable the daemon"
systemctl enable --now tailscaled
sleep 2
tailscale version
systemctl is-active tailscaled
