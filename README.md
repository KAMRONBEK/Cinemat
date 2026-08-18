# Cinemat — Personal Jellyfin Media Server

A family-only media server running on a home Ubuntu box in Tashkent. Streams to
phones, a Google TV, and a remote office PC over Tailscale. No subscriptions,
no paid software, nothing exposed to the public internet.

**Scope (settled):** personal/family use only. Not a paid or public service.

---

## 1. Host

| | |
|---|---|
| OS | Ubuntu 26.04 LTS (Resolute Raccoon), kernel 7.0.0-29-generic |
| CPU | Intel i5-12400F — 6C/12T. **"F" = no iGPU, so no Quick Sync / VAAPI** |
| GPU | NVIDIA RTX 4060 (AD107, Ada), driver 595.71.05, 8 GB VRAM |
| RAM | 14 GB |
| Boot disk | 476 GB NVMe (TEAM TM8FP6512G) → `/` |
| Media disk | 1 TB SATA SSD (KingFast) → `/mnt/storage`, ext4, in fstab with `nofail` |
| Network | Wi-Fi `wlp3s0`, `192.168.0.146/24`, gateway `192.168.0.1` |
| Public IP | `94.158.60.80` — **not** CGNAT (verified via `tailscale netcheck`) |
| Docker | 29.6.1, Compose v5.1.4 |

`eno1` (gigabit ethernet) exists but has no cable attached. Current Wi-Fi link is
−73 dBm, single spatial stream, ~117/130 Mbit/s negotiated. Plugging in ethernet
is the single largest available performance win. Deliberately deferred.

---

## 2. Architecture

```
                 ┌──────────────── home LAN 192.168.0.0/24 ───────────┐
  Google TV  ────┤                                                    │
  Phones     ────┤   Ubuntu box (192.168.0.146)                       │
  Home PC    ────┤     ├─ jellyfin      :8096  (host network)         │
                 │     ├─ jellyseerr    :5055  (bridge, LAN + tailnet) │
                 │     ├─ qbittorrent   :8080  (bridge, LAN only)     │
                 │     ├─ radarr        :7878  (bridge, LAN only)     │
                 │     ├─ sonarr        :8989  (bridge, LAN only)     │
                 │     ├─ prowlarr      :9696  (bridge, LAN only)     │
                 │     └─ tailscaled    tailscale0 = 100.83.255.76    │
                 └────────────────────────┬───────────────────────────┘
                                          │ WireGuard, direct UDP
                       Office PC ─────────┘  (100.64.0.0/10 tailnet)
```

Remote access is Tailscale only. **No router port forwarding, no UPnP, no DDNS.**

---

## 3. Directory layout

```
/opt/jellyfin/
  docker-compose.yml
  config/                  # SQLite DB, users, metadata, watch state  <-- backed up
  cache/                   # transcode scratch + image cache (disposable)

/opt/arr/
  docker-compose.yml
  .credentials             # admin login for all four UIs (mode 600, not in git)
  radarr/  sonarr/  prowlarr/  qbittorrent/

/mnt/storage/
  media/movies/            # mounted into Jellyfin READ-ONLY as /media/movies
  media/tv/                #                                     /media/tv
  downloads/{complete,incomplete}
  backups/jellyfin/        # nightly tarballs, 7 retained
  backups/arr/             # nightly *arr config tarballs, 7 retained
```

Config lives on the NVMe (SQLite wants the fast disk); media lives on the SATA SSD.

### Media naming

Jellyfin's scanner depends on this structure. Get it wrong and metadata matching fails.

```
/mnt/storage/media/movies/Dune (2021)/Dune (2021).mkv
/mnt/storage/media/tv/Severance/Season 01/Severance S01E01.mkv
```

Files must be readable by uid 1000.

---

## 4. Jellyfin

Pinned to **10.11.11**. 12.0 is still release-candidate as of 2026-08.

`/opt/jellyfin/docker-compose.yml`:

