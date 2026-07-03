#!/usr/bin/env bash

# Run this from the repo root:
#   /Users/devindixon/Development/Glitch-Games-Veloren

VERSION="${VERSION:-production-$(date -u +%Y%m%d-%H%M%S)}"
OUT_DIR="${OUT_DIR:-$HOME/Downloads}"
DOCKERFILE="docker/Dockerfile.glitch-veloren-web"
IMAGE_TAG="${IMAGE_TAG:-veloren-glitch-web:${VERSION}}"
ZIP_NAME="${ZIP_NAME:-veloren-glitch-streamed-native-${VERSION}.zip}"
ZIP_PATH="${OUT_DIR%/}/${ZIP_NAME}"
VARS_PATH="${OUT_DIR%/}/glitch-production-vars-${VERSION}.json"

# Set these before running, or replace the placeholder values here.
: "${GLITCH_TITLE_TOKEN:=PASTE_GLITCH_TITLE_TOKEN_HERE}"
: "${GLITCH_SHARED_PASSWORD:=PASTE_GLITCH_SHARED_PASSWORD_HERE}"

if [[ "$GLITCH_TITLE_TOKEN" == "PASTE_GLITCH_TITLE_TOKEN_HERE" ]]; then
  echo "ERROR: Set GLITCH_TITLE_TOKEN before running, or replace the placeholder in this script." >&2
  exit 1
fi

if [[ "$GLITCH_SHARED_PASSWORD" == "PASTE_GLITCH_SHARED_PASSWORD_HERE" ]]; then
  echo "ERROR: Set GLITCH_SHARED_PASSWORD before running, or replace the placeholder in this script." >&2
  exit 1
fi

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker is required" >&2; exit 1; }
command -v zip >/dev/null 2>&1 || { echo "ERROR: zip is required" >&2; exit 1; }
command -v unzip >/dev/null 2>&1 || { echo "ERROR: unzip is required" >&2; exit 1; }

[[ -f "$DOCKERFILE" ]] || { echo "ERROR: Missing $DOCKERFILE" >&2; exit 1; }
[[ -f "glitch-streamed-native.json" ]] || { echo "ERROR: Missing glitch-streamed-native.json" >&2; exit 1; }
[[ -f "docker/glitch-web-entrypoint.sh" ]] || { echo "ERROR: Missing docker/glitch-web-entrypoint.sh" >&2; exit 1; }

if [[ -n "$(git diff --name-only --diff-filter=U)" ]]; then
  echo "ERROR: unresolved merge conflicts are present." >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

echo "[glitch-build] Writing Glitch production variables: $VARS_PATH"
cat > "$VARS_PATH" <<EOF
{
  "dockerfile": "docker/Dockerfile.glitch-veloren-web",
  "target_port": "6080",
  "runtime_preset": "veloren",

  "VELOREN_WEB_MODE": "all_in_one",
  "VELOREN_AUTH_MODE": "glitch",
  "GLITCH_TITLE_TOKEN": "$GLITCH_TITLE_TOKEN",
  "GLITCH_SHARED_PASSWORD": "$GLITCH_SHARED_PASSWORD",

  "VELOREN_ENABLE_GPU": "0",
  "LIBGL_ALWAYS_SOFTWARE": "1",
  "NVIDIA_VISIBLE_DEVICES": "none",

  "VELOREN_STREAM_PRESET": "balanced",
  "VELOREN_AUTH_SERVER_URL": "https://auth.veloren.net",
  "VELOREN_AUTH_AUTOREGISTER": "0",
  "VELOREN_SERVER_GRACE_SECONDS": "0",

  "GLITCH_NOVNC_POINTER_LOCK": "1",
  "GLITCH_NOVNC_POINTER_LOCK_X_SCALE": "0.5",
  "GLITCH_NOVNC_POINTER_LOCK_Y_SCALE": "0.4",
  "GLITCH_NOVNC_POINTER_LOCK_MAX_DELTA": "48",
  "GLITCH_VNC_ABSOLUTE_MOUSE": "0",
  "GLITCH_VNC_ABSOLUTE_MOUSE_X_SCALE": "0.015",
  "GLITCH_VNC_ABSOLUTE_MOUSE_Y_SCALE": "0.006",
  "GLITCH_VNC_ABSOLUTE_MOUSE_DEADZONE": "1.8",
  "GLITCH_VNC_ABSOLUTE_MOUSE_MAX_DELTA": "48",
  "GLITCH_VNC_ABSOLUTE_MOUSE_MAX_Y_DELTA": "28"
}
EOF
chmod 600 "$VARS_PATH"

echo "[glitch-build] Building Docker image: $IMAGE_TAG"
docker buildx build \
  --platform linux/amd64 \
  --progress=plain \
  -f "$DOCKERFILE" \
  -t "$IMAGE_TAG" \
  --load \
  .

echo "[glitch-build] Creating upload ZIP: $ZIP_PATH"
rm -f "$ZIP_PATH"

zip -r -X "$ZIP_PATH" . \
  -x ".git/*" \
  -x "target/*" \
  -x "**/target/*" \
  -x "node_modules/*" \
  -x "**/node_modules/*" \
  -x "*.orig" \
  -x "*.rej" \
  -x "*.log" \
  -x "**/__pycache__/*" \
  -x "*.pyc" \
  -x "**/*.pyc" \
  -x "*.zip" \
  -x ".DS_Store" \
  -x "**/.DS_Store" \
  -x "__MACOSX/*" \
  -x ".env" \
  -x ".env.*" \
  -x "**/.env" \
  -x "**/.env.*" \
  -x "native-container.env" \
  -x "**/native-container.env" \
  -x "userdata/*" \
  -x "docker/userdata/*"

echo "[glitch-build] Verifying ZIP integrity"
unzip -tq "$ZIP_PATH" >/dev/null

echo "[glitch-build] Verifying required files are present"
unzip -Z1 "$ZIP_PATH" | grep -qx "glitch-streamed-native.json"
unzip -Z1 "$ZIP_PATH" | grep -qx "docker/Dockerfile.glitch-veloren-web"
unzip -Z1 "$ZIP_PATH" | grep -qx "docker/glitch-web-entrypoint.sh"

echo "[glitch-build] Checking ZIP does not contain runtime secrets"
if unzip -p "$ZIP_PATH" 2>/dev/null | grep -aF "$GLITCH_TITLE_TOKEN" >/dev/null; then
  echo "ERROR: ZIP contains GLITCH_TITLE_TOKEN. Do not upload this ZIP." >&2
  exit 1
fi

if unzip -p "$ZIP_PATH" 2>/dev/null | grep -aF "$GLITCH_SHARED_PASSWORD" >/dev/null; then
  echo "ERROR: ZIP contains GLITCH_SHARED_PASSWORD. Do not upload this ZIP." >&2
  exit 1
fi

echo
echo "[glitch-build] Done."
echo "ZIP to upload:"
echo "  $ZIP_PATH"
echo
echo "Variables file to copy into Glitch:"
echo "  $VARS_PATH"
echo
ls -lh "$ZIP_PATH" "$VARS_PATH"
