#!/usr/bin/env bash
# Root setup for the *arr stack. Run once:  sudo bash 06-arr.sh
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SRC_DIR/.." && pwd)"
STACK=/opt/arr
CREDS="$STACK/.credentials"
LAN_IP="${LAN_IP:-$(hostname -I | awk '{print $1}')}"

# qBittorrent categories, one completed-download subdirectory each. Radarr and
# Sonarr health-check that the client's save path exists inside their own
# container, so these must be created up front rather than lazily on first
# download -- otherwise both apps report a path-mapping error on a fresh install.
QBIT_CATEGORIES=(radarr tv-sonarr prowlarr)
DOWNLOADS=/mnt/storage/downloads

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "run me with sudo"; exit 1; }
command -v curl >/dev/null || apt-get install -y curl
command -v jq >/dev/null || apt-get install -y jq
command -v openssl >/dev/null || apt-get install -y openssl

say "1/6  Directories"
CATEGORY_DIRS=()
for cat in "${QBIT_CATEGORIES[@]}"; do
  CATEGORY_DIRS+=("$DOWNLOADS/complete/$cat")
done

install -d -o 1000 -g 1000 -m 755 \
  "$STACK" \
  "$STACK/radarr" "$STACK/sonarr" "$STACK/prowlarr" "$STACK/qbittorrent" \
  "$STACK/jellyseerr" \
  /mnt/storage/media/movies /mnt/storage/media/tv \
  "$DOWNLOADS/complete" "$DOWNLOADS/incomplete" \
  "${CATEGORY_DIRS[@]}" \
  /mnt/storage/backups/arr

say "2/6  Install compose"
install -o 1000 -g 1000 -m 644 "$REPO_ROOT/compose/arr.docker-compose.yml" "$STACK/docker-compose.yml"

say "3/6  Credentials"
if [[ ! -f "$CREDS" ]]; then
  ADMIN_PASS="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
  umask 077
  cat > "$CREDS" <<EOF
ADMIN_USER=admin
ADMIN_PASS=$ADMIN_PASS
EOF
  chown 1000:1000 "$CREDS"
  chmod 600 "$CREDS"
fi
# shellcheck disable=SC1090
source "$CREDS"

say "4/6  Start containers"
cd "$STACK"
docker compose up -d

wait_http() {
  local url=$1 label=$2
  for _ in $(seq 1 90); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "timed out waiting for $label ($url)" >&2
  return 1
}

wait_qbit() {
  for _ in $(seq 1 90); do
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/ || true)"
    [[ "$code" == "200" || "$code" == "401" ]] && return 0
    sleep 2
  done
  echo "timed out waiting for qBittorrent" >&2
  return 1
}

wait_http "http://127.0.0.1:7878/ping" "Radarr"
wait_http "http://127.0.0.1:8989/ping" "Sonarr"
wait_http "http://127.0.0.1:9696/ping" "Prowlarr"
wait_qbit
wait_http "http://127.0.0.1:5055/api/v1/status" "Jellyseerr"

api_key() {
  grep -oP '(?<=<ApiKey>)[^<]+' "$1" | head -1
}

RADARR_KEY="$(api_key "$STACK/radarr/config.xml")"
SONARR_KEY="$(api_key "$STACK/sonarr/config.xml")"
PROWLARR_KEY="$(api_key "$STACK/prowlarr/config.xml")"

servarr() {
  local base=$1 key=$2 method=$3 path=$4 data=${5:-}
  local -a args=(-fsS -X "$method" -H "X-Api-Key: $key" -H "Content-Type: application/json")
  [[ -n "$data" ]] && args+=(-d "$data")
  curl "${args[@]}" "${base}${path}"
}

configure_auth() {
  local base=$1 key=$2 label=$3
  local auth_method
  auth_method="$(servarr "$base" "$key" GET /config/host | jq -r '.authenticationMethod')"
  [[ "$auth_method" == "forms" ]] && { echo "$label auth already enabled"; return 0; }

  local host_cfg
  host_cfg="$(servarr "$base" "$key" GET /config/host)"
  host_cfg="$(echo "$host_cfg" | jq \
    --arg user "$ADMIN_USER" --arg pass "$ADMIN_PASS" \
    '.authenticationMethod = "forms"
     | .authenticationRequired = "enabled"
     | .username = $user
     | .password = $pass
     | .passwordConfirmation = $pass')"
  servarr "$base" "$key" PUT /config/host "$host_cfg" >/dev/null
  echo "$label forms auth enabled"
}