```yaml
services:
  jellyfin:
    image: jellyfin/jellyfin:10.11.11
    container_name: jellyfin
    restart: unless-stopped
    network_mode: host        # DLNA + client auto-discovery; also lets ufw police 8096
    user: "1000:1000"
    runtime: nvidia
    environment:
      - TZ=Asia/Tashkent
      - HOME=/config         # see gotcha #2
      - NVIDIA_VISIBLE_DEVICES=all
      - NVIDIA_DRIVER_CAPABILITIES=compute,utility,video
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:8096/health || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 90s
    volumes:
      - ./config:/config
      - ./cache:/cache
      - /mnt/storage/media:/media:ro
```

### Libraries

| Display name | Content type | Path (container) |
|---|---|---|
| Movies | Movies | `/media/movies` |
| TV | Shows | `/media/tv` |

Movies and TV **must** be separate libraries with distinct content types — the Shows
scanner parses `S01E01` and does episode lookups, the Movies scanner doesn't.

Per-library settings applied: trickplay extraction **on**, chapter images **off**,
metadata `en`/`US`, real-time monitor on, `SaveLocalMetadata` off,
`SaveSubtitlesWithMedia` off.

---

## 5. Hardware transcoding (NVENC)

The i5-12400F has no iGPU, so VAAPI/QSV is not an option on this box. The 4060 is
the better encoder regardless.

Set in `/opt/jellyfin/config/config/encoding.xml`:

| Setting | Value | Why |
|---|---|---|
| `HardwareAccelerationType` | `nvenc` | |
| `AllowHevcEncoding` | `true` | large bandwidth saving; Jellyfin only picks it if the client advertises support |
| `EnableTonemapping` | `true` | without it HDR content looks washed-out grey on SDR clients |
| `HardwareDecodingCodecs` | h264, hevc, mpeg2video, vc1, vp9, av1 | default was only h264+vc1, leaving most 4K decoding on the CPU |
| `AllowAv1Encoding` | `false` | 4060 does AV1 well, but client support is patchy. Flip when wanted. |

### Measured throughput

Real encodes run inside the container, not vendor claims:

| Codec | Resolution | Speed |
|---|---|---|
| `h264_nvenc` | 1080p | **10.8× realtime** |
| `hevc_nvenc` 10-bit | 4K 3840×2160 | **3.06× realtime** (94 fps) |
| `av1_nvenc` | 1080p | **8.88× realtime** |

GeForce cards cap concurrent NVENC *encode* sessions (5 on current drivers);
decode is unlimited, and direct plays don't consume a session at all.

### Verify NVENC still works

```bash
docker exec jellyfin nvidia-smi -L
docker exec jellyfin /usr/lib/jellyfin-ffmpeg/ffmpeg -hide_banner -loglevel error -stats \
  -f lavfi -i testsrc2=size=1920x1080:rate=30 -t 10 -c:v h264_nvenc -f null -
```

**Critical:** `NVIDIA_DRIVER_CAPABILITIES` must include `video`. The toolkit default
(`utility,compute`) silently hides NVENC — the #1 cause of "I enabled hardware
transcoding but the CPU still pegs at 100%".

---

## 6. Remote access (Tailscale)

Tailscale 1.102.2, free Personal plan.

| | |
|---|---|
| Node | `jellyfin-server` |
| Tailscale IP | `100.83.255.76` |
| MagicDNS | `jellyfin-server.tailcfff5a.ts.net` |
| Tailnet | kamuranbek1998@gmail.com |
| Connection | **direct** UDP (not DERP-relayed) |

Brought up with `--accept-dns=false` so tailscaled does not rewrite the host's
`/etc/resolv.conf` and disturb the other Docker stacks on this machine. Remote
clients still resolve the MagicDNS name via their own tailscaled.

`tailscale set --operator=softwhere` is applied, so tailscale commands don't need root.

### Client setup

