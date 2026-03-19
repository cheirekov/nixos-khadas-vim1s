#!/usr/bin/env bash
set -euo pipefail

NIX_CACHE_REGION="${NIX_CACHE_REGION:-eu-west-3}"
NIX_CACHE_BUCKET_NAME="${NIX_CACHE_BUCKET_NAME:-nix-cache-vim1s-${NIX_CACHE_REGION}}"
NIX_CACHE_SIGNING_KEY_FILE="${NIX_CACHE_SIGNING_KEY_FILE:-/home/yc/.local/share/${NIX_CACHE_BUCKET_NAME}/cache-private-key.pem}"
NIX_CACHE_WRITE_NAR_LISTING="${NIX_CACHE_WRITE_NAR_LISTING:-false}"
WINDOW_MINUTES="${WINDOW_MINUTES:-240}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-60}"
STATE_FILE="${STATE_FILE:-/tmp/vim1s-local-cache-pushed.txt}"
BUILD_LOG="${BUILD_LOG:-}"
MODE="${1:---follow}"

usage() {
  cat <<'EOF'
Usage:
  push-local-s3-cache.sh --follow
  push-local-s3-cache.sh --once

Environment:
  NIX_CACHE_REGION            Default: eu-west-3
  NIX_CACHE_BUCKET_NAME       Default: nix-cache-vim1s-${NIX_CACHE_REGION}
  NIX_CACHE_SIGNING_KEY_FILE  Default: /home/yc/.local/share/${NIX_CACHE_BUCKET_NAME}/cache-private-key.pem
  NIX_CACHE_WRITE_NAR_LISTING Default: false
  WINDOW_MINUTES              Default: 240
  INTERVAL_SECONDS            Default: 60
  STATE_FILE                  Default: /tmp/vim1s-local-cache-pushed.txt
  BUILD_LOG                   Optional: build log to mine for realized derivation outputs

This helper is a local salvage uploader for the S3 binary cache used by the CI
builders. It is useful when a build is already running and you want to seed the
cache without restarting that build under a proper Nix post-build hook.

When BUILD_LOG is provided, the helper watches derivations mentioned in that log
and pushes their outputs as soon as they materialize in /nix/store. Without
BUILD_LOG, it falls back to scanning for recent store entries.
EOF
}

log() {
  printf '[local-cache] %s\n' "$*"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

cache_uri() {
  printf 's3://%s?region=%s&compression=zstd&parallel-compression=true&write-nar-listing=%s&secret-key=%s' \
    "${NIX_CACHE_BUCKET_NAME}" \
    "${NIX_CACHE_REGION}" \
    "${NIX_CACHE_WRITE_NAR_LISTING}" \
    "${NIX_CACHE_SIGNING_KEY_FILE}"
}

filter_candidate_paths() {
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    [[ "${path}" == /nix/store/* ]] || continue
    [[ "${path}" != *.drv ]] || continue
    [[ "${path}" != *.lock ]] || continue
    [[ "${path}" != *.chroot ]] || continue
    [[ "${path}" != *.check ]] || continue
    [[ "${path}" != *.tmp-* ]] || continue
    [[ -e "${path}" ]] || continue
    printf '%s\n' "${path}"
  done | sort -u
}

discover_log_outputs() {
  [[ -f "${BUILD_LOG}" ]] || return 0

  rg -o "/nix/store/[[:alnum:]]{32}-[^']+\\.drv" "${BUILD_LOG}" 2>/dev/null \
    | sort -u \
    | while IFS= read -r drv; do
        [[ -n "${drv}" ]] || continue
        nix-store -q --outputs "${drv}" 2>/dev/null || true
      done \
    | filter_candidate_paths
}

discover_recent_paths_fallback() {
  find /nix/store -mindepth 1 -maxdepth 1 \
    \( -type f -o -type d -o -type l \) \
    -mmin "-${WINDOW_MINUTES}" \
    -printf '%p\n' \
    | filter_candidate_paths
}

discover_candidate_paths() {
  if [[ -n "${BUILD_LOG}" && -f "${BUILD_LOG}" ]]; then
    discover_log_outputs
  else
    discover_recent_paths_fallback
  fi
}

copy_new_paths() {
  local tmp_candidates tmp_new cache

  tmp_candidates="$(mktemp)"
  tmp_new="$(mktemp)"
  trap 'rm -f "${tmp_candidates}" "${tmp_new}"' RETURN

  discover_candidate_paths > "${tmp_candidates}"
  touch "${STATE_FILE}"
  comm -23 "${tmp_candidates}" <(sort -u "${STATE_FILE}") > "${tmp_new}" || true

  if [[ ! -s "${tmp_new}" ]]; then
    log "no new recent store paths to push"
    return 0
  fi

  cache="$(cache_uri)"
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    log "pushing ${path}"
    if nix --extra-experimental-features 'nix-command flakes' copy -L --to "${cache}" "${path}"; then
      printf '%s\n' "${path}" >> "${STATE_FILE}"
    else
      log "warning: failed to push ${path}"
    fi
  done < "${tmp_new}"
}

main() {
  if [[ "${MODE}" != "--follow" && "${MODE}" != "--once" && "${MODE}" != "-h" && "${MODE}" != "--help" ]]; then
    usage >&2
    exit 1
  fi

  if [[ "${MODE}" == "-h" || "${MODE}" == "--help" ]]; then
    usage
    exit 0
  fi

  if ! have_cmd nix; then
    echo "nix is required" >&2
    exit 1
  fi

  if [[ ! -f "${NIX_CACHE_SIGNING_KEY_FILE}" ]]; then
    echo "cache signing key file not found: ${NIX_CACHE_SIGNING_KEY_FILE}" >&2
    exit 1
  fi

  log "using bucket ${NIX_CACHE_BUCKET_NAME} in ${NIX_CACHE_REGION}"
  log "using signing key ${NIX_CACHE_SIGNING_KEY_FILE}"
  if [[ -n "${BUILD_LOG}" && -f "${BUILD_LOG}" ]]; then
    log "tracking derivations from ${BUILD_LOG}"
  else
    log "tracking recent outputs from the last ${WINDOW_MINUTES} minutes"
  fi

  copy_new_paths

  if [[ "${MODE}" == "--once" ]]; then
    exit 0
  fi

  while true; do
    sleep "${INTERVAL_SECONDS}"
    copy_new_paths
  done
}

main "$@"
