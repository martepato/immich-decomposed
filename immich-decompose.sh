#!/usr/bin/env bash
# =============================================================================
# immich-decompose.sh - install and upgrade Immich on Debian 13 (trixie) without Docker
#
# It rebuilds what the official Docker images contain, from the same sources and
# pinned versions:
#
#   ghcr.io/immich-app/immich-server            -> /opt/immich/current/{server,cli,build}
#     (base-server-prod: libvips, ImageMagick,     native libs built into /usr/local,
#      libheif, libjxl, libraw, jpegli, ffmpeg)    jellyfin-ffmpeg from its .deb
#   ghcr.io/immich-app/immich-machine-learning  -> /opt/immich/current/ml (uv venv)
#   ghcr.io/immich-app/postgres                 -> PostgreSQL (PGDG) + pgvector + VectorChord
#   valkey                                      -> Debian valkey-server
#   docker-compose.yml + .env                   -> systemd units + /etc/immich/*.env
#
# Usage:
#   ./immich-decompose.sh [install|upgrade] [VERSION]   install, or upgrade to VERSION (default: latest)
#   ./immich-decompose.sh status
#
# Settings are read from the environment, e.g.:
#   UPLOAD_LOCATION=/mnt/photos ./immich-decompose.sh install v3.3.5
# See the "Settings" block below for all of them.
# =============================================================================
set -Eeuo pipefail
umask 022

# ----------------------------------------------------------------- Settings --
: "${IMMICH_VERSION:=latest}"                  # git tag (e.g. v3.3.5) or "latest"; also the 2nd argument

# Locations and user
: "${IMMICH_HOME:=/var/lib/immich}"            # home of the immich user
: "${UPLOAD_LOCATION:=$IMMICH_HOME/library}"   # same meaning as UPLOAD_LOCATION in .env (mounted at /data in Docker)
: "${ML_CACHE_LOCATION:=$IMMICH_HOME/model-cache}"  # the "model-cache" volume
: "${IMMICH_ROOT:=/opt/immich}"                # releases/ and current -> releases/<ver>
: "${CONFIG_DIR:=/etc/immich}"                 # immich.env and ml.env
: "${IMMICH_USER:=immich}"
: "${IMMICH_UID:=}"                            # fixed uid/gid for the immich user (e.g. to match mounted storage)
: "${IMMICH_GID:=}"

# Database
: "${PG_MAJOR:=17}"                            # 14-18 are supported by Immich
: "${DB_DATA_LOCATION:=}"                      # empty = Debian default (/var/lib/postgresql/<ver>/main); first install only
: "${DB_STORAGE_TYPE:=SSD}"                    # SSD or HDD, picks the same postgres tuning as the image
: "${DB_USERNAME:=immich}"
: "${DB_DATABASE_NAME:=immich}"

# Machine learning and hardware
: "${INSTALL_ML:=1}"                           # 0 = skip machine learning (e.g. you run it on another box)
: "${ML_DEVICE:=cpu}"                          # uv extra: cpu (tested), openvino/cuda/rocm/armnn/rknn (see README)
: "${INTEL_OPENCL:=auto}"                      # Intel OpenCL runtime for HW tone-mapping (auto = on for amd64)

# Build and upgrades
: "${BUILD_JOBS:=$(nproc)}"                    # lower this if the build runs out of memory
: "${BUILD_CACHE:=/var/cache/immich-build}"    # sources, pnpm/uv caches, build tools
: "${CLEAN_BUILD_CACHE:=0}"                    # 1 = delete $BUILD_CACHE after a successful run
: "${KEEP_RELEASES:=2}"                        # how many built releases to keep in $IMMICH_ROOT/releases
: "${FORCE_REBUILD:=0}"                        # 1 = rebuild native libs and the release even if up to date
: "${BASE_IMAGES_REF:=}"                       # override the immich-app/base-images commit (normally auto-detected)

# Output
: "${PLAIN:=0}"                                # 1 = no status header, plain scrolling output
: "${LOG_FILE:=/var/log/immich-decompose.log}" # every run is appended here

IMMICH_REPO=https://github.com/immich-app/immich
BASE_IMAGES_REPO=https://github.com/immich-app/base-images
STATE_DIR=/usr/local/share/immich-decompose         # stamps for what has been built into /usr/local
export DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------------ Helpers --
if [[ -t 1 ]]; then
  c_blue=$'\033[1;34m'; c_yel=$'\033[1;33m'; c_red=$'\033[1;31m'; c_grn=$'\033[1;32m'; c_off=$'\033[0m'
else
  c_blue='' c_yel='' c_red='' c_grn='' c_off=''
fi
log()  { printf '\n%s==> %s%s\n' "$c_blue" "$*" "$c_off"; ui_send DETAIL "$*"; }
info() { printf '    %s\n' "$*"; ui_send DETAIL "$*"; }
warn() { printf '%sWARNING:%s %s\n' "$c_yel" "$c_off" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }
# shellcheck disable=SC2154
trap 'rc=$?; printf "%sFAILED%s (exit %s) at line %s: %s\n" "$c_red" "$c_off" "$rc" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ------------------------------------------------------------ Status header --
# On a terminal, the top lines of the screen show a fixed header (version, current step,
# progress, elapsed time) while command output scrolls underneath. One writer process
# owns the terminal, so output and header redraws never interleave. Everything is also
# appended to $LOG_FILE. Without a terminal, or with PLAIN=1, output is plain.
UI=0 UI_PID='' UI_FD='' UI_ORIG_OUT='' UI_ORIG_ERR='' STEP_N=0 STEP_TOTAL=0 STEP_TITLE=''
UI_M=$'\x1e' UI_F=$'\x1f'      # message prefix and field separator for the writer

# ui_send TYPE [FIELDS...]: update the header (no-op without the writer)
ui_send() {
  [[ $UI == 1 ]] || return 0
  local IFS=$UI_F
  printf '%s%s\n' "$UI_M" "$*" >&"$UI_FD"
}