| Device | How |
|---|---|
| Office PC (different LAN) | Tailscale app, same account → `http://100.83.255.76:8096` |
| Phone (iOS/Android) | Tailscale app + Jellyfin app → `http://100.83.255.76:8096` |
| Google TV | Tailscale from Play Store + Findroid or Jellyfin for Android TV |
| Home PC on the LAN | `http://192.168.0.146:8096` — no Tailscale needed |

Enable **Quick Connect** (Dashboard → General) before configuring the TV — it shows a
6-digit code you approve from your phone, instead of typing a password with a d-pad.

`PublishedServerUriBySubnet` is set so each client is told a URL that works from
where it actually sits:

```
192.168.0.0/24=http://192.168.0.146:8096
100.64.0.0/10=http://100.83.255.76:8096
```

A single published URL would break one group or the other.

### Family onboarding

Free Personal plan is 3 users / 100 devices. Preferred approach is **Tailscale node
sharing** — share only the `jellyfin-server` node with each relative's own account.
They see Jellyfin and nothing else on the tailnet, and it sidesteps the seat limit.
The alternative (every device signed into one account) puts them inside the tailnet.

---

## 7. Security model

### ufw

ufw was installed and enabled as a systemd unit but **`ufw status` reported
`inactive`** — nothing was being filtered. Now active:

```
8096/tcp                ALLOW IN    192.168.0.0/24      # Jellyfin web (LAN)
7359/udp                ALLOW IN    192.168.0.0/24      # Jellyfin auto-discovery
1900/udp                ALLOW IN    192.168.0.0/24      # DLNA/SSDP
5432,5433,6379,6380,9000,9001/tcp  ALLOW IN 192.168.0.0/24   # dev services
8096/tcp on tailscale0  ALLOW IN    Anywhere            # Jellyfin over Tailscale
8096/tcp                ALLOW IN    172.20.0.0/24       # Jellyfin API (arr library refresh)
```

`DEFAULT_FORWARD_POLICY` was changed `DROP` → `ACCEPT` in `/etc/default/ufw`.
Leaving it at `DROP` while enabling ufw kills all Docker container networking —
containers talk through the FORWARD chain.

The tailscale0 rule is scoped to **port 8096 only**. An earlier blanket
`allow in on tailscale0` would have handed every family device on the tailnet
access to the postgres/redis/minio instances on this box.

### Docker bypasses ufw

Docker DNATs published ports through its own FORWARD chains, so **ufw INPUT rules do
not protect bridge-networked containers**. Jellyfin is host-networked and therefore
genuinely governed by ufw; the dev stacks are not.

`DOCKER-USER` closes the tailnet path, with one deliberate hole for Jellyseerr:

```bash
iptables -I DOCKER-USER 1 -i tailscale0 -j DROP                              # everything
iptables -I DOCKER-USER 1 -i tailscale0 -p tcp --dport 5055 -j ACCEPT        # except :5055
```

Order is the entire security property, and `iptables -C` can only tell you a rule
exists, not where it sits. So the guard script deletes both of its own rules and
re-inserts them every run rather than appending conditionally — otherwise a second
run could leave the blanket `DROP` above the `ACCEPT` and quietly close the hole.

Jellyseerr is the exception because requesting a film while away is the point of it:
without this you can watch from anywhere but only request from the sofa. It carries
its own Jellyfin login, and the tailnet is already limited to devices signed into the
account. The \*arr admin UIs stay blocked — they are the ones with broad filesystem
and download control.

Installed as `/usr/local/bin/docker-tailnet-guard.sh`, re-applied on every dockerd
start via a drop-in at `/etc/systemd/system/docker.service.d/tailnet-guard.conf`
(dockerd rebuilds `DOCKER-USER`, so a one-shot rule would silently vanish).
Verified to survive `systemctl restart docker`.

This is also why qBittorrent/Radarr/Sonarr/Prowlarr are reachable from the LAN only.
All four ship with no authentication; `06-arr.sh` now enables forms auth on each
(credentials in `/opt/arr/.credentials`), but keeping them off the tailnet as well is
deliberate — the login is the second layer, not the only one.

