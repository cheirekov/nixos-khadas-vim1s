#!/usr/bin/env bash
set -euo pipefail

TARGET_ATTR="${TARGET_ATTR:?TARGET_ATTR is required}"
REPO_URL="${REPO_URL:?REPO_URL is required}"
REPO_SHA="${REPO_SHA:?REPO_SHA is required}"
WORK_ROOT="${WORK_ROOT:-/var/tmp/nixos-khadas-vim1s-build}"
NIX_CACHE_REGION="${NIX_CACHE_REGION:-${AWS_REGION:-eu-west-3}}"
NIX_CACHE_BUCKET_NAME="${NIX_CACHE_BUCKET_NAME:-nix-cache-vim1s-${NIX_CACHE_REGION}}"
NIX_CACHE_SIGNING_KEY_NAME="${NIX_CACHE_SIGNING_KEY_NAME:-${NIX_CACHE_BUCKET_NAME}}"
NIX_BINARY_CACHE_SECRET_KEY="${NIX_BINARY_CACHE_SECRET_KEY:-}"
NIX_BINARY_CACHE_SECRET_KEY_FILE=""
POST_BUILD_HOOK_FILE=""

log() {
  printf '[builder] %s\n' "$*"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

download() {
  local url="${1:?url is required}"
  local out="${2:?output path is required}"

  if have_cmd curl; then
    curl --fail --location --progress-bar "$url" -o "$out"
  elif have_cmd wget; then
    wget --show-progress -O "$out" "$url"
  else
    echo "Neither curl nor wget is available for downloading ${url}" >&2
    exit 1
  fi
}

as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

ensure_home() {
  if [[ -n "${HOME:-}" ]]; then
    return
  fi

  if [[ "$(id -u)" -eq 0 ]]; then
    export HOME=/root
  else
    export HOME="/home/$(id -un)"
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
  download https://nixos.org/nix/install /tmp/install-nix.sh
  chmod +x /tmp/install-nix.sh
  # The legacy installer hides the large binary-tarball download behind a
  # plain curl command. Rewrite it locally so SSM/CloudWatch logs show whether
  # the EC2 host is actually pulling data or just waiting.
  sed -i \
    -e 's/curl --fail -L /curl --fail -L --progress-bar /' \
    -e 's/wget "$1" -O "$2"/wget --show-progress "$1" -O "$2"/' \
    /tmp/install-nix.sh
  as_root env HOME="${HOME}" /bin/sh /tmp/install-nix.sh --daemon --yes
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

s3_cache_store_url() {
  printf 's3://%s?region=%s&compression=zstd&parallel-compression=true&write-nar-listing=true&secret-key=%s' \
    "${NIX_CACHE_BUCKET_NAME}" \
    "${NIX_CACHE_REGION}" \
    "${NIX_BINARY_CACHE_SECRET_KEY_FILE}"
}

normalize_binary_cache_signing_key() {
  local key="${1:-}"

  key="${key//$'\r'/}"
  key="${key#"${key%%[![:space:]]*}"}"
  key="${key%"${key##*[![:space:]]}"}"

  if [[ -z "${key}" ]]; then
    echo ""
    return 0
  fi

  if [[ "${key}" != *:* ]]; then
    key="${NIX_CACHE_SIGNING_KEY_NAME}:${key}"
  fi

  printf '%s\n' "${key}"
}

setup_binary_cache_signing_key() {
  local normalized_key

  if [[ -z "${NIX_BINARY_CACHE_SECRET_KEY}" ]]; then
    log "binary cache signing key not provided, cache push will be skipped"
    return
  fi

  normalized_key="$(normalize_binary_cache_signing_key "${NIX_BINARY_CACHE_SECRET_KEY}")"
  if [[ -z "${normalized_key}" ]]; then
    log "binary cache signing key was empty after normalization, cache push will be skipped"
    return
  fi

  mkdir -p "${WORK_ROOT}/secrets"
  chmod 700 "${WORK_ROOT}/secrets"
  NIX_BINARY_CACHE_SECRET_KEY_FILE="${WORK_ROOT}/secrets/nix-cache-private-key.pem"
  printf '%s\n' "${normalized_key}" > "${NIX_BINARY_CACHE_SECRET_KEY_FILE}"
  chmod 600 "${NIX_BINARY_CACHE_SECRET_KEY_FILE}"
}

install_post_build_hook() {
  local nix_bin

  if [[ -z "${NIX_BINARY_CACHE_SECRET_KEY_FILE}" ]]; then
    return
  fi

  nix_bin="$(command -v nix)"
  POST_BUILD_HOOK_FILE="${WORK_ROOT}/post-build-hook.sh"

  cat > "${POST_BUILD_HOOK_FILE}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ -z "\${OUT_PATHS:-}" ]]; then
  exit 0
fi

echo "[post-build-hook] pushing completed outputs for \${DRV_PATH:-unknown}" >&2
if ! env -u NIX_CONFIG "${nix_bin}" --extra-experimental-features 'nix-command flakes' copy -L --to "$(s3_cache_store_url)" \${OUT_PATHS}; then
  echo "[post-build-hook] warning: cache push failed for \${DRV_PATH:-unknown}" >&2
fi
exit 0
EOF

  chmod 755 "${POST_BUILD_HOOK_FILE}"
  export NIX_CONFIG="${NIX_CONFIG}"$'\n'"post-build-hook = ${POST_BUILD_HOOK_FILE}"
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

push_binary_cache() {
  local result_path

  if [[ -z "${NIX_BINARY_CACHE_SECRET_KEY_FILE}" ]]; then
    echo "CACHE_PUSH=skipped"
    return
  fi

  result_path="$(awk -F= '/^BUILD_RESULT=/{print $2}' "${WORK_ROOT}/build-summary.txt")"
  if [[ -z "${result_path}" ]]; then
    echo "Unable to find BUILD_RESULT in ${WORK_ROOT}/build-summary.txt" >&2
    exit 1
  fi

  log "pushing ${result_path} to S3 binary cache ${NIX_CACHE_BUCKET_NAME}"
  if nix copy -L --to "$(s3_cache_store_url)" "${result_path}"; then
    echo "CACHE_PUSH=ok"
  else
    log "warning: failed to push ${result_path} to S3 binary cache ${NIX_CACHE_BUCKET_NAME}"
    echo "CACHE_PUSH=failed"
  fi
}

ensure_home
ensure_packages
install_nix
load_nix
setup_binary_cache_signing_key
install_post_build_hook
clone_repo
build_target
push_binary_cache
