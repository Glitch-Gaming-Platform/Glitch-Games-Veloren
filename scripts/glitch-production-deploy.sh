#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/glitch-production-deploy.sh [options]

Packages and deploys the Veloren streamed-native Glitch build with the official
Glitch CLI Deploy tool.

Required environment:
  GLITCH_DEPLOY_TOKEN          Deploy-scoped CLI token, usually gl_deploy_...
  GLITCH_RUNTIME_TITLE_TOKEN   Veloren runtime title token from the previous deployment.
  GLITCH_SHARED_PASSWORD       Shared runtime password from the previous deployment.

Optional environment:
  GLITCH_TITLE_ID              Defaults to the Veloren title id.
  GLITCH_DEPLOY_VERSION        Defaults to a UTC timestamp, max 20 characters.
  GLITCH_DEPLOY_OUT_DIR        Defaults to ~/Downloads.
  GLITCH_DEPLOY_POLL_TIMEOUT_MS Defaults to 7200000 (2 hours).
  GLITCH_DEPLOY_POLL_INTERVAL_MS Defaults to 10000.

Options:
  --version VERSION            Deployment version string, max 20 characters.
  --out-dir DIR                Directory for the upload ZIP.
  --zip-name NAME              Exact ZIP file name to create.
  --title-id ID                Glitch title UUID.
  --build-type TYPE            production, playtest, or demo. Default: production.
  --api-url URL                Override the Glitch API base URL.
  --env ENV                    CLI environment preset. Default: production.
  --build-local                Also build the Docker image locally before upload.
  --dry-run                    Ask the CLI to validate/archive without uploading.
  --no-wait                   Do not wait for the backend deployment job.
  --skip-secret-scan           Skip repo and ZIP secret scans.
  -h, --help                   Show this help.

This script intentionally does not use GLITCH_TITLE_TOKEN for CLI auth because
the Veloren runtime also needs a custom variable with that exact name. Use
GLITCH_DEPLOY_TOKEN for the CLI token and GLITCH_RUNTIME_TITLE_TOKEN for the
runtime value that becomes custom_variables.GLITCH_TITLE_TOKEN.
EOF
}

log() {
  printf '[glitch-production-deploy] %s\n' "$*"
}

fail() {
  printf '[glitch-production-deploy] ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
cd "$repo_root"

title_id="${GLITCH_TITLE_ID:-355282b1-f6a8-4183-9105-044993ba6066}"
deploy_token="${GLITCH_DEPLOY_TOKEN:-${GLITCH_CLI_DEPLOY_TOKEN:-${GLITCH_API_TOKEN:-}}}"
runtime_title_token="${GLITCH_RUNTIME_TITLE_TOKEN:-${VELOREN_GLITCH_TITLE_TOKEN:-${GLITCH_TITLE_TOKEN:-}}}"
shared_password="${GLITCH_SHARED_PASSWORD:-}"
version="${GLITCH_DEPLOY_VERSION:-$(date -u +%Y%m%d%H%M%S)}"
out_dir="${GLITCH_DEPLOY_OUT_DIR:-${HOME}/Downloads}"
zip_name="${GLITCH_DEPLOY_ZIP_NAME:-}"
build_type="${GLITCH_BUILD_TYPE:-production}"
deploy_env="${GLITCH_DEPLOY_ENV:-production}"
api_url="${GLITCH_API_URL:-}"
wait_for_build=1
dry_run=0
build_local="${GLITCH_BUILD_LOCAL:-0}"
skip_secret_scan="${GLITCH_SKIP_SECRET_SCAN:-0}"
poll_timeout_ms="${GLITCH_DEPLOY_POLL_TIMEOUT_MS:-7200000}"
poll_interval_ms="${GLITCH_DEPLOY_POLL_INTERVAL_MS:-10000}"
stream_entry="${GLITCH_STREAM_ENTRY:-vnc.html?autoconnect=1&resize=scale&quality=8&compression=1&shared=1}"
cli_package="${GLITCH_DEPLOY_CLI_PACKAGE:-github:Glitch-Gaming-Platform/Glitch-Cli-Deploy}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="${2:?--version requires a value}"
      shift 2
      ;;
    --out-dir)
      out_dir="${2:?--out-dir requires a value}"
      shift 2
      ;;
    --zip-name)
      zip_name="${2:?--zip-name requires a value}"
      shift 2
      ;;
    --title-id)
      title_id="${2:?--title-id requires a value}"
      shift 2
      ;;
    --build-type)
      build_type="${2:?--build-type requires a value}"
      shift 2
      ;;
    --api-url)
      api_url="${2:?--api-url requires a value}"
      shift 2
      ;;
    --env)
      deploy_env="${2:?--env requires a value}"
      shift 2
      ;;
    --build-local)
      build_local=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --no-wait)
      wait_for_build=0
      shift
      ;;
    --skip-secret-scan)
      skip_secret_scan=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