The one exception is outbound: Radarr and Sonarr reach Jellyfin on 8096 from the arr
bridge subnet to refresh the library (§9). That is the `172.20.0.0/24` rule above.

### Not done

UPnP is off everywhere. No router port forwarding. The router (TP-Link) does have
UPnP enabled and will honour port-mapping requests from any LAN host — worth
disabling at the router if you care.

---

## 8. Backups

`/usr/local/bin/jellyfin-backup.sh`, driven by `jellyfin-backup.timer` at 04:00 daily,
7 archives retained in `/mnt/storage/backups/jellyfin/` (a different physical disk
from the config it backs up).

The script **stops the container before tarring**. Jellyfin uses SQLite with WAL;
tarring a live database yields a snapshot that may not restore. ~10s of downtime at
4am beats an invalid backup.

Excluded: `config/log`, `config/metadata`, `config/transcodes` — all regenerable.
Included: `config/data` (users, watch progress, library) and `config/config` (settings).

### Restore

```bash
cd /opt/jellyfin
docker compose down
mv config config.broken
tar -xzf /mnt/storage/backups/jellyfin/jellyfin-config-YYYYMMDD-HHMMSS.tar.gz
docker compose up -d
```

---

## 9. Library management (Radarr / Sonarr / Prowlarr / qBittorrent)

This stack organises the family's **own** media into Jellyfin: DVD/Blu-ray rips,
public-domain and Creative Commons titles, Internet Archive collections, and local
UZ film/TV where the household holds the rights. Radarr and Sonarr rename and
file movies/shows to match §3; Prowlarr is the shared source manager; qBittorrent
is the transfer client for those sources. Nothing is exposed publicly; UIs stay
on the LAN.

Install once from the repo:

```bash
sudo bash scripts/06-arr.sh
```

That creates `/opt/arr/` and the media/downloads tree (including one completed
folder per qBittorrent category), starts the stack, enables forms auth on all four
UIs, wires qBittorrent into Radarr/Sonarr/Prowlarr, links Prowlarr → Radarr/Sonarr
for source sync, sets Jellyfin-compatible naming, and installs a nightly config backup.

`/opt/arr/docker-compose.yml` — `lscr.io/linuxserver/{qbittorrent,radarr,sonarr,prowlarr}:latest`,
PUID/PGID 1000, TZ Asia/Tashkent. All four share one bind mount: host
`/mnt/storage` → container `/data` (enables hardlinks from incoming files into the library).

| Service | Port | Paths (container) |
|---|---|---|
| qBittorrent | 8080 | complete `/data/downloads/complete`, incomplete `/data/downloads/incomplete` |
| Radarr | 7878 | root `/data/media/movies`, category `radarr` |
| Sonarr | 8989 | root `/data/media/tv`, category `tv-sonarr` |
| Prowlarr | 9696 | shared source manager; syncs to Radarr/Sonarr |
| Jellyseerr | 5055 | request front end; talks to Radarr/Sonarr by container name |

LAN URLs (home only — blocked over Tailscale by `DOCKER-USER`):

```
http://192.168.0.146:8080   qBittorrent
http://192.168.0.146:7878   Radarr
http://192.168.0.146:8989   Sonarr
http://192.168.0.146:9696   Prowlarr
http://192.168.0.146:5055   Jellyseerr  (also reachable over Tailscale)
```

Login user/password: `/opt/arr/.credentials` (`ADMIN_USER` / `ADMIN_PASS`).

Radarr/Sonarr get read-write media access, unlike Jellyfin's read-only mount, because
organising and renaming is their purpose. Hardlinks are enabled so completed files
move into the library without doubling disk use.

### Sources

Prowlarr owns the source list; Radarr and Sonarr receive it automatically
(`fullSync`). Eight public sources are enabled on this box and all eight pass
Prowlarr's connection test. The list itself lives in Prowlarr, not in this repo —
`06-arr.sh` ships no sources, so a fresh install starts empty and you add your own.

