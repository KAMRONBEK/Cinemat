#!/usr/bin/env bash
set -euo pipefail
LAN=192.168.0.0/24
# Pinned in compose/arr.docker-compose.yml so this rule keeps matching if the
# arr network is ever recreated.
ARR_NET=172.20.0.0/24
say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

say "1/4  Don't break Docker: forward policy DROP -> ACCEPT"
# ufw ships DEFAULT_FORWARD_POLICY=DROP. Docker containers talk to each other
# and to the internet through the FORWARD chain, so leaving this at DROP is the
# classic way to enable ufw and silently kill every container's networking.
sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
grep DEFAULT_FORWARD_POLICY /etc/default/ufw

say "2/4  Baseline policy"
ufw default deny incoming
ufw default allow outgoing

say "3/4  Rules"
# Remote family access arrives over the Tailscale interface. Without this rule
# the whole remote-streaming plan dies the moment the firewall comes up. Scoped to
# 8096: a blanket 'allow in on tailscale0' would also hand every family device on the
# tailnet the postgres/redis/minio ports on this box (see README section 7).
ufw allow in on tailscale0 to any port 8096 proto tcp comment 'Jellyfin over Tailscale'

# Jellyfin is host-networked, so ufw genuinely enforces this one.
ufw allow from "$LAN" to any port 8096 proto tcp comment 'Jellyfin web (LAN)'

# Radarr/Sonarr sit on the arr bridge network and call Jellyfin's HTTP API to
# refresh the library the moment an import lands. Jellyfin is host-networked, so
# that request reaches ufw's INPUT chain sourced from the bridge subnet, not from
# $LAN -- without this rule it is dropped and the refresh silently never happens.
ufw allow from "$ARR_NET" to any port 8096 proto tcp comment 'Jellyfin API (arr library refresh)'

# Client auto-discovery so the phone/TV apps find the server without typing an IP.
ufw allow from "$LAN" to any port 7359 proto udp comment 'Jellyfin auto-discovery'
ufw allow from "$LAN" to any port 1900 proto udp comment 'DLNA/SSDP'

# Dev services, LAN-scoped. Note: these publish via Docker bridge networking,
# which DNATs past ufw's INPUT chain entirely -- so these rules are correctness
# insurance, not actual protection. Closing that hole needs DOCKER-USER rules.
for p in 5432 5433 6379 6380 9000 9001; do
  ufw allow from "$LAN" to any port "$p" proto tcp comment 'dev service (LAN)'
done

say "4/4  Enable"
ufw --force enable
ufw status verbose
