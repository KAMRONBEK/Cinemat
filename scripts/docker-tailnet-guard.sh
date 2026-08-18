#!/usr/bin/env bash
# Docker DNATs published ports straight past ufw's INPUT chain, so ufw rules do
# NOT protect bridge-networked containers. DOCKER-USER is the chain that does.
#
# Devices joining the tailnet must not reach the dev stacks (postgres 5432/5433,
# redis 6379/6380, minio 9000/9001) or the *arr admin UIs. Jellyfin is
# host-networked, so it is governed by ufw instead and is unaffected by this.
#
# Jellyseerr (5055) is the deliberate exception: requesting a film from away is
# the whole point of it, so it is the one container port reachable over the
# tailnet. It requires a Jellyfin login of its own. Everything else stays blocked.
set -euo pipefail

TAILNET_ALLOW_PORT=5055

apply() {
  local bin=$1
  # Remove our own rules first so re-runs cannot leave DROP sitting above ACCEPT.
  # Order is the whole security property here, and -C alone cannot enforce it.
  while "$bin" -C DOCKER-USER -i tailscale0 -p tcp --dport "$TAILNET_ALLOW_PORT" -j ACCEPT 2>/dev/null; do
    "$bin" -D DOCKER-USER -i tailscale0 -p tcp --dport "$TAILNET_ALLOW_PORT" -j ACCEPT
  done
  while "$bin" -C DOCKER-USER -i tailscale0 -j DROP 2>/dev/null; do
    "$bin" -D DOCKER-USER -i tailscale0 -j DROP
  done

  # Insert in reverse order: DROP first, then ACCEPT above it.
  "$bin" -I DOCKER-USER 1 -i tailscale0 -j DROP
  "$bin" -I DOCKER-USER 1 -i tailscale0 -p tcp --dport "$TAILNET_ALLOW_PORT" -j ACCEPT
}

# DOCKER-USER may not exist yet if dockerd is still coming up.
for _ in $(seq 1 30); do
  iptables -L DOCKER-USER -n >/dev/null 2>&1 && break
  sleep 1
done

apply iptables
ip6tables -L DOCKER-USER -n >/dev/null 2>&1 && apply ip6tables || true
echo "docker-tailnet-guard applied (tailnet may reach :$TAILNET_ALLOW_PORT only)"
