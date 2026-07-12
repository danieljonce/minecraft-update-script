#!/usr/bin/env bash
set -euo pipefail
#
# update-mc-plugins.sh
# ===========================================================================
# Keeps a Paper/Spigot server's cross-version + Bedrock plugins up to date, and
# tells you which Paper (Minecraft) version is safe to run.
#
# Works with ANY Minecraft server install that has a plugins/ folder -- Crafty,
# Pterodactyl, systemd, docker bind-mount, or a plain directory. It only touches
# files; it never starts or stops your server.
#
# Plugins handled, each from its project's own official channel:
#     ViaVersion, ViaBackwards, ViaRewind   -> Hangar   (hangar.papermc.io)
#     Geyser-Spigot, Floodgate-Spigot       -> GeyserMC (download.geysermc.org)
#
# Paper policy:
#   * Each plugin reports the highest Minecraft version it supports.
#   * The CEILING = the LOWEST of those maxes (lowest common denominator), so no
#     plugin is left behind. (Usually Geyser is the laggard, but nothing assumes
#     that -- whichever plugin is furthest behind sets the limit.)
#   * Two INDEPENDENT checks are reported:
#       (a) compatibility  : is installed Paper ABOVE the ceiling? -> plugins break
#       (b) stable build   : is a newer STABLE Paper build available at/below it?
#     Running a Paper newer than the newest STABLE build is fine so long as (a)
#     holds -- it just means Paper hasn't promoted a stable build for it yet.
#   * Default: report only. With --update-paper it will apply an upgrade.
#   * ViaVersion then lets clients NEWER than the server connect, so players who
#     auto-update keep working.
#
# Cron-safe: single-instance lock; resolves everything first and touches nothing
# unless a plugin's checksum actually differs (so idle days are a no-op).
#
# IMPORTANT: stop your server before running this (or run it while stopped).
# Swapping jars under a running server does nothing until the next restart, and
# can leave a plugin's on-disk jar out of sync with the running code.
#
# Requires: bash, curl, jq, sha256sum, flock   (Debian/Ubuntu: apt install jq)
# ===========================================================================

# Some APIs (notably PaperMC's Fill) require a descriptive User-Agent with a
# contact URL. Point this at your own repo/site if you like.
UA="mc-plugin-updater/6.0 (+https://github.com/self-hosted/mc-plugin-updater)"

