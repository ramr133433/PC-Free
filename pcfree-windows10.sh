#!/usr/bin/env bash
# PC-Free launcher: Windows 10 only, one persistent disk.
set -Eeuo pipefail
IMAGE="dockurr/windows"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"
CFG=".pcfree-config"
DATA=".pcfree-data"
WIN10="pcfree-windows10"
MIN_FREE_GB="${PCFREE_MIN_FREE_GB:-10}"
DISK_SIZE="${PCFREE_DISK_SIZE:-32G}"

info(){ echo "[PC-Free] $*"; }
die(){ echo "[ERROR] $*" >&2; exit 1; }
ok(){ echo "[OK] $*"; }

ignore_line() {
  touch .gitignore
  grep -qxF "$1" .gitignore 2>/dev/null || echo "$1" >> .gitignore
}

check_space() {
  local path="$1" label="$2" free_kb required_kb
  free_kb="$(df -Pk "$path" | awk 'NR==2 {print $4}')"
  required_kb="$((MIN_FREE_GB * 1024 * 1024))"
  if [ "${free_kb:-0}" -lt "$required_kb" ]; then
    die "$label par sirf $(( ${free_kb:-0} / 1024 / 1024 )) GB free hai; kam az kam ${MIN_FREE_GB} GB chahiye. Space free karo ya PCFREE_MIN_FREE_GB se threshold adjust karo."
  fi
  ok "$label storage check pass: $((free_kb / 1024 / 1024)) GB free."
}

prerequisites() {
  command -v docker >/dev/null || die "Docker command nahi mila."
  command -v curl >/dev/null || die "curl available nahi."
  docker info >/dev/null 2>&1 || die "Docker daemon available nahi."
  [ -c /dev/kvm ] || die "/dev/kvm missing. Is Codespace/host par KVM unavailable hai; Windows VM start nahi ho sakti."
  [ -c /dev/net/tun ] || die "/dev/net/tun missing. TUN device unavailable hai."
  check_space "$ROOT" "Workspace"
  local docker_root
  docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  if [ -n "$docker_root" ] && [ -d "$docker_root" ]; then
    check_space "$docker_root" "Docker storage"
  fi
  ok "Docker, KVM, TUN aur storage checks pass."
  free -h || true
  df -h "$ROOT" || true
}

make_private_dirs() {
  ignore_line "$CFG"
  ignore_line "$DATA/"
  mkdir -p "$DATA/win10"
  chmod 700 "$DATA" "$DATA/win10" 2>/dev/null || true
}

setup_config() {
  if [ ! -f "$CFG" ]; then
    echo "First-time setup:"
    read -r -p "GitHub username: " GITHUB_USER
    [[ "$GITHUB_USER" =~ ^[a-zA-Z0-9-]{1,39}$ ]] || die "GitHub username invalid."
    read -r -p "Windows username [Docker]: " WINDOWS_USERNAME
    WINDOWS_USERNAME="${WINDOWS_USERNAME:-Docker}"
    [[ "$WINDOWS_USERNAME" =~ ^[a-zA-Z0-9._-]{1,20}$ ]] || die "Windows username invalid."
    read -r -s -p "Windows password (minimum 8 characters): " pw
    echo
    [ "${#pw}" -ge 8 ] || die "Password kam az kam 8 characters ka ho."
    pw64="$(printf '%s' "$pw" | base64 | tr -d '\n')"
    unset pw
    {
      printf 'GITHUB_USER=%s\n' "$GITHUB_USER"
      printf 'WINDOWS_USERNAME=%s\n' "$WINDOWS_USERNAME"
      printf 'WINDOWS_PASSWORD_B64=%s\n' "$pw64"
    } > "$CFG"
    chmod 600 "$CFG"
    unset pw64
    ok "Private config saved. Base64 encryption nahi hota; config file ko private rakho aur commit mat karo."
  fi
  # shellcheck disable=SC1090
  source "$CFG"
  WINDOWS_PASSWORD="$(printf '%s' "${WINDOWS_PASSWORD_B64:-}" | base64 -d 2>/dev/null || true)"
  [ -n "${GITHUB_USER:-}" ] || die "Saved GitHub username missing."
  [ -n "${WINDOWS_USERNAME:-}" ] || die "Saved Windows username missing."
  [ -n "${WINDOWS_PASSWORD:-}" ] || die "Saved Windows password missing/invalid."
}