How they distribute is worth knowing before wondering why the two apps disagree:

- Prowlarr pushes a source into an app only if that app accepts it. Radarr refuses
  any source whose movie-category search comes back empty, so its list is shorter
  than Sonarr's — see §10.9, because the reason is only visible in Prowlarr's log.
- A source exposing no usable categories reaches neither app, but stays searchable
  from Prowlarr directly.
- A movies-only source never reaches Sonarr, and a TV/anime-only source never
  reaches Radarr. Both are normal, not a misconfiguration.

Three more were attempted and not added: two sit behind CloudFlare and would need a
FlareSolverr companion container, and one was unreachable from this network. Add more
in Prowlarr → Settings → Indexers; they sync to Radarr/Sonarr on their own.

### Requesting (Jellyseerr)

Jellyfin searches **files already on disk** — it is a player, not a catalogue. A search
for a film you do not own returns "No results found", which is correct behaviour and
regularly mistaken for a broken index. Jellyseerr is the missing half: it searches the
full TMDb catalogue, and a request there tells Radarr/Sonarr to go and fetch the title.

The whole loop, once a request is made:

```
Jellyseerr  ->  Radarr/Sonarr  ->  qBittorrent  ->  hardlink into library
                                                 -> Jellyfin refresh (Connect)
```

Setup is one sign-in at `http://192.168.0.146:5055` using the Jellyfin account; the
Radarr and Sonarr servers are pre-seeded into `jellyseerr/settings.json` by this repo's
install, so the wizard only needs the media-server step. Jellyfin can be given as either
`http://host.docker.internal:8096` or `http://192.168.0.146:8096` — both resolve from the
container, and both depend on the ufw rule in §9's *Jellyfin refresh* note.

This is the one container port open to the tailnet (§7), so requests work from away.

### Checking on a request

Jellyseerr -> **Requests** is the everyday view. Two different states are shown per
title and they mean different things:

| Where | Value | Meaning |
|---|---|---|
| Request status | `1` pending / `2` approved / `3` declined | did Jellyseerr accept the ask |
| Media status | `2` pending / `3` processing / `4` partial / `5` available | has the file actually landed |

"Processing" only means Radarr owns it now. For *why* nothing is moving, the real
answer is always further down the chain:

```
Radarr -> Activity -> Queue     what is downloading, and how much is left
Radarr -> Movies -> the title   whether Radarr considers it released at all
qBittorrent                     transfer speed and seeders
```

A request can sit at *processing* indefinitely and be perfectly healthy — see §10.11.

### Jellyfin refresh

Radarr and Sonarr each hold a Connect notification (`MediaBrowser`, named "Jellyfin")
pointed at `host.docker.internal:8096` with `updateLibrary` on, firing on import,
upgrade and rename. Files therefore appear in Jellyfin straight away instead of
waiting for the scan in §10.1.

That path needs a firewall rule. Jellyfin is host-networked, so ufw genuinely filters
port 8096, and it only allowed the LAN — the call from Radarr arrives sourced from the
arr bridge subnet instead. `scripts/03-firewall.sh` opens 8096 to `172.20.0.0/24`, and
that subnet is pinned in `compose/arr.docker-compose.yml` so Docker cannot reassign it
out from under the rule.

qBittorrent has UPnP disabled so it does not punch the TP-Link. Port 6881 is not
ufw-opened to the internet.

### Backups

`/usr/local/bin/arr-backup.sh`, driven by `arr-backup.timer` at 04:15 daily, 7 archives
retained in `/mnt/storage/backups/arr/`. Stops all four containers before tarring config
(SQLite + WAL, same rationale as Jellyfin §8).

```bash
systemctl list-timers arr-backup.timer
sudo /usr/local/bin/arr-backup.sh
ls -lh /mnt/storage/backups/arr/
```

---

## 10. Gotchas found during setup