log()  { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
warn() { printf '%s WARNING: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
die()  { printf '%s ERROR: %s\n'   "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
Usage: update-mc-plugins.sh <server-dir> [options]
   or: update-mc-plugins.sh --plugins-dir <path> [options]

Installs/updates ViaVersion, ViaBackwards, ViaRewind, Geyser-Spigot and
Floodgate-Spigot, and checks whether your Paper version is compatible with them.

<server-dir> is the folder containing your server jar and plugins/ .
Plugins go to <server-dir>/plugins unless --plugins-dir says otherwise.

Options:
  --plugins-dir <path>       Plugins folder (default: <server-dir>/plugins).
                             If given alone, the server dir is its parent.
  --channel <release|beta|any>
                             Build channel (default: release = stable only).
                             On Hangar: release = Release channel, beta =
                             Snapshot. On GeyserMC: release = default (promoted)
                             channel. Applied to all plugins, so the Via trio
                             always stays on one channel together.
  --update-paper             Upgrade Paper to the newest stable build at/below
                             the ceiling (default is to only report it).
  --allow-downgrade          Permit --update-paper to roll Paper DOWN, when the
                             installed version is above the plugin ceiling.
  --server-jar <name>        Paper jar filename (auto-detected when unambiguous).
  --no-paper                 Skip the Paper check entirely; just do plugins.
  --skip <name[,name...]>    Don't manage these plugins (ViaVersion, ViaBackwards,
                             ViaRewind, Geyser, Floodgate).
  --viaversion-url <url>     Override a plugin's download URL (skips its API).
  --viabackwards-url <url>
  --viarewind-url <url>
  --geyser-url <url>
  --floodgate-url <url>
  --keep-backups <n>         Keep only the newest n backup sets (default: 10).
  --dry-run                  Report the full plan; change nothing.
  -y, --yes                  Don't prompt for confirmation if the server is
                             running (the prompt only appears on a terminal;
                             it never blocks a cron run).
  -h, --help                 Show this help.

Examples:
  update-mc-plugins.sh /srv/minecraft/survival --dry-run
  update-mc-plugins.sh /srv/minecraft/survival --update-paper
  update-mc-plugins.sh --plugins-dir /opt/mc/plugins --no-paper

Cron (daily 04:30; stop the server around it if you want jars to load promptly):
  30 4 * * * /opt/scripts/update-mc-plugins.sh /srv/minecraft/survival \
               >> /var/log/mc-plugins.log 2>&1
EOF
}

# --------------------------- defaults --------------------------------------
SERVER_DIR=""
PLUGINS_DIR=""
CHANNEL="release"
UPDATE_PAPER=0
ALLOW_DOWNGRADE=0
SERVER_JAR=""
NO_PAPER=0
SKIP_LIST=""
KEEP_BACKUPS=10
DRY_RUN=0
ASSUME_YES=0
VIAVERSION_URL=""
VIABACKWARDS_URL=""
VIAREWIND_URL=""
GEYSER_URL=""
FLOODGATE_URL=""

# --------------------------- argument parsing ------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --plugins-dir)      PLUGINS_DIR="${2:-}";      [ -n "$PLUGINS_DIR" ]      || die "Missing value for --plugins-dir";      shift 2 ;;
    --channel)          CHANNEL="${2:-}";          case "$CHANNEL" in release|beta|any) ;; *) die "Invalid --channel '$CHANNEL' (use: release, beta, any)";; esac; shift 2 ;;
    --update-paper)     UPDATE_PAPER=1; shift ;;
    --allow-downgrade)  ALLOW_DOWNGRADE=1; shift ;;
    --server-jar)       SERVER_JAR="${2:-}";       [ -n "$SERVER_JAR" ]       || die "Missing value for --server-jar";       shift 2 ;;
    --no-paper)         NO_PAPER=1; shift ;;
    --skip)             SKIP_LIST="${2:-}";        [ -n "$SKIP_LIST" ]        || die "Missing value for --skip";             shift 2 ;;
    --keep-backups)     KEEP_BACKUPS="${2:-}";     shift 2 ;;
    --viaversion-url)   VIAVERSION_URL="${2:-}";   shift 2 ;;
    --viabackwards-url) VIABACKWARDS_URL="${2:-}"; shift 2 ;;
    --viarewind-url)    VIAREWIND_URL="${2:-}";    shift 2 ;;
    --geyser-url)       GEYSER_URL="${2:-}";       shift 2 ;;
    --floodgate-url)    FLOODGATE_URL="${2:-}";    shift 2 ;;
    --dry-run)          DRY_RUN=1; shift ;;
    -y|--yes)           ASSUME_YES=1; shift ;;
    -h|--help)          usage; exit 0 ;;
    -*)                 die "Unknown option: $1" ;;
    *)                  if [ -z "$SERVER_DIR" ]; then SERVER_DIR="$1"; else die "Unexpected argument: $1"; fi; shift ;;
  esac
done

# --------------------------- dependency checks -----------------------------
command -v curl      >/dev/null 2>&1 || die "curl is required"
command -v jq        >/dev/null 2>&1 || die "jq is required (Debian: sudo apt install jq)"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required (coreutils)"
command -v flock     >/dev/null 2>&1 || die "flock is required (util-linux)"

# --------------------------- resolve directories ---------------------------
# Either a server dir (plugins = <dir>/plugins) or a plugins dir (server dir =
# its parent). No paths are assumed or guessed.
if [ -n "$SERVER_DIR" ]; then
  SERVER_DIR="${SERVER_DIR%/}"
  [ -d "$SERVER_DIR" ] || die "Server dir not found: $SERVER_DIR"
  [ -n "$PLUGINS_DIR" ] || PLUGINS_DIR="${SERVER_DIR}/plugins"
elif [ -n "$PLUGINS_DIR" ]; then
  PLUGINS_DIR="${PLUGINS_DIR%/}"
  [ -d "$PLUGINS_DIR" ] || die "Plugins dir not found: $PLUGINS_DIR"
  SERVER_DIR="$(dirname "$PLUGINS_DIR")"
else
  usage; exit 1
fi
PLUGINS_DIR="${PLUGINS_DIR%/}"
[ -d "$PLUGINS_DIR" ] || die "Plugins dir not found: $PLUGINS_DIR"
[ -w "$PLUGINS_DIR" ] || die "Plugins dir is not writable: $PLUGINS_DIR (run as the user that owns the server)"

# --------------------------- single-instance lock --------------------------
LOCK_KEY="$(printf '%s' "$PLUGINS_DIR" | tr -c 'A-Za-z0-9' '_')"
LOCK_FILE="${LOCK_FILE:-/tmp/mc-plugin-updater.${LOCK_KEY}.lock}"
exec 9>"$LOCK_FILE" || die "Cannot open lock file: $LOCK_FILE"
flock -n 9 || die "Another run is already in progress (lock: $LOCK_FILE)"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR" 2>/dev/null || true' EXIT

