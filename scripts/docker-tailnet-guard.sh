#!/usr/bin/env bash
# Docker DNATs published ports straight past ufw's INPUT chain, so ufw rules do
# NOT protect bridge-networked containers. DOCKER-USER is the chain that does.
#
# Family devices joining the tailnet must not be able to reach the dev stacks
# (postgres 5432/5433, redis 6379/6380, minio 9000/9001). Jellyfin is
# host-networked, so it is governed by ufw instead and is unaffected by this.
set -euo pipefail

add_rule() {  # idempotent
  local bin=$1
  "$bin" -C DOCKER-USER -i tailscale0 -j DROP 2>/dev/null \
    || "$bin" -I DOCKER-USER 1 -i tailscale0 -j DROP
}

# DOCKER-USER may not exist yet if dockerd is still coming up.
for _ in $(seq 1 30); do
  iptables -L DOCKER-USER -n >/dev/null 2>&1 && break
  sleep 1
done

add_rule iptables
ip6tables -L DOCKER-USER -n >/dev/null 2>&1 && add_rule ip6tables || true
echo "docker-tailnet-guard applied"