1. **Real-time monitoring does not work** through the read-only bind mount. Tested
   twice with live file drops; inotify events never reached Jellyfin. New files will
   not appear on their own — run **Dashboard → Scheduled Tasks → Scan Media Library**,
   or add an hourly trigger there. The scanner itself works fine.

2. **`HOME` had to be set to `/config`.** Running as `user: 1000:1000` left `HOME=/`,
   which uid 1000 cannot write, so ASP.NET DataProtection fell back to an in-memory
   key repository and regenerated keys on every restart. Keys now persist at
   `/config/.aspnet/DataProtection-Keys/`.

3. **Empty libraries get no watcher.** Jellyfin logs
   `Library folder /media/movies is inaccessible or empty, skipping` and does not
   attach a watcher. Harmless, but explains silence on a fresh install.

4. **`WebRootPath was not found: /wwwroot`** in the logs is benign — the web UI serves
   correctly from `/jellyfin/jellyfin-web` (verified HTTP 200).

5. **Anything writing into the media folder fails** while the mount is `:ro` — NFO
   savers, "save artwork into media folders", "save trickplay next to media". All are
   off. Drop `:ro` in the compose file if you want them.

6. **`pkexec`, not `sudo`.** Non-interactive shells have no TTY, so `sudo` cannot
   prompt. `pkexec <cmd>` raises a GNOME polkit dialog instead.

7. **qBittorrent's category folders have to exist up front.** qBittorrent creates a
   category's save path lazily, on first transfer — but Radarr and Sonarr health-check
   it immediately, and both raised
   *"places downloads in /data/downloads/complete/radarr but this directory does not
   appear to exist inside the container"*. Creating the categories is not enough;
   `06-arr.sh` now creates a directory per category from the same list.

8. **ufw blocks container → Jellyfin, and it fails by hanging.** Jellyfin is
   host-networked so ufw really does filter 8096, and it allowed only
   `192.168.0.0/24`. Radarr's library-refresh call arrives from the bridge subnet
   instead, so it was dropped — `curl` reported no response at all (`000`) rather than
   a refusal, which reads like a dead service rather than a firewall. Allowing
   `172.20.0.0/24` to 8096 fixes it; the subnet is pinned in compose so the rule
   cannot drift.

9. **Radarr declines some sources, and only says so in Prowlarr's log.** Prowlarr
   pushes every source it holds, but Radarr rejects any whose movie-category search
   returns nothing, answering `400` with
   *"Query successful, but no results in the configured categories were returned"*.
   Prowlarr surfaces that as a sync warning in its log, not in its UI, so a source can
   look enabled in Prowlarr and simply be missing from Radarr.

10. **Pre-filling Jellyseerr's Jellyfin hostname breaks its own setup wizard.** Seeding
    `jellyfin.ip` in `settings.json` to save a wizard step makes first-time sign-in fail
    with `500` and `{"error":"Jellyfin hostname already configured"}` — it treats a
    present hostname as "already set up". Nothing is written to the log, so the browser
    shows only a generic *Something went wrong*, and the obvious suspects (password,
    URL, reachability) are all innocent. Seed `radarr`/`sonarr` only; leave `.jellyfin`
    empty for the wizard to fill. Its URL field also wants a **bare hostname** — the form
    supplies `http://` and the port separately, so pasting a full URL silently builds
    `http://http://host:8096`.

11. **A film still in cinemas looks like a broken request.** It sits at *processing*
    forever with an empty queue. That is correct behaviour twice over: Radarr's
    `minimumAvailability: released` holds anything with no digital or physical release
    date, and the quality profile rejects what does exist. A real search returned 18
    results of which 16 were rejected — 15 `TELESYNC`, 1 `CAM` — i.e. camcorder rips.
    Nothing is stuck; it will grab itself when a proper release appears. Lowering
    `minimumAvailability` to `inCinemas` only buys you a filmed-off-a-screen copy.

---

## 11. Using it (for everyone else in the house)

Two apps, two jobs. You **ask** in one and **watch** in the other.