# ===========================================================================
# helpers
# ===========================================================================

# ---- version math ----
ver_le() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]; }
ver_lt() { [ "$1" != "$2" ] && ver_le "$1" "$2"; }
max_release_version() { { grep -E '^[0-9]+(\.[0-9]+)+$' || true; } | sort -V | tail -n1; }
min_of() { printf '%s\n' "$@" | { grep -E '^[0-9]+(\.[0-9]+)+$' || true; } | sort -V | head -n1; }

# ---- hashing ----
hash_file() {  # <algo> <file>
  case "$1" in
    sha256) sha256sum "$2" | awk '{print $1}' ;;
    sha512) sha512sum "$2" | awk '{print $1}' ;;
    *)      echo "" ;;
  esac
}
sha_of() { if [ -f "$2" ]; then hash_file "$1" "$2"; else echo ""; fi; }  # <algo> <file>

# ---- Hangar (hangar.papermc.io): official channel for the Via plugins ----
# Public read endpoints; no auth. Versions carry an explicit channel
# (Release/Snapshot), a sha256, and platformDependencies (supported MC versions).
HANGAR="https://hangar.papermc.io"
hangar_resolve() {  # <slug> <platform> <channel> -> TSV: url hash algo filename version game_versions
  local slug="$1" platform="$2" channel="${3:-release}" name vjson url sha fname games chan algo="none"
  case "$channel" in
    release) name="$(curl -fsSL -A "$UA" "${HANGAR}/api/v1/projects/${slug}/latestrelease" 2>/dev/null || true)" ;;
    beta)    name="$(curl -fsSL -A "$UA" "${HANGAR}/api/v1/projects/${slug}/latest?channel=Snapshot" 2>/dev/null || true)"
             [ -n "$name" ] || name="$(curl -fsSL -A "$UA" "${HANGAR}/api/v1/projects/${slug}/latestrelease" 2>/dev/null || true)" ;;
    *)       name="$(curl -fsSL -A "$UA" "${HANGAR}/api/v1/projects/${slug}/versions?limit=1&offset=0" 2>/dev/null \
                    | jq -r '.result[0].name // empty' 2>/dev/null || true)" ;;
  esac
  name="$(printf '%s' "$name" | tr -d '\r\n"')"
  [ -n "$name" ] || return 1
  vjson="$(curl -fsSL -A "$UA" "${HANGAR}/api/v1/projects/${slug}/versions/${name}" 2>/dev/null || true)"
  [ -n "$vjson" ] || return 1
  sha="$(printf '%s' "$vjson"   | jq -r --arg p "$platform" '.downloads[$p].fileInfo.sha256Hash // empty' 2>/dev/null || true)"
  fname="$(printf '%s' "$vjson" | jq -r --arg p "$platform" '.downloads[$p].fileInfo.name // empty' 2>/dev/null || true)"
  games="$(printf '%s' "$vjson" | jq -r --arg p "$platform" '(.platformDependencies[$p] // []) | join(",")' 2>/dev/null || true)"
  chan="$(printf '%s' "$vjson"  | jq -r '.channel.name // ""' 2>/dev/null || true)"
  [ -n "$fname" ] || [ -n "$games" ] || return 1
  [ -n "$sha" ] && algo="sha256"
  [ -z "$fname" ] && fname="${slug}-${name}.jar"
  url="${HANGAR}/api/v1/projects/${slug}/versions/${name}/${platform}/download"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$url" "$sha" "$algo" "$fname" "${name} [${chan}]" "$games"
}

