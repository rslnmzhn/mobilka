#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXPECTED_BUILDER_VERSION="${APPIMAGE_BUILDER_VERSION:-1.0.3}"
RECIPE_PATH="${ROOT_DIR}/.github/appimage/AppImageBuilder.yml"
DESKTOP_FILE="${ROOT_DIR}/.github/appimage/mobilka.desktop"
APP_VERSION="${APP_VERSION:-}"

cleanup_packaging_workspace() {
  rm -rf \
    "${ROOT_DIR}/AppDir" \
    "${ROOT_DIR}/appimage-build" \
    "${ROOT_DIR}/.appimage-builder-cache" \
    "${ROOT_DIR}/.appimage-builder-libs"
}

usage() {
  cat <<'EOF'
Usage: APP_VERSION=X.Y.Z package_linux_appimage.sh

Packages the existing Flutter Linux release bundle into an AppImage using the
pinned appimage-builder workflow toolchain. The script fails if the expected
appimage-builder version is not available or if the final AppImage is missing.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "${APP_VERSION}" ]]; then
  echo "APP_VERSION is required." >&2
  usage >&2
  exit 1
fi

if ! command -v appimage-builder >/dev/null 2>&1; then
  echo "appimage-builder is not installed or not on PATH." >&2
  exit 1
fi

ACTUAL_VERSION="$(appimage-builder --version 2>&1 || true)"
if [[ "${ACTUAL_VERSION}" != *"${EXPECTED_BUILDER_VERSION}"* ]]; then
  echo "Expected appimage-builder ${EXPECTED_BUILDER_VERSION}, got: ${ACTUAL_VERSION}" >&2
  exit 1
fi

if [[ ! -d "${ROOT_DIR}/build/linux/x64/release/bundle" ]]; then
  echo "Flutter Linux release bundle is missing. Build it before packaging." >&2
  exit 1
fi

desktop-file-validate "${DESKTOP_FILE}"

cd "${ROOT_DIR}"
trap cleanup_packaging_workspace EXIT
cleanup_packaging_workspace
rm -f "mobilka-v${APP_VERSION}-linux-x86_64.AppImage" "mobilka-v${APP_VERSION}-linux-x86_64.AppImage.zsync"

APP_VERSION="${APP_VERSION}" appimage-builder --recipe "${RECIPE_PATH}"

OUTPUT_PATH="${ROOT_DIR}/mobilka-v${APP_VERSION}-linux-x86_64.AppImage"
if [[ ! -f "${OUTPUT_PATH}" ]]; then
  echo "AppImage packaging did not produce ${OUTPUT_PATH}" >&2
  exit 1
fi

echo "AppImage created at ${OUTPUT_PATH}"