| App | What it holds | You go there to |
|---|---|---|
| **Jellyseerr** | every film and show that exists | ask for something |
| **Jellyfin** | only what is already downloaded | watch it |

Searching Jellyfin for something the house does not own returns nothing, and that is
not a fault — it only ever searches the shelf, never the shop.

### Two addresses, and they work everywhere

```
Watch    http://100.83.255.76:8096      Jellyfin
Request  http://100.83.255.76:5055      Jellyseerr
```

These are the Tailscale addresses, so they work at home *and* away. The
`192.168.0.146` equivalents work only at home; using the Tailscale pair everywhere
means one set to remember and nothing to change when you leave the house.

### At home

On the house Wi-Fi, both just work. Search in Jellyseerr, press **Request**, wait,
then open Jellyfin and play it. Nothing else is needed — the server fetches, renames
and files it on its own.

### Away, including a Google TV you travel with

Everything here is deliberately invisible from the public internet, so a device away
from home needs **Tailscale** to tunnel back. Set it up once, ideally while the device
is still at home:

1. Play Store -> install **Tailscale**
2. Open it; it shows a code and a link. On a phone, open that link and approve the
   device on the same account
3. Turn the VPN switch **on** and leave it on
4. Play Store -> install **Jellyfin**
5. Jellyfin -> Add Server -> `http://100.83.255.76:8096`, then sign in

After that the device works anywhere with Wi-Fi, unchanged. If it ever says it cannot
reach the server, check the Tailscale switch first — that is nearly always the cause.

Requesting with a TV remote is miserable; request on a phone and watch on the TV.

### What to expect

Nothing appears instantly. Radarr searches every source before choosing one, then the
file has to transfer, so minutes to an hour is normal depending on size and seeders.
Progress lives in Jellyseerr -> Requests (§9). The \*arr admin UIs and qBittorrent stay
home-only; Jellyseerr is the one management page reachable from away, because asking
for a film from a hotel is the entire point of it.

---

## 12. Operations

```bash
# Status
docker ps
docker logs --tail 50 jellyfin
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.0.146:8096/health

# *arr health -- empty [] means clean. API keys live in /opt/arr/<app>/config.xml
for a in radarr:7878:v3 sonarr:8989:v3 prowlarr:9696:v1; do
  IFS=: read -r n p v <<<"$a"
  k=$(grep -oP '(?<=<ApiKey>)[^<]+' "/opt/arr/$n/config.xml" | head -1)
  echo "$n: $(curl -fsS -H "X-Api-Key: $k" "http://127.0.0.1:$p/api/$v/health")"
done

# Restart / update
cd /opt/jellyfin && docker compose restart
cd /opt/jellyfin && docker compose pull && docker compose up -d   # bump the pin first
cd /opt/arr && docker compose restart
cd /opt/arr && docker compose pull && docker compose up -d

# Tailscale
tailscale status
tailscale netcheck          # direct vs relayed

# Firewall
sudo ufw status verbose
sudo iptables -L DOCKER-USER -n -v

# Backups
systemctl list-timers jellyfin-backup.timer arr-backup.timer
sudo /usr/local/bin/jellyfin-backup.sh
sudo /usr/local/bin/arr-backup.sh
ls -lh /mnt/storage/backups/jellyfin/ /mnt/storage/backups/arr/
```

---

## 13. Why Jellyfin and not Plex

Since 2025-04-29 Plex requires the **server admin** to hold Plex Pass ($6.99/mo,
$69.99/yr, $249.99 lifetime) for remote streaming of personal media, or each viewer
to buy a Remote Watch Pass. Jellyfin is GPL, includes hardware transcoding and
remote access, and costs nothing. Plex has nicer TV apps and simpler sharing —
revisit only if the family finds Jellyfin clients painful.

Unraid, often recommended alongside, is a paid NAS OS ($49–$249). Ubuntu + Docker
covers the same ground here for free.

**Total recurring cost: $0.**