follow_check() {
  info "GitHub follow status check: $GITHUB_USER → jephersonRD"
  local code
  code="$(curl -L -sS -o /dev/null -w '%{http_code}' -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/users/${GITHUB_USER}/following/jephersonRD" || true)"
  case "$code" in
    204) ok "Follow verified." ;;
    404) die "$GITHUB_USER jephersonRD ko follow nahi karta. Follow kar ke dobara run karo." ;;
    403) die "GitHub API rate limit/access restriction. Kuch der baad retry karo." ;;
    *) die "GitHub follow check failed (HTTP ${code:-unknown}); network/API check karo." ;;
  esac
}

exists(){ docker inspect "$1" >/dev/null 2>&1; }
running(){ [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" = true ]; }

stop_windows10() {
  if running "$WIN10"; then
    info "Windows 10 stopping..."
    docker stop --time 120 "$WIN10" >/dev/null
    ok "Windows 10 stopped; persistent disk preserved."
  else
    info "Windows 10 is not running."
  fi
}

start_windows10() {
  prerequisites
  follow_check
  if exists "$WIN10"; then
    if running "$WIN10"; then
      ok "Windows 10 already running."
    else
      info "Existing Windows 10 installation resume..."
      docker start "$WIN10" >/dev/null
      ok "Windows 10 resume request sent."
    fi
  else
    info "First Windows 10 install: image download and Windows setup may take time."
    docker run -d \
      --name "$WIN10" \
      --label pcfree.managed=true \
      --device=/dev/kvm \
      --device=/dev/net/tun \
      --cap-add NET_ADMIN \
      --stop-timeout 120 \
      -p 8006:8006 \
      -e "VERSION=10" \
      -e "USERNAME=$WINDOWS_USERNAME" \
      -e "PASSWORD=$WINDOWS_PASSWORD" \
      -e "RAM_SIZE=4G" \
      -e "CPU_CORES=2" \
      -e "DISK_SIZE=$DISK_SIZE" \
      -e "DISK_FMT=qcow2" \
      -e "ALLOCATE=N" \
      -v "$ROOT/$DATA/win10:/storage" \
      "$IMAGE" >/dev/null
    ok "Windows 10 container created."
  fi
  info "Codespace Ports tab mein port 8006 → Open in Browser. Visibility Private rakho."
  info "Virtual disk maximum: $DISK_SIZE; qcow2 grows with writes, actual usage barh sakta hai."
}

status() {
  docker ps -a --filter "name=$WIN10" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
  du -sh "$DATA/win10" 2>/dev/null || true
  df -h "$ROOT" || true
}

show_logs() {
  exists "$WIN10" || die "Windows 10 container abhi create nahi hua."
  docker logs --tail 100 -f "$WIN10"
}

prerequisites
make_private_dirs
setup_config
while true; do
  echo
  echo "========== PC-FREE / WINDOWS 10 =========="
  echo "1) Windows 10 start / resume"
  echo "2) Windows 10 stop"
  echo "3) Status / storage"
  echo "4) Logs"
  echo "5) Exit"
  read -r -p "Select [1-5]: " choice
  case "$choice" in
    1) start_windows10 ;;
    2) stop_windows10 ;;
    3) status ;;
    4) show_logs ;;
    5) unset WINDOWS_PASSWORD 2>/dev/null || true; info "Exit. Running Windows automatically stop nahi hoga."; exit 0 ;;
    *) echo "Invalid choice." ;;
  esac
done