# Runs in a process substitution: stdin is the script's output, stdout the terminal.
ui_writer() {
  set +eEu; trap - ERR EXIT; trap '' INT TERM HUP
  shopt -s extglob
  local tui=$1 log=$2 hdr=4 rows=0 cols=0 resized=0 hidden=0
  local -a buf=()        # recent output lines, reprinted after a resize
  local pending=''       # current unfinished output line
  local ver='' title='Starting' detail='' state=run n=0 total=0
  local t0=$SECONDS ts=$SECONDS last=-1 line rc f
  exec 3>>"$log"

  _size() {
    local sz; sz=$(stty size </dev/tty 2>/dev/null) || return 1
    rows=${sz% *}; cols=${sz#* }
    (( rows >= 12 && cols >= 50 ))
  }
  _clock() {
    local t=$1
    if (( t >= 3600 )); then printf '%d:%02d:%02d' $((t/3600)) $((t%3600/60)) $((t%60))
    else printf '%02d:%02d' $((t/60)) $((t%60)); fi
  }
  # _row ROW COLOR LEFT RIGHT: one header line, left text truncated so RIGHT stays visible
  _row() {
    local room=$(( cols - ${#4} - 2 )) left=$3
    (( ${#left} > room )) && left="${left:0:room-1}~"
    printf '\e[%d;1H\e[2K%s%-*s %s\e[0m' "$1" "$2" "$room" "$left" "$4"
  }
  _draw() {
    (( tui && !hidden )) || return 0
    local now=$SECONDS w=24 fill bar sl=''
    fill=$(( total > 0 ? n * w / total : 0 ))
    [[ $state == 'done' ]] && fill=$w
    printf -v bar '%*s' "$fill" ''; bar=${bar// /#}
    printf -v sl '%*s' $(( w - fill )) ''; bar="[$bar${sl// /.}]"
    printf '\e7'
    _row 1 $'\e[1m' " immich-decompose${ver:+  -  Immich $ver}" "total $(_clock $((now - t0)))"
    case $state in
      run)  _row 2 $'\e[1;34m' " $bar $n/$total  $title" "step $(_clock $((now - ts)))" ;;
      'done') _row 2 $'\e[1;32m' " $bar  $title" "" ;;
      fail) _row 2 $'\e[1;31m' " FAILED in step $n/$total: $title" "" ;;
      stop) _row 2 $'\e[1;33m' " STOPPED in step $n/$total: $title" "" ;;
    esac
    _row 3 $'\e[2m' "   ${detail}" ""
    local rule; printf -v rule '%*s' "$cols" ''; rule=${rule// /-}
    local tag=" log: $log "
    printf '\e[%d;1H\e[2K\e[2m%s%s%s\e[0m' 4 "${rule:0:3}" "$tag" "${rule:0:cols-3-${#tag}}"
    printf '\e8'
    last=$now
  }
  _region() {   # keep the header out of the scrolling area
    printf '\e[%d;%dr\e[%d;1H' $((hdr + 1)) "$rows" "$rows"
  }
  _out() {      # _out TEXT [nl]: print to the scrolling area and the log
    if [[ ${2:-} == nl ]]; then
      printf '%s\n' "$1"; printf '%s\n' "${1//$'\e'\[*([0-9;])m/}" >&3
      buf+=("$pending$1"); pending=''
      (( ${#buf[@]} > 600 )) && buf=("${buf[@]:100}")
    else
      printf '%s' "$1"; printf '%s' "${1//$'\e'\[*([0-9;])m/}" >&3
      pending+=$1
    fi
  }
  # After a resize the terminal may have reflowed or pulled scrollback onto the screen,
  # leaving stale header copies around. Start from a clean screen instead: clear it,
  # set up the region again and reprint the latest output under a fresh header.
  _repaint() {
    printf '\e[r\e[H\e[2J'
    if ! _size; then hidden=1; printf '\e[%d;1H' "${rows:-1}"; return; fi   # too small: plain scrolling
    hidden=0
    _region
    local i start=$(( ${#buf[@]} - (rows - hdr - 1) ))
    (( start < 0 )) && start=0
    for (( i = start; i < ${#buf[@]}; i++ )); do printf '%s\n' "${buf[i]}"; done
    printf '%s' "$pending"
    _draw
  }
  _msg() {      # header message from ui_send
    local -a m; IFS=$UI_F read -r -a m <<<"${1#"$UI_M"}"
    case ${m[0]} in
      VER)    ver=${m[1]} ;;
      STEP)   n=${m[1]}; total=${m[2]}; title=${m[3]}; detail=''; ts=$SECONDS ;;
      DETAIL) detail=${m[1]} ;;
      DONE)   state='done'; title=${m[1]}; detail=${m[2]:-} ;;
      FAIL)   state=fail; n=${m[1]}; total=${m[2]}; title=${m[3]}
              if (( m[4] >= 129 && m[4] <= 143 )); then state=stop; detail="stopped by a signal (exit code ${m[4]}); re-run to continue"
              else detail="exit code ${m[4]}, see the output above and $log"; fi ;;
    esac
    _draw
  }

  if (( tui )) && _size; then
    trap 'resized=1' WINCH
    printf '%*s' "$rows" '' | tr ' ' '\n'   # push what is on screen into scrollback
    printf '\e[H'; _region; _draw
  else
    tui=0
  fi

  while :; do
    if IFS= read -r -t 1 line; then
      if [[ $line == "$UI_M"* ]]; then _msg "$line"; else _out "$line" nl; fi
    else
      rc=$?
      [[ -n $line && $line != "$UI_M"* ]] && _out "$line"   # partial line (timeout) or last line (EOF)
      (( rc > 128 )) || break                                  # EOF
    fi
    if (( resized )); then
      # wait until the window stops changing size (dragging sends many signals)
      while (( resized )); do resized=0; sleep 0.2; done
      _repaint
    fi
    (( tui && SECONDS != last )) && _draw
  done

  if (( tui && !hidden )); then   # give the terminal back: full-screen scrolling
    _draw
    printf '\e7\e[r\e8'   # resetting the region homes the cursor, so restore it after
  fi
  exec 3>&-
}

ui_start() {
  mkdir -p "$(dirname "$LOG_FILE")"
  printf '\n===== %s  immich-decompose %s =====\n' "$(date -Is)" "$*" >> "$LOG_FILE"
  local tui=0
  [[ -t 1 && $PLAIN != 1 && ${TERM:-dumb} != dumb ]] && tui=1
  exec {UI_ORIG_OUT}>&1 {UI_ORIG_ERR}>&2
  exec > >(ui_writer "$tui" "$LOG_FILE") 2>&1
  UI_PID=$!
  exec {UI_FD}>&1
  UI=1
  trap ui_stop EXIT
  # bash would run the EXIT trap with status 0 after a signal; make the status explicit
  trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
}

ui_stop() {
  local rc=$?
  [[ $UI == 1 ]] || return 0
  if (( rc == 0 )); then
    local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    ui_send DONE "Immich $IMMICH_VERSION is running" "web UI: http://${ip:-<host>}:2283"
  else
    ui_send FAIL "$STEP_N" "$STEP_TOTAL" "$STEP_TITLE" "$rc"
  fi
  UI=0
  # closing our ends of the pipe lets the writer finish and restore the terminal
  exec >&"$UI_ORIG_OUT" 2>&"$UI_ORIG_ERR" {UI_FD}>&-
  local _i; for _i in {1..50}; do kill -0 "$UI_PID" 2>/dev/null || return 0; sleep 0.1; done
  kill "$UI_PID" 2>/dev/null; printf '\e[r' >&"$UI_ORIG_OUT"
}

# env_get KEY FILE: last value of KEY in an env file, quotes stripped (empty if unset)
env_get() { { grep -oP "^$1=\K.*" "$2" 2>/dev/null || true; } | tail -n1 | tr -d "\"'"; }

apt_install() { apt-get install -y --no-install-recommends -o Dpkg::Options::=--force-confold "$@"; }

# fetch URL DEST [SHA256]
fetch() {
  local url=$1 dest=$2 sum=${3:-}
  curl -fL --retry 4 --retry-delay 2 --connect-timeout 30 -sS -o "$dest.part" "$url"
  if [[ -n $sum ]]; then
    echo "$sum  $dest.part" | sha256sum -c --quiet - || die "checksum mismatch for $url"
  fi
  mv "$dest.part" "$dest"
}

# shallow clone of one tag/branch/commit into a fresh directory
git_checkout() {
  local repo=$1 ref=$2 dir=$3
  rm -rf "$dir"; mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "$repo"
  git -C "$dir" -c protocol.version=2 fetch -q --depth 1 origin "$ref"
  git -C "$dir" checkout -q FETCH_HEAD
}

# dpkg arch -> naming used by the various upstream release assets
case "$(dpkg --print-architecture 2>/dev/null || echo unknown)" in
  amd64) ARCH=amd64; NODE_ARCH=x64;   UV_ARCH=x86_64;  MISE_PLATFORM=linux-x64 ;;
  arm64) ARCH=arm64; NODE_ARCH=arm64; UV_ARCH=aarch64; MISE_PLATFORM=linux-arm64 ;;
  *) ARCH=unsupported ;;
esac
LIBDIR_ARCH=$(uname -m)-linux-gnu

# --------------------------------------------------------------- Preflight --
preflight() {
  log "Checking the system"
  [[ $ARCH != unsupported ]] || die "only amd64 and arm64 are supported"
  # shellcheck source=/dev/null
  . /etc/os-release
  if [[ ${ID:-} != debian || ${VERSION_CODENAME:-} != trixie ]]; then
    [[ ${FORCE_OS:-0} == 1 ]] || die "this script targets Debian 13 (trixie), found ${PRETTY_NAME:-unknown}. Set FORCE_OS=1 to try anyway."
    warn "unsupported OS ${PRETTY_NAME:-}, continuing because FORCE_OS=1"
  fi
  [[ -d /run/systemd/system ]] || die "systemd is not running as init"
  [[ $UPLOAD_LOCATION == /* && $ML_CACHE_LOCATION == /* ]] || die "UPLOAD_LOCATION and ML_CACHE_LOCATION must be absolute paths"
  case "${DB_STORAGE_TYPE^^}" in SSD|HDD) ;; *) die "DB_STORAGE_TYPE must be SSD or HDD" ;; esac

  info "virtualization: $(systemd-detect-virt 2>/dev/null || echo none)"
  local mem_kb swap_kb
  mem_kb=$(awk '/^MemTotal/{print $2}' /proc/meminfo); swap_kb=$(awk '/^SwapTotal/{print $2}' /proc/meminfo)
  info "memory: $((mem_kb / 1024)) MiB RAM, $((swap_kb / 1024)) MiB swap, build jobs: $BUILD_JOBS"
  (( mem_kb + swap_kb >= 3800000 )) || warn "less than 4 GiB RAM+swap: the web/native builds may fail. Add swap or set BUILD_JOBS=1."
  mkdir -p "$IMMICH_ROOT" "$BUILD_CACHE"
  local free_kb; free_kb=$(df -Pk "$BUILD_CACHE" | awk 'NR==2{print $4}')
  (( free_kb >= 15000000 )) || warn "less than 15 GiB free on $BUILD_CACHE; a full build needs about that much"
}

# ------------------------------------------------------------- Resolve tag --
resolve_version() {
  if [[ $IMMICH_VERSION == latest ]]; then
    IMMICH_VERSION=$(git ls-remote --tags --refs "$IMMICH_REPO" 'v*' | awk -F/ '{print $3}' \
      | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1)
    [[ -n $IMMICH_VERSION ]] || die "could not determine the latest Immich release"
  fi
  [[ $IMMICH_VERSION == v* ]] || IMMICH_VERSION="v$IMMICH_VERSION"
  log "Immich version: $IMMICH_VERSION"
  ui_send VER "$IMMICH_VERSION"
}

# ------------------------------------------------------------ APT packages --
setup_apt() {
  log "Configuring APT (Debian testing pinned low, PostgreSQL PGDG repo)"
  apt-get update -qq
  apt_install ca-certificates curl wget gnupg git jq python3 xz-utils unzip

  # The image takes libde265 from testing (v1.0.16 has an HDR fix). Pin testing to 100 so
  # nothing else is ever pulled from it unless explicitly asked for with pkg/testing.
  cat > /etc/apt/sources.list.d/immich-debian-testing.sources <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: testing
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
  cat > /etc/apt/preferences.d/immich-debian-testing <<'EOF'
Package: *
Pin: release a=testing
Pin-Priority: 100
EOF

  install -d /usr/share/postgresql-common/pgdg
  fetch https://www.postgresql.org/media/keys/ACCC4CF8.asc /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt trixie-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list
  apt-get update -qq
}

install_packages() {
  log "Installing build and runtime packages"
  # Union of base-server-dev (build) and base-server-prod (runtime) package lists.
  apt_install \
    build-essential autoconf automake libtool libltdl-dev cmake meson ninja-build pkg-config make patch \
    libbrotli-dev libexif-dev libexpat1-dev libglib2.0-dev libgsf-1-dev libjpeg62-turbo-dev \
    liblcms2-dev libopenjp2-7-dev librsvg2-dev libspng-dev libdav1d-dev libhwy-dev libwebp-dev libaom-dev \
    libexif12 libexpat1 libgcc-s1 libglib2.0-0 libgomp1 libgsf-1-114 liblcms2-2 liblqr-1-0 libltdl7 \
    libopenexr-3-1-30 libopenjp2-7 librsvg2-2 libspng0 zlib1g libwebp7 libwebpdemux2 libwebpmux3 \
    libhwy1t64 libaom3 libmimalloc3 ocl-icd-libopencl1 libio-compress-brotli-perl perl \
    libopenmpt0 libbluray2 libvpx9 libzvbi0 libmp3lame0 libopus0 libtheora0 libvorbis0a libvorbisenc2 libx264-164 \
    tini procps
  apt_install libde265-dev/testing libde265-0/testing
}

# ------------------------------------------------- Locate pinned upstreams --
# Fetch the Immich release and the base-images commit its server image was built from.
fetch_sources() {
  log "Fetching Immich $IMMICH_VERSION source"
  SRC=$BUILD_CACHE/src/immich-$IMMICH_VERSION
  git_checkout "$IMMICH_REPO" "refs/tags/$IMMICH_VERSION" "$SRC"
  IMMICH_COMMIT=$(git -C "$SRC" rev-parse HEAD)
  info "commit $IMMICH_COMMIT"

  if [[ -z $BASE_IMAGES_REF ]]; then
    # server/Dockerfile: FROM ghcr.io/immich-app/base-server-prod:<tag>@sha256:...
    local tag token
    tag=$(grep -oP '^FROM ghcr\.io/immich-app/base-server-prod:\K[^@ ]+' "$SRC/server/Dockerfile" | head -n1)
    [[ -n $tag ]] || die "cannot find the base-server-prod tag in server/Dockerfile"
    info "server image uses base-server-prod:$tag"
    token=$(curl -fsS "https://ghcr.io/token?scope=repository:immich-app/base-server-prod:pull" | jq -r .token) || token=
    if [[ -n $token ]]; then
      BASE_IMAGES_REF=$(curl -fsS -H "Authorization: Bearer $token" \
        -H 'Accept: application/vnd.oci.image.index.v1+json' \
        "https://ghcr.io/v2/immich-app/base-server-prod/manifests/$tag" \
        | jq -r '.annotations["org.opencontainers.image.revision"] // empty') || BASE_IMAGES_REF=
    fi
    if [[ -z $BASE_IMAGES_REF ]]; then
      warn "could not read the base image revision from ghcr.io, using base-images main"
      BASE_IMAGES_REF=main
    fi
  fi
  BASE_SRC=$BUILD_CACHE/src/base-images
  git_checkout "$BASE_IMAGES_REPO" "$BASE_IMAGES_REF" "$BASE_SRC"
  BASE_IMAGES_REF=$(git -C "$BASE_SRC" rev-parse HEAD)
  info "base-images commit $BASE_IMAGES_REF"
}

# ---------------------------------------------------------------- Node.js --
install_node() {
  local want have
  want=$(grep -m1 -oP '^FROM node:\K[0-9.]+' "$BASE_SRC/server/Dockerfile")
  have=$(node --version 2>/dev/null || true)
  if [[ $have == "v$want" ]]; then
    info "Node.js v$want already installed"
  else
    log "Installing Node.js v$want (was: ${have:-none})"
    local d=$BUILD_CACHE/dl name="node-v$want-linux-$NODE_ARCH.tar.xz" sum
    mkdir -p "$d"
    fetch "https://nodejs.org/dist/v$want/SHASUMS256.txt" "$d/node-SHASUMS256.txt"
    sum=$(awk -v n="$name" '$2==n{print $1}' "$d/node-SHASUMS256.txt")
    fetch "https://nodejs.org/dist/v$want/$name" "$d/$name" "$sum"
    rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack
    tar -xJf "$d/$name" -C /usr/local --strip-components=1 --no-same-owner \
      --exclude='*/CHANGELOG.md' --exclude='*/LICENSE' --exclude='*/README.md'
    hash -r
  fi
  # same as the server Dockerfile
  export COREPACK_ENABLE_DOWNLOAD_PROMPT=0 COREPACK_HOME=$BUILD_CACHE/corepack
  npm install --global --silent corepack@latest
  corepack enable pnpm
}

# ------------------------------------------- Native libs (base-server image) --
build_base_libs() {
  local stamp=$STATE_DIR/base-images.rev
  if [[ $FORCE_REBUILD != 1 && -f $stamp && $(cat "$stamp") == "$BASE_IMAGES_REF" ]]; then
    info "native libraries already built from base-images $BASE_IMAGES_REF"
    return
  fi
  log "Building native image libraries from base-images ${BASE_IMAGES_REF:0:12} (this takes a while)"
  local s=$BASE_SRC/server/sources work=$BUILD_CACHE/work/base lib

  # Same environment as the base image; LD_RUN_PATH embeds /usr/local/lib as RUNPATH so
  # libvips/ImageMagick load jpegli's libjpeg.so.62 instead of Debian's libjpeg-turbo.
  export LD_LIBRARY_PATH=/usr/local/lib LD_RUN_PATH=/usr/local/lib
  # The upstream scripts use $(nproc) for parallelism; honour BUILD_JOBS.
  mkdir -p "$BUILD_CACHE/bin"
  printf '#!/bin/sh\necho %s\n' "$BUILD_JOBS" > "$BUILD_CACHE/bin/nproc"; chmod +x "$BUILD_CACHE/bin/nproc"

  # Docker builds jpegli/libheif/libjxl/libraw independently, then ImageMagick and libvips on
  # top of all of them. On one host that means: independent libs, then jpegli, then the rest.
  local order=(libheif libjxl libraw jpegli imagemagick libvips) extra=()
  for f in "$s"/*.sh; do
    lib=$(basename "$f" .sh)
    [[ " ${order[*]} " == *" $lib "* ]] || extra+=("$lib")
  done
  if ((${#extra[@]})); then
    warn "base-images has libraries this script does not know about (${extra[*]}); building them before jpegli"
    order=(libheif libjxl libraw "${extra[@]}" jpegli imagemagick libvips)
  fi

  for lib in "${order[@]}"; do
    [[ -f $s/$lib.sh ]] || { warn "base-images has no $lib.sh, skipping"; continue; }
    info "building $lib $(jq -r '.version // .revision[0:12]' "$s/$lib.json")"
    rm -rf "${work:?}/$lib"; mkdir -p "$work/$lib"
    cp "$s/$lib.json" "$s/$lib.sh" "$work/$lib/"
    [[ -d $s/$lib-patches ]] && cp -r "$s/$lib-patches" "$work/$lib/"
    ( cd "$work/$lib" && PATH="$BUILD_CACHE/bin:$PATH" ./"$lib.sh" ) > "$work/$lib.log" 2>&1 \
      || { tail -n 40 "$work/$lib.log" >&2; die "building $lib failed, full log: $work/$lib.log"; }
    if [[ $lib == jpegli ]]; then
      # The image only takes libjpeg.so* and the headers from jpegli; drop its pkg-config file
      # so later builds keep resolving libjpeg through Debian's libjpeg62-turbo-dev, as in Docker.
      rm -f /usr/local/lib/pkgconfig/libjpeg.pc
    fi
  done
  ldconfig /usr/local/lib

  install -D -m644 "$BASE_SRC/server/policy.xml" /etc/ImageMagick/policy.xml
  mkdir -p "$STATE_DIR"; echo "$BASE_IMAGES_REF" > "$stamp"
  rm -rf "$work"
  unset LD_LIBRARY_PATH LD_RUN_PATH
}

install_ffmpeg() {
  local p=$BASE_SRC/server/packages want have
  want=$(jq -r .version "$p/ffmpeg.json")
  have=$(dpkg-query -W -f='${Version}' jellyfin-ffmpeg7 2>/dev/null || true)
  if [[ $FORCE_REBUILD != 1 && $have == "$want"-* ]]; then
    info "jellyfin-ffmpeg $have already installed"
  else
    log "Installing jellyfin-ffmpeg $want"
    local work=$BUILD_CACHE/work/ffmpeg
    rm -rf "$work"; mkdir -p "$work"; cp "$p/ffmpeg.json" "$p/ffmpeg.sh" "$work/"
    rm -f /usr/bin/ffmpeg /usr/bin/ffprobe      # ffmpeg.sh creates these symlinks
    ( cd "$work" && TARGETARCH=$ARCH ./ffmpeg.sh )
    rm -rf "$work"
  fi
}

install_intel_opencl() {
  [[ $INTEL_OPENCL == auto ]] && { [[ $ARCH == amd64 ]] && INTEL_OPENCL=1 || INTEL_OPENCL=0; }
  [[ $INTEL_OPENCL == 1 && $ARCH == amd64 ]] || return 0
  local df=$BASE_SRC/server/Dockerfile igc cr gmm stamp=$STATE_DIR/intel-opencl.ver
  igc=$(grep -oP '^ARG IGC_VERSION=\K\S+' "$df"); cr=$(grep -oP '^ARG COMPUTE_RUNTIME_VERSION=\K\S+' "$df")
  gmm=$(grep -oP '^ARG GMMLIB_VERSION=\K\S+' "$df")
  [[ -n $igc && -n $cr && -n $gmm ]] || { warn "could not read Intel driver versions from base-images, skipping"; return 0; }
  if [[ $FORCE_REBUILD != 1 && -f $stamp && $(cat "$stamp") == "$igc $cr $gmm" ]]; then
    info "Intel OpenCL runtime already installed"; return 0
  fi
  log "Installing Intel OpenCL runtime (IGC $igc, compute-runtime $cr)"
  local d=$BUILD_CACHE/work/intel igc_tag=${igc%%+*} cr_tag=${cr%-*}
  rm -rf "$d"; mkdir -p "$d"
  local urls=(
    # legacy driver for older GPUs, as in the image
    https://github.com/intel/intel-graphics-compiler/releases/download/igc-1.0.17537.24/intel-igc-core_1.0.17537.24_amd64.deb
    https://github.com/intel/intel-graphics-compiler/releases/download/igc-1.0.17537.24/intel-igc-opencl_1.0.17537.24_amd64.deb
    https://github.com/intel/compute-runtime/releases/download/24.35.30872.36/intel-opencl-icd-legacy1_24.35.30872.36_amd64.deb
    "https://github.com/intel/intel-graphics-compiler/releases/download/v${igc_tag}/intel-igc-core-2_${igc}_amd64.deb"
    "https://github.com/intel/intel-graphics-compiler/releases/download/v${igc_tag}/intel-igc-opencl-2_${igc}_amd64.deb"
    "https://github.com/intel/compute-runtime/releases/download/${cr_tag}/intel-opencl-icd_${cr}_amd64.deb"
    "https://github.com/intel/compute-runtime/releases/download/${cr_tag}/libigdgmm12_${gmm}_amd64.deb"
  )
  local u; for u in "${urls[@]}"; do fetch "$u" "$d/$(basename "$u")"; done
  dpkg -i "$d"/*.deb || apt-get -f install -y
  [[ -e /usr/local/lib/libopencl-clang.so.14 ]] && ln -sf libopencl-clang.so.14 /usr/local/lib/libopencl-clang.so
  ldconfig
  mkdir -p "$STATE_DIR"; echo "$igc $cr $gmm" > "$stamp"
  rm -rf "$d"
}

# ------------------------------------------------- PostgreSQL + VectorChord --
install_postgres() {
  log "Setting up PostgreSQL $PG_MAJOR with pgvector and VectorChord"
  apt_install postgresql-common
  if [[ ! -d /etc/postgresql/$PG_MAJOR/main ]]; then
    # Like POSTGRES_INITDB_ARGS=--data-checksums in docker-compose.yml
    mkdir -p /etc/postgresql-common/createcluster.d
    {
      echo "initdb_options = '--data-checksums'"
      [[ -n $DB_DATA_LOCATION ]] && echo "data_directory = '$DB_DATA_LOCATION'"
    } > /etc/postgresql-common/createcluster.d/immich.conf
  fi
  apt_install "postgresql-$PG_MAJOR" "postgresql-$PG_MAJOR-pgvector"
  [[ -d /etc/postgresql/$PG_MAJOR/main ]] || pg_createcluster "$PG_MAJOR" main

  # VectorChord: same version as the immich-app/postgres image
  local vchord have
  vchord=$(awk '/^vectorchord:/{f=1;next} f&&/^ *-/{gsub(/[" -]/,"");print;exit}' "$BASE_SRC/postgres/versions.yaml")
  [[ -n $vchord ]] || die "cannot read the VectorChord version from base-images"
  have=$(dpkg-query -W -f='${Version}' "postgresql-$PG_MAJOR-vchord" 2>/dev/null || true)
  local restart=0
  if [[ $have != "$vchord"-* ]]; then
    info "installing VectorChord $vchord"
    restart=1
    local deb=$BUILD_CACHE/dl/postgresql-$PG_MAJOR-vchord_${vchord}-1_$ARCH.deb
    mkdir -p "$BUILD_CACHE/dl"
    fetch "https://github.com/tensorchord/VectorChord/releases/download/$vchord/$(basename "$deb")" "$deb"
    apt_install "$deb"
  fi

  # Same settings the image puts in /etc/postgresql/postgresql.conf
  local tpl=$BASE_SRC/postgres/postgresql.${DB_STORAGE_TYPE,,}.conf conf=/etc/postgresql/$PG_MAJOR/main/conf.d/immich.conf
  local old_conf; old_conf=$(cat "$conf" 2>/dev/null || true)
  {
    echo "# Generated by immich-decompose.sh from immich-app/base-images postgres/$(basename "$tpl")."
    echo "# Put your own overrides in a later file, e.g. conf.d/zz-local.conf"
    grep -v '^include' "$tpl" | sed '/^$/N;/^\n$/D'
  } > "$conf"
  [[ $(cat "$conf") == "$old_conf" ]] || restart=1

  local datadir fstype
  datadir=$(pg_conftool -s "$PG_MAJOR" main show data_directory 2>/dev/null || echo "/var/lib/postgresql/$PG_MAJOR/main")
  fstype=$(stat -f -c %T "$datadir" 2>/dev/null || echo unknown)
  case "$fstype" in
    ext2/ext3|ext4|xfs|btrfs|zfs|f2fs|tmpfs|overlayfs) ;;
    *) warn "PostgreSQL data ($datadir) is on '$fstype'. Network shares will corrupt the database; use local storage." ;;
  esac

  systemctl enable -q postgresql
  if [[ $restart == 1 ]]; then
    systemctl restart "postgresql@$PG_MAJOR-main"
  else
    systemctl start "postgresql@$PG_MAJOR-main"
  fi
  for _ in $(seq 1 30); do pg_isready -q -h /var/run/postgresql -p "$(pg_port)" && break; sleep 1; done
  pg_isready -q -h /var/run/postgresql -p "$(pg_port)" || die "PostgreSQL did not start"

  # Immich expects a superuser, like POSTGRES_USER in the image (it creates/updates extensions
  # and pg_dumpall is used for the built-in database backups). It only listens on localhost.
  runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 -p "$(pg_port)" \
    -v user="$DB_USERNAME" -v pw="$DB_PASSWORD" -v db="$DB_DATABASE_NAME" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN SUPERUSER', :'user')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'user') \gexec
ALTER ROLE :"user" WITH LOGIN SUPERUSER PASSWORD :'pw';
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'user')
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db') \gexec
SQL
}
pg_port() { pg_conftool -s "$PG_MAJOR" main show port 2>/dev/null || echo 5432; }

install_valkey() {
  log "Setting up Valkey (Redis)"
  apt_install valkey-server
  systemctl enable -q --now valkey-server
}

# ------------------------------------------------ Build the Immich release --
build_release() {
  REL=$IMMICH_ROOT/releases/$IMMICH_VERSION
  if [[ $FORCE_REBUILD != 1 && -f $REL/.complete ]]; then
    info "release $IMMICH_VERSION already built in $REL"
    return
  fi
  if [[ -L $IMMICH_ROOT/current && $(readlink -f "$IMMICH_ROOT/current") == "$REL" ]]; then
    stop_services          # rebuilding the running release
  fi
  rm -rf "$REL"; mkdir -p "$REL/build"
  build_server
  build_plugins
  [[ $INSTALL_ML == 1 ]] && build_ml
  write_release_env
  cp "$SRC/LICENSE" "$REL/LICENSE"
  chmod -R go-w "$REL"
  touch "$REL/.complete"
}

pnpm_env() {
  export CI=1 COREPACK_ENABLE_DOWNLOAD_PROMPT=0 COREPACK_HOME=$BUILD_CACHE/corepack
  export LD_LIBRARY_PATH=/usr/local/lib LD_RUN_PATH=/usr/local/lib
  cd "$SRC"
  pnpm config set store-dir "$BUILD_CACHE/pnpm-store" >/dev/null
}

build_server() {
  log "Building server, web and CLI"
  pnpm_env
  info "building SDKs"
  pnpm --filter @immich/sdk install --frozen-lockfile
  pnpm --filter @immich/sdk build
  pnpm --filter @immich/plugin-sdk install --frozen-lockfile
  pnpm --filter @immich/plugin-sdk build

  info "building server"
  pnpm --filter immich install --frozen-lockfile
  pnpm --filter immich build
  pnpm --filter immich --prod --no-optional deploy "$REL/server"
  # build sharp against the libvips from build_base_libs, as the Dockerfile does
  SHARP_FORCE_GLOBAL_LIBVIPS=true pnpm --config.verify-deps-before-run=false \
    --dir "$REL/server/node_modules/sharp" exec npm run build

  info "building web UI"
  pnpm --filter immich-web install --frozen-lockfile
  pnpm --filter immich-web build
  cp -a "$SRC/web/build" "$REL/build/www"

  info "building CLI"
  pnpm --filter @immich/cli install --frozen-lockfile
  pnpm --filter @immich/cli build
  pnpm --filter @immich/cli --prod --no-optional deploy "$REL/cli"
  ln -sfn ../../cli/bin/immich "$REL/server/bin/immich"

  info "downloading geodata"
  # same files the base image ADDs to /build/geodata
  local geo=$REL/build/geodata url name
  mkdir -p "$geo"
  while read -r url name; do
    fetch "$url" "$geo/$name"
  done < <(grep -oP '^ADD (--chmod=\S+ )?\Khttps://\S+ /build/geodata/\S+' "$BASE_SRC/server/Dockerfile" \
             | sed 's# /build/geodata/# #')
  [[ -f $geo/cities500.zip ]] || die "geodata download list not found in base-images Dockerfile"
  unzip -q -o "$geo/cities500.zip" -d "$geo"; rm -f "$geo/cities500.zip"
  date --iso-8601=seconds | tr -d '\n' > "$geo/geodata-date.txt"
  chmod 444 "$geo"/*

  # /build/build-lock.json: versions of the native libraries, shown by the server
  jq -n --slurpfile sources <(jq -s . "$BASE_SRC"/server/sources/*.json) \
        --slurpfile packages <(jq -s . "$BASE_SRC"/server/packages/*.json) \
        '{sources: $sources[0], packages: $packages[0]}' > "$REL/build/build-lock.json"
  cd /
}

build_plugins() {
  log "Building core plugins (WebAssembly)"
  # The Dockerfile uses mise for extism-js + binaryen; fetch the exact same files from mise.lock.
  local tools=$BUILD_CACHE/tools tool ver url sum
  mkdir -p "$tools/bin"
  while read -r tool ver url sum; do
    case $tool in
      github:extism/js-pdk)
        if [[ ! -x $tools/extism-js-$ver ]]; then
          fetch "$url" "$tools/extism-js.gz" "$sum"
          gunzip -c "$tools/extism-js.gz" > "$tools/extism-js-$ver"; chmod +x "$tools/extism-js-$ver"; rm "$tools/extism-js.gz"
        fi
        ln -sfn "../extism-js-$ver" "$tools/bin/extism-js" ;;
      github:webassembly/binaryen)
        if [[ ! -d $tools/binaryen-$ver ]]; then
          fetch "$url" "$tools/binaryen.tar.gz" "$sum"
          mkdir -p "$tools/binaryen-$ver"; tar -xzf "$tools/binaryen.tar.gz" -C "$tools/binaryen-$ver" --strip-components=1
          rm "$tools/binaryen.tar.gz"
        fi
        local b; for b in "$tools/binaryen-$ver"/bin/*; do ln -sfn "$b" "$tools/bin/$(basename "$b")"; done ;;
    esac
  done < <(python3 - "$SRC/mise.lock" "$MISE_PLATFORM" <<'PY'
import sys, tomllib
lock = tomllib.load(open(sys.argv[1], "rb"))
for name in ("github:extism/js-pdk", "github:webassembly/binaryen"):
    entry = lock["tools"][name][0]
    plat = entry[f"platforms.{sys.argv[2]}"]
    print(name, entry["version"], plat["url"], plat["checksum"].split(":", 1)[1])
PY
)
  pnpm_env
  PATH="$tools/bin:$PATH" pnpm --filter @immich/sdk --filter @immich/plugin-sdk --filter @immich/plugin-core install --frozen-lockfile
  PATH="$tools/bin:$PATH" pnpm --filter @immich/sdk --filter @immich/plugin-sdk --filter @immich/plugin-core build
  local dst=$REL/build/plugins/immich-plugin-core
  mkdir -p "$dst"
  cp -a "$SRC/packages/plugin-core/dist" "$dst/dist"
  cp "$SRC/packages/plugin-core/manifest.json" "$dst/manifest.json"
  cd /
}

build_ml() {
  log "Building machine learning ($ML_DEVICE)"
  [[ $ML_DEVICE == cpu ]] || warn "ML_DEVICE=$ML_DEVICE: only the Python packages are installed; GPU drivers/runtimes are up to you (see README)"
  local uv_ver uv_dir
  uv_ver=$(grep -oP 'ghcr\.io/astral-sh/uv:\K[0-9.]+' "$SRC/machine-learning/Dockerfile" | head -n1)
  uv_dir=$BUILD_CACHE/tools/uv-$uv_ver
  if [[ ! -x $uv_dir/uv ]]; then
    local t="uv-$UV_ARCH-unknown-linux-gnu.tar.gz" sum
    mkdir -p "$uv_dir"
    fetch "https://github.com/astral-sh/uv/releases/download/$uv_ver/$t.sha256" "$uv_dir/$t.sha256"
    sum=$(awk '{print $1}' "$uv_dir/$t.sha256")
    fetch "https://github.com/astral-sh/uv/releases/download/$uv_ver/$t" "$uv_dir/$t" "$sum"
    tar -xzf "$uv_dir/$t" -C "$uv_dir" --strip-components=1; rm "$uv_dir/$t" "$uv_dir/$t.sha256"
  fi
  apt_install python3 python3-dev
  mkdir -p "$REL/ml"
  # Same flags as the machine-learning Dockerfile; Debian's python3.13 matches the image's Python.
  ( cd "$SRC/machine-learning" && \
    VIRTUAL_ENV=$REL/ml/venv UV_CACHE_DIR=$BUILD_CACHE/uv UV_PYTHON_DOWNLOADS=never UV_PYTHON=/usr/bin/python3 \
    PYTHONDONTWRITEBYTECODE=1 \
    "$uv_dir/uv" sync --frozen --extra "$ML_DEVICE" --no-dev --no-editable --no-install-project \
      --compile-bytecode --no-progress --active --link-mode copy )
  cp -a "$SRC/machine-learning/immich_ml" "$REL/ml/immich_ml"
  cp "$SRC/machine-learning/scripts/healthcheck.py" "$REL/ml/healthcheck.py"
}

# Environment baked into the images (Dockerfile ENV lines and compose "environment:").
# Regenerated per release; user settings live in $CONFIG_DIR and override these.
write_release_env() {
  local cur=$IMMICH_ROOT/current src_url="$IMMICH_REPO/commit/$IMMICH_COMMIT"
  cat > "$REL/server.env" <<EOF
# Generated by immich-decompose.sh for $IMMICH_VERSION - do not edit, use $CONFIG_DIR/immich.env
NODE_ENV=production
PATH=$cur/server/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
IMMICH_BUILD_DATA=$cur/build
IMMICH_REPOSITORY=immich-app/immich
IMMICH_REPOSITORY_URL=$IMMICH_REPO
IMMICH_SOURCE_REF=$IMMICH_VERSION
IMMICH_SOURCE_COMMIT=$IMMICH_COMMIT
IMMICH_SOURCE_URL=$src_url
XDG_DATA_DIRS=/usr/lib/jellyfin-ffmpeg/share:/usr/local/share:/usr/share
MAGICK_CONFIGURE_PATH=/etc/ImageMagick
EOF
  [[ $INSTALL_ML == 1 ]] || return 0
  local rev arena=false preload="/usr/lib/$LIBDIR_ARCH/libmimalloc.so.3"
  rev=$(grep -oP 'MACHINE_LEARNING_MODEL_REVISION:\s*\K\S+' "$SRC/docker/docker-compose.yml" || true)
  case $ML_DEVICE in openvino|rocm) preload= ;; esac   # the image skips mimalloc for these
  case $ML_DEVICE in openvino|rocm) arena=true ;; esac  # and only disables the arena for the others
  cat > "$REL/ml.env" <<EOF
# Generated by immich-decompose.sh for $IMMICH_VERSION - do not edit, use $CONFIG_DIR/ml.env
PATH=$cur/ml/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
VIRTUAL_ENV=$cur/ml/venv
PYTHONPATH=$cur/ml
PYTHONDONTWRITEBYTECODE=1
PYTHONUNBUFFERED=1
DEVICE=$ML_DEVICE
MACHINE_LEARNING_CACHE_FOLDER=$ML_CACHE_LOCATION
TRANSFORMERS_CACHE=$ML_CACHE_LOCATION
HF_HOME=$ML_CACHE_LOCATION/hf-cache
CUDA_CACHE_PATH=$ML_CACHE_LOCATION/jit/cuda
AMD_COMGR_CACHE_DIR=$ML_CACHE_LOCATION/jit/comgr
NEO_CACHE_DIR=$ML_CACHE_LOCATION/jit/neo
MACHINE_LEARNING_MODEL_ARENA=$arena
${rev:+MACHINE_LEARNING_MODEL_REVISION=$rev}
${preload:+LD_PRELOAD=$preload}
IMMICH_SOURCE_REF=$IMMICH_VERSION
EOF
}

# ---------------------------------------------- User, config, systemd units --
setup_user_and_config() {
  log "Creating user, directories and configuration"
  local env=$CONFIG_DIR/immich.env
  if [[ -f $env ]]; then
    # existing install: immich.env is the source of truth
    DB_PASSWORD=$(env_get DB_PASSWORD "$env")
    DB_USERNAME=$(env_get DB_USERNAME "$env"); DB_USERNAME=${DB_USERNAME:-immich}
    DB_DATABASE_NAME=$(env_get DB_DATABASE_NAME "$env"); DB_DATABASE_NAME=${DB_DATABASE_NAME:-immich}
    local media; media=$(env_get IMMICH_MEDIA_LOCATION "$env")
    UPLOAD_LOCATION=${media:-$UPLOAD_LOCATION}
  fi

  if ! getent group "$IMMICH_USER" >/dev/null; then
    groupadd --system ${IMMICH_GID:+--gid "$IMMICH_GID"} "$IMMICH_USER"
  fi
  if ! id "$IMMICH_USER" >/dev/null 2>&1; then
    useradd --system ${IMMICH_UID:+--uid "$IMMICH_UID"} --gid "$IMMICH_USER" --home-dir "$IMMICH_HOME" \
      --shell /usr/sbin/nologin "$IMMICH_USER"
  fi
  [[ -z $IMMICH_UID || $(id -u "$IMMICH_USER") == "$IMMICH_UID" ]] \
    || warn "user $IMMICH_USER already exists with uid $(id -u "$IMMICH_USER"), not $IMMICH_UID"
  local g; for g in video render; do getent group "$g" >/dev/null && usermod -aG "$g" "$IMMICH_USER"; done

  install -d -o "$IMMICH_USER" -g "$IMMICH_USER" -m 750 "$IMMICH_HOME"
  local d uid gid; uid=$(id -u "$IMMICH_USER"); gid=$(id -g "$IMMICH_USER")
  for d in "$UPLOAD_LOCATION" "$ML_CACHE_LOCATION"; do
    mkdir -p "$d"
    chown "$IMMICH_USER:$IMMICH_USER" "$d" 2>/dev/null || true
    if ! setpriv --reuid="$uid" --regid="$gid" --clear-groups -- test -w "$d"; then
      die "$d is not writable by $IMMICH_USER (uid $uid, gid $gid). Fix its ownership/permissions (for a host mount, mind the uid mapping) and re-run."
    fi
  done
  install -d -m 750 -g "$IMMICH_USER" "$CONFIG_DIR"

  [[ -n ${DB_PASSWORD:-} ]] || DB_PASSWORD=$(python3 -c 'import secrets, string; print("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(32)))')
  if [[ ! -f $env ]]; then
    cat > "$env" <<EOF
# Immich settings - the equivalent of the docker-compose .env file.
# All options: https://docs.immich.app/install/environment-variables
# Restart after changes: systemctl restart immich-server immich-machine-learning

# Where photos and videos are stored (UPLOAD_LOCATION in Docker, which mounts it at /data).
# Do not change this once you have uploaded files; see "immich-admin change-media-location".
IMMICH_MEDIA_LOCATION=$UPLOAD_LOCATION

# TZ=Etc/UTC

# Web/API listener (Docker publishes 2283)
# IMMICH_HOST=0.0.0.0
# IMMICH_PORT=2283

# Database (local PostgreSQL $PG_MAJOR, created by immich-decompose.sh)
DB_HOSTNAME=127.0.0.1
DB_PORT=$(pg_port 2>/dev/null || echo 5432)
DB_USERNAME=$DB_USERNAME
DB_PASSWORD=$DB_PASSWORD
DB_DATABASE_NAME=$DB_DATABASE_NAME

# Valkey/Redis
REDIS_HOSTNAME=127.0.0.1
REDIS_PORT=6379

# Machine learning service (immich-machine-learning in Docker)
IMMICH_MACHINE_LEARNING_URL=http://127.0.0.1:3003
EOF
  fi
  chmod 640 "$env"; chgrp "$IMMICH_USER" "$env"

  # The ML service reads IMMICH_HOST/IMMICH_PORT too. In Docker each container has its own
  # network namespace; here they share one, so ML gets its own values, loaded last.
  if [[ ! -f $CONFIG_DIR/ml.env ]]; then
    cat > "$CONFIG_DIR/ml.env" <<'EOF'
# Machine learning settings. Loaded after immich.env, so values here win for the ML service.
# All MACHINE_LEARNING_* options: https://docs.immich.app/install/environment-variables
IMMICH_HOST=127.0.0.1
IMMICH_PORT=3003
# MACHINE_LEARNING_WORKERS=1
# MACHINE_LEARNING_MODEL_TTL=300
EOF
  fi
  chmod 640 "$CONFIG_DIR/ml.env"; chgrp "$IMMICH_USER" "$CONFIG_DIR/ml.env"
}

write_units() {
  log "Writing systemd units"
  local cur=$IMMICH_ROOT/current
  cat > /etc/systemd/system/immich-server.service <<EOF
[Unit]
Description=Immich server
Documentation=https://docs.immich.app
After=network-online.target postgresql.service valkey-server.service immich-machine-learning.service
Wants=network-online.target postgresql.service valkey-server.service

[Service]
Type=simple
User=$IMMICH_USER
Group=$IMMICH_USER
WorkingDirectory=$cur
EnvironmentFile=$cur/server.env
EnvironmentFile=$CONFIG_DIR/immich.env
ExecStart=$cur/server/bin/start.sh
Restart=always
RestartSec=5
TimeoutStopSec=30
SyslogIdentifier=immich-server
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

  if [[ $INSTALL_ML == 1 ]]; then
    cat > /etc/systemd/system/immich-machine-learning.service <<EOF
[Unit]
Description=Immich machine learning
Documentation=https://docs.immich.app
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$IMMICH_USER
Group=$IMMICH_USER
WorkingDirectory=$cur/ml
EnvironmentFile=$cur/ml.env
EnvironmentFile=$CONFIG_DIR/immich.env
EnvironmentFile=$CONFIG_DIR/ml.env
ExecStart=$cur/ml/venv/bin/python -m immich_ml
Restart=always
RestartSec=5
TimeoutStopSec=20
LimitCORE=0
SyslogIdentifier=immich-ml
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  else
    rm -f /etc/systemd/system/immich-machine-learning.service
  fi

  # immich-admin, like "docker exec -it immich_server immich-admin"
  cat > /usr/local/bin/immich-admin <<EOF
#!/usr/bin/env bash
set -e
[[ \$EUID -eq 0 ]] || exec sudo "\$0" "\$@"
set -a; . "$cur/server.env"; . "$CONFIG_DIR/immich.env"; set +a
cd "$cur"
exec setpriv --reuid="$IMMICH_USER" --regid="$IMMICH_USER" --init-groups -- "$cur/server/bin/start.sh" immich-admin "\$@"
EOF
  chmod 755 /usr/local/bin/immich-admin
  systemctl daemon-reload
}

stop_services() {
  systemctl stop immich-server.service immich-machine-learning.service 2>/dev/null || true
}

activate_release() {
  local prev=
  [[ -L $IMMICH_ROOT/current ]] && prev=$(readlink -f "$IMMICH_ROOT/current")
  log "Activating $IMMICH_VERSION${prev:+ (previous: $(basename "$prev"))}"
  stop_services
  ln -sfn "releases/$IMMICH_VERSION" "$IMMICH_ROOT/current"
  local units=(immich-server.service)
  [[ $INSTALL_ML == 1 ]] && units+=(immich-machine-learning.service)
  systemctl enable -q "${units[@]}"
  systemctl start "${units[@]}"

  info "waiting for the server (database migrations can take a few minutes on upgrades)..."
  local port
  port=$(env_get IMMICH_PORT "$CONFIG_DIR/immich.env"); port=${port:-2283}
  for _ in $(seq 1 120); do
    [[ $(curl -fsS -m 2 "http://127.0.0.1:$port/api/server/ping" 2>/dev/null) == '{"res":"pong"}' ]] && break
    systemctl -q is-active immich-server || { journalctl -u immich-server -n 40 --no-pager >&2; die "immich-server stopped"; }
    sleep 5
  done
  [[ $(curl -fsS -m 2 "http://127.0.0.1:$port/api/server/ping" 2>/dev/null) == '{"res":"pong"}' ]] \
    || { journalctl -u immich-server -n 40 --no-pager >&2; die "the server did not answer on port $port"; }
  if [[ $INSTALL_ML == 1 ]]; then
    for _ in $(seq 1 30); do curl -fsS -m 2 http://127.0.0.1:3003/ping >/dev/null 2>&1 && break; sleep 2; done
    curl -fsS -m 2 http://127.0.0.1:3003/ping >/dev/null 2>&1 || warn "machine learning is not answering yet: journalctl -u immich-machine-learning"
  fi
}

prune() {
  log "Cleaning up"
  local cur keep=0 r
  cur=$(readlink -f "$IMMICH_ROOT/current")
  # newest first; always keep the active one
  while read -r r; do
    [[ $r == "$cur" ]] && continue
    if [[ ! -f $r/.complete ]]; then rm -rf "$r"; continue; fi
    keep=$((keep + 1))
    (( keep < KEEP_RELEASES )) || { info "removing old release $(basename "$r")"; rm -rf "$r"; }
  done < <(ls -1dt "$IMMICH_ROOT"/releases/*/ 2>/dev/null | sed 's#/$##')
  rm -rf "$BUILD_CACHE/src" "$BUILD_CACHE/work"
  [[ $CLEAN_BUILD_CACHE == 1 ]] && rm -rf "$BUILD_CACHE"
  true
}

summary() {
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  printf '\n%sImmich %s is running.%s\n' "$c_grn" "$IMMICH_VERSION" "$c_off"
  cat <<EOF
  Web UI:        http://${ip:-<container-ip>}:2283  (first visit creates the admin account)
  Settings:      $CONFIG_DIR/immich.env, $CONFIG_DIR/ml.env
  Media:         $UPLOAD_LOCATION
  Model cache:   $ML_CACHE_LOCATION
  Logs:          journalctl -u immich-server -u immich-machine-learning -f
  Install log:   $LOG_FILE
  Admin CLI:     immich-admin --help
  Upgrade:       $0 upgrade            (or: $0 upgrade vX.Y.Z)
EOF
}

status() {
  local cur; cur=$(readlink -f "$IMMICH_ROOT/current" 2>/dev/null || echo none)
  echo "active release: $(basename "$cur")"
  echo "built releases: $(ls "$IMMICH_ROOT/releases" 2>/dev/null | tr '\n' ' ')"
  echo "native libs:    base-images $(cat "$STATE_DIR/base-images.rev" 2>/dev/null || echo none)"
  echo "node:           $(node --version 2>/dev/null || echo none)"
  echo "ffmpeg:         $(dpkg-query -W -f='${Version}' jellyfin-ffmpeg7 2>/dev/null || echo none)"
  local u; for u in immich-server immich-machine-learning "postgresql@$PG_MAJOR-main" valkey-server; do
    printf '%-24s %s\n' "$u:" "$(systemctl is-active "$u" 2>/dev/null || true)"
  done
}

# ---------------------------------------------------------------------- Main --
main() {
  local cmd=${1:-install}
  case $cmd in
    install|upgrade) [[ -n ${2:-} ]] && IMMICH_VERSION=$2 ;;
    status) status; exit 0 ;;
    -h|--help|help) sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown command '$cmd' (use install, upgrade or status)" ;;
  esac

  [[ $EUID -eq 0 ]] || die "run as root"

  local steps=(
    "preflight|Checking the system"
    "setup_apt|Configuring APT"
    "resolve_version|Resolving the release"
    "install_packages|Installing packages"
    "fetch_sources|Fetching sources"
    "setup_user_and_config|User and configuration"   # creates/reads DB_PASSWORD
    "install_valkey|Valkey"
    "install_postgres|PostgreSQL"
    "install_node|Node.js"
    "build_base_libs|Image libraries"
    "install_ffmpeg|ffmpeg"
    "install_intel_opencl|Intel OpenCL runtime"
    "build_release|Building Immich"
    "write_units|systemd units"
    "activate_release|Starting Immich"
    "prune|Cleaning up"
  )
  ui_start "$*"
  STEP_TOTAL=${#steps[@]}
  local s
  for s in "${steps[@]}"; do
    STEP_N=$((STEP_N + 1)); STEP_TITLE=${s#*|}
    ui_send STEP "$STEP_N" "$STEP_TOTAL" "$STEP_TITLE"
    "${s%%|*}"
  done
  summary
}

main "$@"