ensure_root_folder() {
  local base=$1 key=$2 path=$3
  local existing
  existing="$(servarr "$base" "$key" GET /rootfolder | jq -r --arg p "$path" '.[] | select(.path == $p) | .path' | head -1)"
  [[ -n "$existing" ]] && return 0
  servarr "$base" "$key" POST /rootfolder "$(jq -nc --arg p "$path" '{path: $p}')" >/dev/null
}

ensure_qbit_client() {
  local base=$1 key=$2 category_field=$3 category=$4
  local existing
  existing="$(servarr "$base" "$key" GET /downloadclient | jq -r '.[] | select(.name == "qBittorrent") | .name' | head -1)"
  [[ -n "$existing" ]] && { echo "qBittorrent client already in $base"; return 0; }

  local schema client
  schema="$(servarr "$base" "$key" GET /downloadclient/schema | jq '.[] | select(.implementation == "QBittorrent")')"
  client="$(echo "$schema" | jq \
    --arg user "$ADMIN_USER" --arg pass "$ADMIN_PASS" \
    --arg cat "$category" --arg cat_field "$category_field" \
    '.enable = true
     | .name = "qBittorrent"
     | .priority = 1
     | .removeCompletedDownloads = true
     | .removeFailedDownloads = true
     | .fields = [.fields[] |
         if .name == "host" then .value = "qbittorrent"
         elif .name == "port" then .value = 8080
         elif .name == "useSsl" then .value = false
         elif .name == "username" then .value = $user
         elif .name == "password" then .value = $pass
         elif .name == $cat_field then .value = $cat
         else . end]')"
  servarr "$base" "$key" POST /downloadclient "$client" >/dev/null
}

configure_radarr() {
  local base="http://127.0.0.1:7878/api/v3"
  configure_auth "$base" "$RADARR_KEY" "Radarr"
  ensure_root_folder "$base" "$RADARR_KEY" "/data/media/movies"

  local naming mm
  naming="$(servarr "$base" "$RADARR_KEY" GET /config/naming | jq \
    '.renameMovies = true
     | .standardMovieFormat = "{Movie Title} ({Release Year})"
     | .movieFolderFormat = "{Movie Title} ({Release Year})"
     | .replaceIllegalCharacters = true')"
  servarr "$base" "$RADARR_KEY" PUT /config/naming "$naming" >/dev/null

  mm="$(servarr "$base" "$RADARR_KEY" GET /config/mediamanagement | jq \
    '.copyUsingHardlinks = true
     | .enableMediaInfo = true')"
  servarr "$base" "$RADARR_KEY" PUT /config/mediamanagement "$mm" >/dev/null

  ensure_qbit_client "$base" "$RADARR_KEY" "movieCategory" "radarr"
  echo "Radarr configured"
}

configure_sonarr() {
  local base="http://127.0.0.1:8989/api/v3"
  configure_auth "$base" "$SONARR_KEY" "Sonarr"
  ensure_root_folder "$base" "$SONARR_KEY" "/data/media/tv"

  local naming mm
  naming="$(servarr "$base" "$SONARR_KEY" GET /config/naming | jq \
    '.renameEpisodes = true
     | .seriesFolderFormat = "{Series Title}"
     | .seasonFolderFormat = "Season {season:00}"
     | .standardEpisodeFormat = "{Series Title} S{season:00}E{episode:00}"
     | .replaceIllegalCharacters = true')"
  servarr "$base" "$SONARR_KEY" PUT /config/naming "$naming" >/dev/null

  mm="$(servarr "$base" "$SONARR_KEY" GET /config/mediamanagement | jq \
    '.copyUsingHardlinks = true
     | .enableMediaInfo = true')"
  servarr "$base" "$SONARR_KEY" PUT /config/mediamanagement "$mm" >/dev/null

  ensure_qbit_client "$base" "$SONARR_KEY" "tvCategory" "tv-sonarr"
  echo "Sonarr configured"
}