# ---- GeyserMC download API: official channel for Geyser / Floodgate ----
# Builds are marked "default" (promoted/stable) or "experimental".
geysermc_resolve() {  # <project> <platform> <channel> -> TSV: url hash algo filename version ""
  local project="$1" platform="$2" channel="${3:-release}" base json ver url="" name="" sha="" algo="none" bsel build ch
  base="https://download.geysermc.org/v2/projects/${project}"
  json="$(curl -fsSL -A "$UA" "${base}/versions/latest/builds" 2>/dev/null || true)"
  if [ -n "$json" ]; then
    ver="$(printf '%s' "$json" | jq -r '.version // empty' 2>/dev/null || true)"
    bsel="$(printf '%s' "$json" | jq -r --arg ch "$channel" --arg p "$platform" '
      [ .builds[]
        | select(($ch != "release") or (.channel == "default"))
        | select(.downloads[$p] != null) ]
      | last
      | if . == null then empty
        else [ (.build|tostring), .downloads[$p].name, (.downloads[$p].sha256 // ""), (.channel // "") ] | @tsv end
    ' 2>/dev/null || true)"
    if [ -n "$bsel" ]; then
      IFS=$'\t' read -r build name sha ch <<< "$bsel"
      [ -n "$sha" ] && algo="sha256"
      [ -n "$ver" ] && [ -n "$build" ] && url="${base}/versions/${ver}/builds/${build}/downloads/${platform}"
      ver="${ver}-b${build} [${ch}]"
    fi
  fi
  [ -z "$url" ]  && url="${base}/versions/latest/builds/latest/downloads/${platform}"
  [ -z "$name" ] && name="${project}-${platform}.jar"
  [ -z "$ver" ]  && ver="latest"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$url" "$sha" "$algo" "$name" "$ver" ""
}

# ---- Modrinth: metadata only (Geyser's supported MC versions, for the ceiling) ----
# The GeyserMC API doesn't publish supported Minecraft versions; Modrinth does.
# Nothing is downloaded from here -- it's read purely to compute the ceiling.
modrinth_max_mc() {  # <slug>
  local slug="$1" loader json gv
  for loader in paper spigot bukkit; do
    json="$(curl -fsSL -A "$UA" \
      "https://api.modrinth.com/v2/project/${slug}/version?loaders=%5B%22${loader}%22%5D" 2>/dev/null)" || continue
    gv="$(printf '%s' "$json" | jq -r 'sort_by(.date_published) | reverse | .[0].game_versions // [] | .[]' 2>/dev/null || true)"
    [ -n "$gv" ] && { printf '%s\n' "$gv" | max_release_version; return 0; }
  done
  return 1
}

# ---- Paper: PaperMC "Fill" v3 API (the old api.papermc.io/v2 shut down 2026-07-01) ----
PAPER_API="https://fill.papermc.io/v3/projects/paper"
paper_all_versions() {
  curl -fsSL -A "$UA" "$PAPER_API" 2>/dev/null \
    | jq -r '.versions | to_entries[] | .value[]' 2>/dev/null || true
}
paper_stable_for_version() {  # <version> -> TSV: build url sha256
  local v="$1" json
  json="$(curl -fsSL -A "$UA" "${PAPER_API}/versions/${v}/builds" 2>/dev/null || true)"
  [ -n "$json" ] || return 1
  printf '%s' "$json" | jq -e 'type == "object"' >/dev/null 2>&1 && return 1   # error object, not a build list
  printf '%s' "$json" | jq -r '
    [ .[] | select(.channel=="STABLE") ] | .[0] | select(. != null)
    | [ (.id|tostring),
        .downloads."server:default".url,
        (.downloads."server:default".checksums.sha256 // "") ] | @tsv
  ' 2>/dev/null
}
paper_recommend() {  # <ceiling> -> TSV: version build url sha256
  local ceiling="$1" v info tried=0
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    ver_le "$v" "$ceiling" || continue
    tried=$((tried+1)); [ "$tried" -gt 15 ] && break
    if info="$(paper_stable_for_version "$v")" && [ -n "$info" ]; then
      printf '%s\t%s\n' "$v" "$info"; return 0
    fi
  done < <(paper_all_versions | { grep -E '^[0-9]+(\.[0-9]+)+$' || true; } | sort -V -r)
  return 1
}
installed_paper_mc() {  # read <server-dir>/version_history.json (written by Paper)
  local vh="${SERVER_DIR}/version_history.json" cur=""
  [ -f "$vh" ] || return 0
  cur="$(jq -r '.currentVersion // empty' "$vh" 2>/dev/null || true)"
  printf '%s' "$cur" | sed -n 's/.*MC: \([0-9][0-9.]*\).*/\1/p'
}
detect_server_jar() {
  if [ -n "$SERVER_JAR" ]; then printf '%s' "${SERVER_DIR}/${SERVER_JAR}"; return 0; fi
  local jars=() paperish=() f
  while IFS= read -r f; do jars+=("$f"); done < <(find "$SERVER_DIR" -maxdepth 1 -type f -name '*.jar' 2>/dev/null | sort)
  for f in "${jars[@]}"; do
    case "$(basename "$f" | tr '[:upper:]' '[:lower:]')" in *paper*) paperish+=("$f");; esac
  done
  if   [ "${#paperish[@]}" -eq 1 ]; then printf '%s' "${paperish[0]}"; return 0
  elif [ "${#jars[@]}"     -eq 1 ]; then printf '%s' "${jars[0]}";     return 0
  fi
  return 1
}

# ---- download / install ----
fetch_verify() {  # <url> <hash|""> <algo> <out>
  local url="$1" want="$2" algo="$3" out="$4" got tries=0
  while :; do
    curl -fsSL -A "$UA" "$url" -o "$out" 2>/dev/null && break
    tries=$((tries+1)); [ "$tries" -ge 3 ] && die "Download failed: $url"; sleep 3
  done
  [ -s "$out" ] || die "Downloaded file is empty: $url"
  [ "$(head -c2 "$out")" = "PK" ] || die "Not a valid jar (bad build or download error?): $url"
  if [ -n "$want" ] && [ "$algo" != "none" ]; then
    got="$(hash_file "$algo" "$out")"
    [ "$got" = "$want" ] || die "Checksum mismatch for $url"
  fi
}
BACKUP_STAMP="$(date +%Y%m%d-%H%M%S)"
backup_file() {  # <path> <backup-root>
  local f="$1" root="$2" bdir
  [ -f "$f" ] || return 0
  bdir="${root}/${BACKUP_STAMP}"
  mkdir -p "$bdir"; cp -p "$f" "$bdir/"
  log "  backed up $(basename "$f") -> ${bdir}/"
}
prune_backups() {  # <backup-root> <keep>
  local root="$1" keep="$2" d
  [ -d "$root" ] || return 0
  [ "$keep" -gt 0 ] 2>/dev/null || return 0
  while IFS= read -r d; do
    [ -n "$d" ] && rm -rf "$d" && log "  pruned old backup $(basename "$d")"
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d | sort -r | tail -n +$((keep+1)))
}

# plugin_dups <lowercase-stem> <canonical-dest> : other jars that are the SAME
# plugin under a different filename (e.g. ViaVersion-5.10.0.jar vs ViaVersion.jar).
# Paper refuses to load when two files declare the same plugin name.
plugin_dups() {
  local stem="$1" dest="$2" f base low
  for f in "${PLUGINS_DIR}"/*.jar; do
    [ -e "$f" ] || continue
    [ "$f" = "$dest" ] && continue
    base="$(basename "$f")"; low="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
    case "$low" in "${stem}"*) printf '%s\n' "$f" ;; esac
  done
}

# Is a java process actually running THIS server directory?
# Most servers launch as `java -jar paper.jar` with the server dir as the working
# directory, so the path never appears in the command line. Checking each java
# process's cwd (via /proc) is the reliable test; the cmdline is a fallback for
# setups that do pass an absolute path.
# Prints the PID(s) on success. Returns 1 if none found or if we can't tell.
server_running_pids() {
  command -v pgrep >/dev/null 2>&1 || return 1
  local pid cwd found=0 real
  real="$(cd "$SERVER_DIR" 2>/dev/null && pwd -P)" || real="$SERVER_DIR"
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    # (a) working directory == the server dir (covers the common case)
    cwd="$(readlink -f "/proc/${pid}/cwd" 2>/dev/null || true)"
    if [ -n "$cwd" ] && [ "$cwd" = "$real" ]; then
      printf '%s\n' "$pid"; found=1; continue
    fi
    # (b) fallback: an absolute server path in the command line
    if tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | grep -Fq -- "$real"; then
      printf '%s\n' "$pid"; found=1
    fi
  done < <( { pgrep -x java 2>/dev/null; pgrep -f 'java .*-jar' 2>/dev/null; } | sort -u )
  [ "$found" = 1 ]
}

# ===========================================================================
# main
# ===========================================================================
main() {
  log "=== plugin update check ==="
  log "server dir:  $SERVER_DIR"
  log "plugins dir: $PLUGINS_DIR"
  log "channel:     ${CHANNEL} (release = stable only)"
  [ "$DRY_RUN" = 1 ] && log "(dry-run: no changes will be made)"

  # Report whether the server is up. Always say something, so silence is never
  # mistaken for "it checked and found nothing".
  local run_pids="" reply=""
  if ! command -v pgrep >/dev/null 2>&1 || [ ! -d /proc/1 ]; then
    log "server state: unknown (can't inspect processes here)"
  elif run_pids="$(server_running_pids)"; then
    run_pids="$(printf '%s' "$run_pids" | tr '\n' ' ')"; run_pids="${run_pids% }"
    if [ "$DRY_RUN" = 1 ]; then
      log "server state: RUNNING (pid ${run_pids}) -- stop it before a real run, or the new jars won't load until you restart."
    else
      warn "Server appears to be RUNNING (pid ${run_pids})."
      warn "Jars swapped now will NOT load until you restart, and a plugin's on-disk jar may not match the running code."
      # Decide whether we can actually ask. /dev/tty may EXIST but be unopenable
      # (e.g. under cron), so test by opening it -- not with [ -e ].
      local can_prompt=0
      if [ "$ASSUME_YES" = 0 ] && { exec 3</dev/tty; } 2>/dev/null; then can_prompt=1; fi
      if [ "$ASSUME_YES" = 1 ]; then
        log "Continuing anyway (--yes)."
      elif [ "$can_prompt" = 1 ]; then
        printf 'Continue anyway? [y/N] ' >&2
        read -r reply <&3 || reply=""
        exec 3<&-
        case "$reply" in
          [yY]|[yY][eE][sS]) log "Continuing at your request." ;;
          *) log "Aborted. Stop the server, then re-run."; return 0 ;;
        esac
      else
        # Non-interactive (cron): never block, and never silently abort.
        warn "No terminal to prompt on -- continuing without asking. Restart the server afterwards so the new jars load. (Use --yes to silence this.)"
      fi
    fi
  else
    log "server state: stopped (no java process using this directory)"
  fi

  # --- plugin table ---
  local NAMES=(ViaVersion ViaBackwards ViaRewind Geyser Floodgate)
  local SRC=(hangar hangar hangar geysermc geysermc)
  local HSLUG=(ViaVersion ViaBackwards ViaRewind "" "")     # Hangar project slug
  local GPROJ=("" "" "" geyser floodgate)                   # GeyserMC project id
  local MCSLUG=("" "" "" geyser "")                         # Modrinth slug: ceiling metadata only
  local DESTS=("${PLUGINS_DIR}/ViaVersion.jar" "${PLUGINS_DIR}/ViaBackwards.jar" "${PLUGINS_DIR}/ViaRewind.jar" "${PLUGINS_DIR}/Geyser-Spigot.jar" "${PLUGINS_DIR}/floodgate-spigot.jar")
  local STEM=(viaversion viabackwards viarewind geyser-spigot floodgate-spigot)
  local OVERR=("$VIAVERSION_URL" "$VIABACKWARDS_URL" "$VIAREWIND_URL" "$GEYSER_URL" "$FLOODGATE_URL")
  local URLS=() SHAS=() HALGO=() VERS=() MAXV=() NEED=() DUPS=() SKIPPED=()
  local n url sha algo file ver games mx
  local GEYSER_MAX_UNKNOWN=0

  # --- honour --skip ---
  for n in 0 1 2 3 4; do
    SKIPPED[$n]=0
    if [ -n "$SKIP_LIST" ]; then
      case ",$(printf '%s' "$SKIP_LIST" | tr '[:upper:]' '[:lower:]')," in
        *",$(printf '%s' "${NAMES[$n]}" | tr '[:upper:]' '[:lower:]'),"*) SKIPPED[$n]=1 ;;
      esac
    fi
  done

  # --- resolve each plugin + its max supported MC version ---
  for n in 0 1 2 3 4; do
    URLS[$n]=""; SHAS[$n]=""; HALGO[$n]="none"; VERS[$n]="-"; MAXV[$n]=""
    [ "${SKIPPED[$n]}" = 1 ] && { VERS[$n]="skipped"; continue; }

    if [ -n "${OVERR[$n]}" ]; then
      URLS[$n]="${OVERR[$n]}"; VERS[$n]="manual-url"
      [ "${NAMES[$n]}" = "Geyser" ] && GEYSER_MAX_UNKNOWN=1
      log "${NAMES[$n]}: using provided URL (no version metadata)"
    elif [ "${SRC[$n]}" = "hangar" ]; then
      if ! IFS=$'\t' read -r url sha algo file ver games < <(hangar_resolve "${HSLUG[$n]}" PAPER "$CHANNEL"); then
        die "Could not resolve ${NAMES[$n]} from Hangar (${HANGAR}/${HSLUG[$n]}, channel '$CHANNEL'). Try --channel any, or pass --$(printf '%s' "${NAMES[$n]}" | tr '[:upper:]' '[:lower:]')-url <url>."
      fi
      URLS[$n]="$url"; SHAS[$n]="$sha"; HALGO[$n]="$algo"; VERS[$n]="$ver"
      MAXV[$n]="$(printf '%s\n' "${games//,/$'\n'}" | max_release_version)"
    else
      if ! IFS=$'\t' read -r url sha algo file ver games < <(geysermc_resolve "${GPROJ[$n]}" spigot "$CHANNEL"); then
        die "Could not resolve ${NAMES[$n]} from the GeyserMC download API. Pass --$(printf '%s' "${NAMES[$n]}" | tr '[:upper:]' '[:lower:]')-url <url> if this persists."
      fi
      URLS[$n]="$url"; SHAS[$n]="$sha"; HALGO[$n]="$algo"; VERS[$n]="$ver"
      if [ -n "${MCSLUG[$n]}" ]; then
        mx="$(modrinth_max_mc "${MCSLUG[$n]}" || true)"
        MAXV[$n]="$mx"
        [ "${NAMES[$n]}" = "Geyser" ] && [ -z "$mx" ] && GEYSER_MAX_UNKNOWN=1
      fi
    fi
  done

  # --- ceiling = lowest of the per-plugin maxes (lowest common denominator) ---
  local maxes=() ceiling="" limiters=() known=0 ceil_note="" paper_safe=1
  for n in 0 1 2 3 4; do [ -n "${MAXV[$n]}" ] && { maxes+=("${MAXV[$n]}"); known=$((known+1)); }; done
  if [ "${#maxes[@]}" -gt 0 ]; then
    ceiling="$(min_of "${maxes[@]}")"
    for n in 0 1 2 3 4; do [ -n "${MAXV[$n]}" ] && [ "${MAXV[$n]}" = "$ceiling" ] && limiters+=("${NAMES[$n]}"); done
    if [ "${#limiters[@]}" -ge "$known" ]; then ceil_note="all agree"
    else ceil_note="limited by ${limiters[*]}"; fi
  fi
  log "Plugin max MC versions: $(for n in 0 1 2 3 4; do printf '%s=%s ' "${NAMES[$n]}" "${MAXV[$n]:-?}"; done)"

  if [ "$NO_PAPER" = 1 ]; then
    paper_safe=0
    log "Paper check skipped (--no-paper)."
  elif [ "$GEYSER_MAX_UNKNOWN" = 1 ] || [ -z "$ceiling" ]; then
    paper_safe=0
    warn "Could not determine Geyser's supported Minecraft version; skipping the Paper check (plugins still update)."
  else
    log "Compatibility ceiling (lowest common denominator): ${ceiling}  (${ceil_note})"
  fi

  # --- Paper: compatibility (vs ceiling) and stable-build availability (vs newest stable) ---
  local rec_paper="" paper_build="" paper_url="" paper_sha="" installed_mc="" paper_action="none"
  if [ "$paper_safe" = 1 ]; then
    local pinfo; pinfo="$(paper_recommend "$ceiling" || true)"
    [ -n "$pinfo" ] && IFS=$'\t' read -r rec_paper paper_build paper_url paper_sha <<< "$pinfo"
    installed_mc="$(installed_paper_mc || true)"
    log "Paper: installed=${installed_mc:-unknown}  newest-stable-within-ceiling=${rec_paper:-unknown} (build ${paper_build:-?})"

    if [ -n "$installed_mc" ]; then
      if ver_lt "$ceiling" "$installed_mc"; then
        # (a) genuinely above what the plugins support -> this is the one that breaks things
        warn "Installed Paper ${installed_mc} is ABOVE the plugin ceiling ${ceiling}; plugins (esp. ${limiters[*]:-Geyser}) may break."
        if [ -n "$rec_paper" ] && [ "$UPDATE_PAPER" = 1 ] && [ "$ALLOW_DOWNGRADE" = 1 ]; then
          paper_action="downgrade"
        elif [ "$UPDATE_PAPER" = 1 ]; then
          warn "Refusing to roll Paper DOWN without --allow-downgrade (world-compat risk). Back up your world, then re-run with --allow-downgrade."
        fi
      else
        log "Paper ${installed_mc} is within the plugin ceiling ${ceiling} -- compatible."
        if [ -n "$rec_paper" ]; then
          if ver_lt "$installed_mc" "$rec_paper"; then
            # (b) a newer STABLE build exists at/below the ceiling
            if [ "$UPDATE_PAPER" = 1 ]; then paper_action="upgrade"
            else log "Paper update AVAILABLE: ${installed_mc} -> ${rec_paper} (stable). Re-run with --update-paper to apply."; fi
          elif ver_lt "$rec_paper" "$installed_mc"; then
            log "No stable Paper build for ${installed_mc} yet (newest stable is ${rec_paper}); you're on a pre-stable build. Compatible with your plugins -- no action needed."
          else
            log "Paper is already at the newest stable version within the ceiling."
          fi
        fi
      fi
    else
      log "Could not read the installed Paper version (no version_history.json); skipping the Paper comparison."
    fi
  fi

  # --- plan: what actually needs doing? ---
  local changed=() worklist=() have status ndup
  log "Plugin status:"
  for n in 0 1 2 3 4; do
    NEED[$n]=0; DUPS[$n]=""
    if [ "${SKIPPED[$n]}" = 1 ]; then
      log "  - ${NAMES[$n]}: skipped (--skip)"
      continue
    fi
    if [ ! -f "${DESTS[$n]}" ]; then NEED[$n]=1; status="install"
    elif [ -z "${SHAS[$n]}" ] || [ "${HALGO[$n]}" = "none" ]; then NEED[$n]=0; status="present (can't verify)"
    else
      have="$(sha_of "${HALGO[$n]}" "${DESTS[$n]}")"
      if [ "$have" = "${SHAS[$n]}" ]; then status="current"; else NEED[$n]=1; status="update"; fi
    fi
    DUPS[$n]="$(plugin_dups "${STEM[$n]}" "${DESTS[$n]}")"
    ndup=0; [ -n "${DUPS[$n]}" ] && ndup="$(printf '%s\n' "${DUPS[$n]}" | grep -c .)"
    [ "$ndup" -gt 0 ] && status="${status}, ${ndup} duplicate jar(s) to remove"
    [ "${NEED[$n]}" = 1 ] && changed+=("$n")
    { [ "${NEED[$n]}" = 1 ] || [ "$ndup" -gt 0 ]; } && worklist+=("$n")
    log "  - ${NAMES[$n]}: ${VERS[$n]}  [${status}]"
  done

  if [ "${#worklist[@]}" -eq 0 ] && [ "$paper_action" = "none" ]; then
    log "Everything is current. Nothing to do."
    log "=== no action taken ==="
    return 0
  fi

  # --- identify the Paper jar if we're going to change it ---
  local server_jar=""
  if [ "$paper_action" != "none" ]; then
    if server_jar="$(detect_server_jar)"; then
      log "Paper ${paper_action}: ${installed_mc:-?} -> ${rec_paper} (jar: $(basename "$server_jar"))"
    else
      warn "Can't identify the Paper jar to replace; pass --server-jar <name>. Skipping the Paper ${paper_action}."
      paper_action="none"
      if [ "${#worklist[@]}" -eq 0 ]; then log "Nothing else to do."; log "=== no action taken ==="; return 0; fi
    fi
  fi

  # --- dry run stops here, with the full plan known ---
  if [ "$DRY_RUN" = 1 ]; then
    local nl=""
    for n in "${worklist[@]}"; do [ "${NEED[$n]}" = 1 ] && nl+="${NAMES[$n]} "; done
    [ -n "$nl" ] && log "[dry-run] would install/update: $nl"
    for n in "${worklist[@]}"; do
      [ -n "${DUPS[$n]}" ] && while IFS= read -r d; do
        [ -n "$d" ] && log "[dry-run] would remove duplicate: $(basename "$d")"
      done <<< "${DUPS[$n]}"
    done
    [ "$paper_action" != "none" ] && log "[dry-run] would ${paper_action} Paper to ${rec_paper} (build ${paper_build})"
    log "=== dry-run complete ==="
    return 0
  fi

  # --- apply plugin changes ---
  if [ "${#worklist[@]}" -gt 0 ]; then
    log "applying plugin changes ..."
    for n in "${worklist[@]}"; do
      if [ "${NEED[$n]}" = 1 ]; then
        local tmp="${TMP_DIR}/$(basename "${DESTS[$n]}")"
        fetch_verify "${URLS[$n]}" "${SHAS[$n]}" "${HALGO[$n]}" "$tmp"
        backup_file "${DESTS[$n]}" "${PLUGINS_DIR}/_backups"
        mv "$tmp" "${DESTS[$n]}"; chmod 644 "${DESTS[$n]}"
        log "  installed ${NAMES[$n]} ${VERS[$n]}"
      fi
      if [ -n "${DUPS[$n]}" ]; then
        while IFS= read -r d; do
          [ -n "$d" ] && [ -f "$d" ] || continue
          backup_file "$d" "${PLUGINS_DIR}/_backups"
          rm -f "$d"
          log "  removed duplicate $(basename "$d") (same plugin as $(basename "${DESTS[$n]}"))"
        done <<< "${DUPS[$n]}"
      fi
    done
    prune_backups "${PLUGINS_DIR}/_backups" "$KEEP_BACKUPS"
  fi

  # --- apply the Paper change (in place, same filename) ---
  if [ "$paper_action" != "none" ]; then
    log "downloading Paper ${rec_paper} (build ${paper_build}) ..."
    fetch_verify "$paper_url" "$paper_sha" "sha256" "${TMP_DIR}/paper.jar"
    backup_file "$server_jar" "${SERVER_DIR}/_paper_backups"
    mv "${TMP_DIR}/paper.jar" "$server_jar"; chmod 644 "$server_jar"
    prune_backups "${SERVER_DIR}/_paper_backups" "$KEEP_BACKUPS"
    log "  Paper ${paper_action} complete -> $(basename "$server_jar") is now ${rec_paper} (build ${paper_build})"
  fi

  log "Done. Restart the server to load the changes."
  log "=== update complete ==="
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
