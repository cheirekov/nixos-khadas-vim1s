#!/usr/bin/env bash
set -euo pipefail

TARGET_ATTR="${TARGET_ATTR:?TARGET_ATTR is required}"
REPO_URL="${REPO_URL:?REPO_URL is required}"
REPO_SHA="${REPO_SHA:?REPO_SHA is required}"
WORK_ROOT="${WORK_ROOT:-/var/tmp/nixos-khadas-vim1s-build}"
ATTIC_ENDPOINT="${ATTIC_ENDPOINT:-}"
ATTIC_CACHE="${ATTIC_CACHE:-}"
ATTIC_TOKEN="${ATTIC_TOKEN:-}"

log() {
  printf '[builder] %s\n' "$*"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

ensure_packages() {
  local -a pkgs

  if have_cmd apt-get; then
    pkgs=()
    have_cmd git || pkgs+=(git)
    have_cmd curl || pkgs+=(curl)
    have_cmd jq || pkgs+=(jq)
    have_cmd xz || pkgs+=(xz-utils)
    have_cmd zstd || pkgs+=(zstd)
    if ((${#pkgs[@]})); then
      as_root apt-get update -y
      as_root apt-get install -y "${pkgs[@]}" ca-certificates
    fi
  elif have_cmd dnf; then
    pkgs=()
    have_cmd git || pkgs+=(git)
    have_cmd curl || pkgs+=(curl-minimal)
    have_cmd jq || pkgs+=(jq)
    have_cmd xz || pkgs+=(xz)
    have_cmd zstd || pkgs+=(zstd)
    if ((${#pkgs[@]})); then
      as_root dnf install -y "${pkgs[@]}" ca-certificates
    fi
  elif have_cmd yum; then
    pkgs=()
    have_cmd git || pkgs+=(git)
    have_cmd curl || pkgs+=(curl-minimal)
    have_cmd jq || pkgs+=(jq)
    have_cmd xz || pkgs+=(xz)
    have_cmd zstd || pkgs+=(zstd)
    if ((${#pkgs[@]})); then
      as_root yum install -y "${pkgs[@]}" ca-certificates
    fi
  fi
}

install_nix() {
  if have_cmd nix; then
    return
  fi

  log "installing Nix"
  curl -fsSL https://nixos.org/nix/install -o /tmp/install-nix.sh
  chmod +x /tmp/install-nix.sh
  as_root /bin/sh /tmp/install-nix.sh --daemon --yes
}

load_nix() {
  export NIX_CONFIG=$'experimental-features = nix-command flakes\naccept-flake-config = true\nmax-jobs = auto'

  if [[ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
    # shellcheck source=/dev/null
    source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  fi

  if ! have_cmd nix; then
    echo "nix is not available after installation" >&2
    exit 1
  fi
}

setup_attic() {
  if [[ -z "${ATTIC_ENDPOINT}" || -z "${ATTIC_CACHE}" || -z "${ATTIC_TOKEN}" ]]; then
    log "Attic configuration incomplete, skipping Attic setup"
    return
  fi

  log "configuring Attic cache"
  nix run github:zhaofengli/attic#default -- login --set-default ci "${ATTIC_ENDPOINT}" "${ATTIC_TOKEN}"
  nix run github:zhaofengli/attic#default -- use "${ATTIC_CACHE}"
}

clone_repo() {
  log "checking out ${REPO_URL} at ${REPO_SHA}"
  rm -rf "${WORK_ROOT}/repo"
  mkdir -p "${WORK_ROOT}"
  git clone --filter=blob:none "${REPO_URL}" "${WORK_ROOT}/repo"
  git -C "${WORK_ROOT}/repo" checkout --detach "${REPO_SHA}"
}

build_target() {
  local result_path

  log "building ${TARGET_ATTR}"
  cd "${WORK_ROOT}/repo"
  nix build -L ".#${TARGET_ATTR}" --accept-flake-config
  result_path="$(readlink -f result)"

  {
    echo "BUILD_RESULT=${result_path}"
    echo "BUILD_TARGET=${TARGET_ATTR}"
    echo "BUILD_SHA=${REPO_SHA}"
    nix path-info -Sh "${result_path}"
  } | tee "${WORK_ROOT}/build-summary.txt"
}

push_attic() {
  local result_path

  if [[ -z "${ATTIC_ENDPOINT}" || -z "${ATTIC_CACHE}" || -z "${ATTIC_TOKEN}" ]]; then
    echo "ATTIC_PUSH=skipped"
    return
  fi

  result_path="$(awk -F= '/^BUILD_RESULT=/{print $2}' "${WORK_ROOT}/build-summary.txt")"
  if [[ -z "${result_path}" ]]; then
    echo "Unable to find BUILD_RESULT in ${WORK_ROOT}/build-summary.txt" >&2
    exit 1
  fi

  log "pushing ${result_path} to Attic cache ${ATTIC_CACHE}"
  nix run github:zhaofengli/attic#default -- push "${ATTIC_CACHE}" "${result_path}"
  echo "ATTIC_PUSH=ok"
}

ensure_packages
install_nix
load_nix
setup_attic
clone_repo
build_target
push_attic