[[ -n "$deploy_token" ]] || fail "Set GLITCH_DEPLOY_TOKEN to the deploy-scoped CLI token."
[[ -n "$runtime_title_token" ]] || fail "Set GLITCH_RUNTIME_TITLE_TOKEN to the Veloren runtime title token."
[[ -n "$shared_password" ]] || fail "Set GLITCH_SHARED_PASSWORD to the previous deployment shared password."

if [[ "$runtime_title_token" == gl_deploy_* ]]; then
  fail "GLITCH_RUNTIME_TITLE_TOKEN looks like a CLI deploy token. Put the gl_deploy token in GLITCH_DEPLOY_TOKEN instead."
fi

if [[ "$deploy_token" == "$runtime_title_token" ]]; then
  fail "Deploy token and runtime title token are identical; these should be different values."
fi

if ((${#version} > 20)); then
  fail "Version string must be 20 characters or fewer; got ${#version}."
fi

case "$build_type" in
  production|playtest|demo) ;;
  *) fail "Invalid build type: $build_type" ;;
esac

zip_name="${zip_name:-veloren-glitch-streamed-native-${version}.zip}"
zip_path="${out_dir%/}/${zip_name}"
image_tag="${GLITCH_DEPLOY_IMAGE:-veloren-glitch-web:${version}}"
manifest_tmp=""

cleanup() {
  if [[ -n "${manifest_tmp:-}" && -f "$manifest_tmp" ]]; then
    rm -f "$manifest_tmp"
  fi
}
trap cleanup EXIT INT TERM

[[ -f glitch-streamed-native.json ]] || fail "Missing glitch-streamed-native.json"
[[ -f docker/Dockerfile.glitch-veloren-web ]] || fail "Missing docker/Dockerfile.glitch-veloren-web"
[[ -f docker/glitch-web-entrypoint.sh ]] || fail "Missing docker/glitch-web-entrypoint.sh"
[[ -f glitch/streamed-native/x11_mouse_bridge.py ]] || fail "Missing streamed-native X11 mouse bridge"
[[ -f glitch/streamed-native/inject_novnc_pointer_lock.py ]] || fail "Missing noVNC pointer-lock injector"
[[ -f glitch/streamed-native/novnc_pointer_lock_mouse.js ]] || fail "Missing noVNC pointer-lock browser script"

if [[ -n "$(git diff --name-only --diff-filter=U)" ]]; then
  fail "Unresolved merge conflicts are present. Resolve them before deploying."
fi

scan_for_secret() {
  local label="$1"
  local value="$2"
  local hits_file

  [[ -n "$value" ]] || return 0
  hits_file="$(mktemp "${TMPDIR:-/tmp}/glitch-secret-scan.XXXXXX")"

  if grep -R -l -F \
    --exclude-dir=.git \
    --exclude-dir=target \
    --exclude-dir=node_modules \
    --exclude='*.bak*' \
    --exclude='*.zip' \
    --exclude='.env' \
    --exclude='.env.*' \
    --exclude='native-container.env' \
    -- "$value" . \
    >"$hits_file"; then
    log "${label} was found in packageable files:"
    sed 's#^\./#  #' "$hits_file" >&2
    rm -f "$hits_file"
    fail "Remove ${label} from repo files before deploying."
  fi

  rm -f "$hits_file"
}

if [[ "$skip_secret_scan" != "1" ]]; then
  log "Scanning packageable files for deployment secrets"
  scan_for_secret "CLI deploy token" "$deploy_token"
  scan_for_secret "runtime title token" "$runtime_title_token"
  scan_for_secret "shared password" "$shared_password"
else
  log "Secret scan skipped by request."
fi

if [[ "$build_local" == "1" ]]; then
  require_cmd docker
  log "Building local Docker image for verification: ${image_tag}"
  docker buildx build \
    --platform linux/amd64 \
    --progress=plain \
    -f docker/Dockerfile.glitch-veloren-web \
    -t "$image_tag" \
    --load \
    .
fi

require_cmd node
require_cmd npm
require_cmd zip
require_cmd unzip

mkdir -p "$out_dir"
rm -f "$zip_path"

log "Writing upload ZIP: ${zip_path}"
zip -rq -X "$zip_path" . \
  -x ".git/*" \
  -x "target/*" \
  -x "**/target/*" \
  -x "node_modules/*" \
  -x "**/node_modules/*" \
  -x ".DS_Store" \
  -x "**/.DS_Store" \
  -x "*.bak*" \
  -x "**/*.bak*" \
  -x "*.zip" \
  -x ".env" \
  -x ".env.*" \
  -x "**/.env" \
  -x "**/.env.*" \
  -x "native-container.env" \
  -x "**/native-container.env" \
  -x "userdata/*" \
  -x "docker/userdata/*"

log "Verifying ZIP structure"
unzip -tq "$zip_path" >/dev/null
zip_listing="$(unzip -Z1 "$zip_path")"
zip_contains() {
  case $'\n'"$zip_listing"$'\n' in
    *$'\n'"$1"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}

zip_contains "glitch-streamed-native.json" || fail "ZIP missing glitch-streamed-native.json"
zip_contains "docker/Dockerfile.glitch-veloren-web" || fail "ZIP missing streamed-native Dockerfile"
zip_contains "docker/glitch-web-entrypoint.sh" || fail "ZIP missing streamed-native entrypoint"
zip_contains "glitch/streamed-native/x11_mouse_bridge.py" || fail "ZIP missing X11 mouse bridge"
zip_contains "glitch/streamed-native/inject_novnc_pointer_lock.py" || fail "ZIP missing noVNC pointer-lock injector"
zip_contains "glitch/streamed-native/novnc_pointer_lock_mouse.js" || fail "ZIP missing noVNC pointer-lock browser script"

if [[ "$skip_secret_scan" != "1" ]]; then
  log "Scanning ZIP for deployment secrets"
  for secret in "$deploy_token" "$runtime_title_token" "$shared_password"; do
    [[ -n "$secret" ]] || continue
    if unzip -p "$zip_path" 2>/dev/null | LC_ALL=C grep -aF -- "$secret" >/dev/null; then
      fail "Verified ZIP still contains a deployment secret."
    fi
  done
fi

manifest_tmp="$(mktemp "${TMPDIR:-/tmp}/glitch-production-manifest.XXXXXX.json")"
chmod 600 "$manifest_tmp"

log "Writing temporary CLI manifest"
MANIFEST_PATH="$manifest_tmp" \
GLITCH_TITLE_ID_VALUE="$title_id" \
GLITCH_DEPLOY_VERSION_VALUE="$version" \
GLITCH_BUILD_TYPE_VALUE="$build_type" \
GLITCH_STREAM_ENTRY_VALUE="$stream_entry" \
RUNTIME_GLITCH_TITLE_TOKEN_VALUE="$runtime_title_token" \
RUNTIME_GLITCH_SHARED_PASSWORD_VALUE="$shared_password" \
node <<'NODE'
const fs = require('node:fs');

const required = (name) => {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing ${name}`);
  }
  return value;
};

const envDefault = (name, fallback) => process.env[name] || fallback;

const manifest = {
  title_id: required('GLITCH_TITLE_ID_VALUE'),
  version: required('GLITCH_DEPLOY_VERSION_VALUE'),
  entry_point: required('GLITCH_STREAM_ENTRY_VALUE'),
  deployment_type: 'streamed_native',
  build_type: required('GLITCH_BUILD_TYPE_VALUE'),
  custom_variables: {
    dockerfile: envDefault('GLITCH_DOCKERFILE', 'docker/Dockerfile.glitch-veloren-web'),
    target_port: envDefault('GLITCH_TARGET_PORT', '6080'),
    runtime_preset: envDefault('GLITCH_RUNTIME_PRESET', 'veloren'),

    GLITCH_API_BASE_URL: envDefault('GLITCH_RUNTIME_API_BASE_URL', 'https://api.glitch.fun/api'),
    GLITCH_TITLE_TOKEN: required('RUNTIME_GLITCH_TITLE_TOKEN_VALUE'),
    GLITCH_SHARED_PASSWORD: required('RUNTIME_GLITCH_SHARED_PASSWORD_VALUE'),

    VELOREN_WEB_MODE: envDefault('VELOREN_WEB_MODE', 'all_in_one'),
    VELOREN_AUTH_MODE: envDefault('VELOREN_AUTH_MODE', 'glitch'),
    VELOREN_AUTH_SERVER_URL: envDefault('VELOREN_AUTH_SERVER_URL', 'https://auth.veloren.net'),
    VELOREN_AUTH_AUTOREGISTER: envDefault('VELOREN_AUTH_AUTOREGISTER', '0'),
    VELOREN_SERVER_GRACE_SECONDS: envDefault('VELOREN_SERVER_GRACE_SECONDS', '0'),
    VELOREN_STREAM_PRESET: envDefault('VELOREN_STREAM_PRESET', 'balanced'),

    VELOREN_ENABLE_GPU: envDefault('VELOREN_ENABLE_GPU', '0'),
    LIBGL_ALWAYS_SOFTWARE: envDefault('LIBGL_ALWAYS_SOFTWARE', '1'),
    NVIDIA_VISIBLE_DEVICES: envDefault('NVIDIA_VISIBLE_DEVICES', 'none'),
    NVIDIA_DRIVER_CAPABILITIES: envDefault('NVIDIA_DRIVER_CAPABILITIES', 'compute,utility'),

    GLITCH_NOVNC_POINTER_LOCK: envDefault('GLITCH_NOVNC_POINTER_LOCK', '1'),
    GLITCH_NOVNC_POINTER_LOCK_X_SCALE: envDefault('GLITCH_NOVNC_POINTER_LOCK_X_SCALE', '0.5'),
    GLITCH_NOVNC_POINTER_LOCK_Y_SCALE: envDefault('GLITCH_NOVNC_POINTER_LOCK_Y_SCALE', '0.4'),
    GLITCH_NOVNC_POINTER_LOCK_MAX_DELTA: envDefault('GLITCH_NOVNC_POINTER_LOCK_MAX_DELTA', '48'),
    GLITCH_VNC_ABSOLUTE_MOUSE: envDefault('GLITCH_VNC_ABSOLUTE_MOUSE', '0'),
    GLITCH_VNC_ABSOLUTE_MOUSE_X_SCALE: envDefault('GLITCH_VNC_ABSOLUTE_MOUSE_X_SCALE', '0.015'),
    GLITCH_VNC_ABSOLUTE_MOUSE_Y_SCALE: envDefault('GLITCH_VNC_ABSOLUTE_MOUSE_Y_SCALE', '0.006'),
    GLITCH_VNC_ABSOLUTE_MOUSE_DEADZONE: envDefault('GLITCH_VNC_ABSOLUTE_MOUSE_DEADZONE', '1.8'),
    GLITCH_VNC_ABSOLUTE_MOUSE_MAX_DELTA: envDefault('GLITCH_VNC_ABSOLUTE_MOUSE_MAX_DELTA', '48'),
    GLITCH_VNC_ABSOLUTE_MOUSE_MAX_Y_DELTA: envDefault('GLITCH_VNC_ABSOLUTE_MOUSE_MAX_Y_DELTA', '28'),
  },
};

fs.writeFileSync(required('MANIFEST_PATH'), JSON.stringify(manifest, null, 2) + '\n', { mode: 0o600 });
NODE

cli_args=(
  npm exec
  --yes
  "--package=${cli_package}"
  --
  glitch-deploy
  deploy
  "$zip_path"
  --title
  "$title_id"
  --manifest
  "$manifest_tmp"
)

if [[ -n "$api_url" ]]; then
  cli_args+=(--api-url "$api_url")
fi

if [[ -n "$deploy_env" ]]; then
  cli_args+=(--env "$deploy_env")
fi

if [[ "$wait_for_build" == "1" ]]; then
  cli_args+=(--wait)
fi

if [[ "$dry_run" == "1" ]]; then
  cli_args+=(--dry-run)
fi

log "Deploying version ${version} to Glitch title ${title_id}"
GLITCH_TITLE_TOKEN="$deploy_token" \
GLITCH_DEPLOY_POLL_TIMEOUT_MS="$poll_timeout_ms" \
GLITCH_DEPLOY_POLL_INTERVAL_MS="$poll_interval_ms" \
"${cli_args[@]}"

log "Deployment command completed."
ls -lh "$zip_path"