configure_prowlarr() {
  local base="http://127.0.0.1:9696/api/v1"
  configure_auth "$base" "$PROWLARR_KEY" "Prowlarr"
  ensure_qbit_client "$base" "$PROWLARR_KEY" "category" "prowlarr"

  local existing
  existing="$(servarr "$base" "$PROWLARR_KEY" GET /applications | jq -r '.[] | select(.name == "Radarr") | .name' | head -1)"
  if [[ -z "$existing" ]]; then
    local schema app
    schema="$(servarr "$base" "$PROWLARR_KEY" GET /applications/schema | jq '.[] | select(.implementation == "Radarr")')"
    app="$(echo "$schema" | jq \
      --arg key "$RADARR_KEY" \
      '.name = "Radarr"
       | .syncLevel = "fullSync"
       | .fields = [.fields[] |
           if .name == "prowlarrUrl" then .value = "http://prowlarr:9696"
           elif .name == "baseUrl" then .value = "http://radarr:7878"
           elif .name == "apiKey" then .value = $key
           else . end]')"
    servarr "$base" "$PROWLARR_KEY" POST /applications "$app" >/dev/null
  fi

  existing="$(servarr "$base" "$PROWLARR_KEY" GET /applications | jq -r '.[] | select(.name == "Sonarr") | .name' | head -1)"
  if [[ -z "$existing" ]]; then
    local schema app
    schema="$(servarr "$base" "$PROWLARR_KEY" GET /applications/schema | jq '.[] | select(.implementation == "Sonarr")')"
    app="$(echo "$schema" | jq \
      --arg key "$SONARR_KEY" \
      '.name = "Sonarr"
       | .syncLevel = "fullSync"
       | .fields = [.fields[] |
           if .name == "prowlarrUrl" then .value = "http://prowlarr:9696"
           elif .name == "baseUrl" then .value = "http://sonarr:8989"
           elif .name == "apiKey" then .value = $key
           else . end]')"
    servarr "$base" "$PROWLARR_KEY" POST /applications "$app" >/dev/null
  fi

  echo "Prowlarr configured"
}

configure_qbittorrent() {
  local conf="$STACK/qbittorrent/qBittorrent/config/qBittorrent.conf"
  local cookie="/tmp/qbit-bootstrap.cookie"
  rm -f "$cookie"

  local login_pass="$ADMIN_PASS"
  if [[ ! -f "$conf" ]] || ! grep -q 'WebUI\\Password_PBKDF2' "$conf" 2>/dev/null; then
    local temp
    temp="$(docker logs qbittorrent 2>&1 | grep -oP 'password is provided for this session: \K\S+' | tail -1 || true)"
    [[ -n "$temp" ]] && login_pass="$temp"
  fi

  for _ in $(seq 1 10); do
    curl -fsS -c "$cookie" -X POST "http://127.0.0.1:8080/api/v2/auth/login" \
      --data-urlencode "username=admin" \
      --data-urlencode "password=$login_pass" >/dev/null && break
    sleep 2
  done

  local prefs
  prefs="$(curl -fsS -b "$cookie" "http://127.0.0.1:8080/api/v2/app/preferences")"
  prefs="$(echo "$prefs" | jq \
    --arg pass "$ADMIN_PASS" \
    '.save_path = "/data/downloads/complete"
     | .temp_path_enabled = true
     | .temp_path = "/data/downloads/incomplete"
     | .upnp = false
     | .upnp_lease_duration = 0
     | .web_ui_password = $pass')"
  curl -fsS -b "$cookie" -X POST "http://127.0.0.1:8080/api/v2/app/setPreferences" \
    --data-urlencode "json=$(echo "$prefs" | jq -c .)" >/dev/null

  for cat in "${QBIT_CATEGORIES[@]}"; do
    curl -fsS -b "$cookie" -X POST "http://127.0.0.1:8080/api/v2/torrents/createCategory" \
      --data-urlencode "category=$cat" \
      --data-urlencode "savePath=/data/downloads/complete/$cat" >/dev/null 2>&1 || true
  done

  rm -f "$cookie"
  echo "qBittorrent configured"
}

configure_jellyseerr() {
  local cfg="$STACK/jellyseerr/settings.json"

  for _ in $(seq 1 60); do [[ -f "$cfg" ]] && break; sleep 2; done
  [[ -f "$cfg" ]] || { echo "Jellyseerr settings.json never appeared" >&2; return 1; }

  if jq -e '.radarr | length > 0' "$cfg" >/dev/null 2>&1; then
    echo "Jellyseerr already seeded"; return 0
  fi

  # Seed Radarr/Sonarr only. Deliberately DO NOT set .jellyfin.ip here: Jellyseerr
  # refuses first-time sign-in with 500 "Jellyfin hostname already configured" if a
  # hostname is already present, and logs nothing, so the browser shows only a
  # generic failure. The media-server step needs a Jellyfin password anyway, which
  # does not belong in this repo. See README section 10.
  docker stop jellyseerr >/dev/null
  jq --arg rk "$RADARR_KEY" --arg sk "$SONARR_KEY" --arg ip "$LAN_IP" '
     .radarr = [{
       name: "Radarr", hostname: "radarr", port: 7878, apiKey: $rk, useSsl: false, baseUrl: "",
       activeProfileId: 6, activeProfileName: "HD - 720p/1080p", activeDirectory: "/data/media/movies",
       is4k: false, minimumAvailability: "released", isDefault: true,
       externalUrl: ("http://" + $ip + ":7878"), syncEnabled: true, preventSearch: false,
       tagRequests: false, tags: []
     }]
     | .sonarr = [{
       name: "Sonarr", hostname: "sonarr", port: 8989, apiKey: $sk, useSsl: false, baseUrl: "",
       activeProfileId: 6, activeProfileName: "HD - 720p/1080p", activeDirectory: "/data/media/tv",
       activeAnimeProfileId: null, activeAnimeProfileName: null, activeAnimeDirectory: null,
       activeLanguageProfileId: null, activeAnimeLanguageProfileId: null,
       is4k: false, isDefault: true, enableSeasonFolders: true,
       externalUrl: ("http://" + $ip + ":8989"), syncEnabled: true, preventSearch: false,
       tagRequests: false, tags: [], animeTags: []
     }]' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  docker start jellyseerr >/dev/null
  echo "Jellyseerr seeded with Radarr/Sonarr (sign-in stays manual)"
}

say "5/6  Bootstrap apps"
configure_qbittorrent
configure_radarr
configure_sonarr
configure_prowlarr
configure_jellyseerr

say "6/6  Backup timer"
install -m 755 "$SRC_DIR/arr-backup.sh" /usr/local/bin/arr-backup.sh

cat > /etc/systemd/system/arr-backup.service <<'UNIT'
[Unit]
Description=Back up *arr stack config
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/arr-backup.sh
UNIT

cat > /etc/systemd/system/arr-backup.timer <<'UNIT'
[Unit]
Description=Nightly *arr stack config backup

[Timer]
OnCalendar=*-*-* 04:15:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now arr-backup.timer
/usr/local/bin/arr-backup.sh

say "Done"
cat <<EOF

*arr stack is up on the LAN:
  qBittorrent  http://${LAN_IP}:8080
  Radarr       http://${LAN_IP}:7878
  Sonarr       http://${LAN_IP}:8989
  Prowlarr     http://${LAN_IP}:9696
  Jellyseerr   http://${LAN_IP}:5055

Login: $ADMIN_USER / (see $CREDS)
Root folders: /data/media/movies, /data/media/tv
Downloads:    /data/downloads/{complete,incomplete}

Next manual steps:
  1. Add indexers in Prowlarr (Settings -> Indexers). They sync to Radarr/Sonarr.
  2. Finish the Jellyseerr wizard at http://${LAN_IP}:5055 -- sign in with the
     Jellyfin account. Enter the host WITHOUT a scheme or port (the form has a
     http:// prefix box and a separate Port field). Radarr/Sonarr are pre-filled.
Backups: /mnt/storage/backups/arr/ (nightly 04:15, 7 retained)
EOF
