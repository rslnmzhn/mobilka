#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PUBSPEC_PATH="${ROOT_DIR}/pubspec.yaml"
OUTPUT_FILE="${GITHUB_OUTPUT:-}"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: resolve_release_version.sh [--dry-run] [--github-output PATH] [--pubspec PATH]

Resolve the stable release version for the normal release workflow:
- If no stable vX.Y.Z tags exist, bootstrap from pubspec.yaml X.Y.Z.
- Otherwise bump the patch segment of the highest stable vX.Y.Z tag.
- Ignore prerelease tags such as vX.Y.Z-pre.N.

Android versionCode uses:
  major * 1000000 + minor * 1000 + patch

The decimal release convention carries patch and minor after 9.
The computed versionCode must stay within Android's signed 32-bit ceiling.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --github-output)
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --pubspec)
      PUBSPEC_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "${PUBSPEC_PATH}" ]]; then
  echo "pubspec not found: ${PUBSPEC_PATH}" >&2
  exit 1
fi

PUBSPEC_VERSION="$(
  sed -n -E 's/^[[:space:]]*version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+)(\+[0-9]+)?[[:space:]]*\r?$/\1/p' "${PUBSPEC_PATH}" \
    | head -n 1
)"

if [[ -z "${PUBSPEC_VERSION}" ]]; then
  echo "Unable to read stable semver from ${PUBSPEC_PATH}" >&2
  exit 1
fi

git -C "${ROOT_DIR}" fetch --tags --force >/dev/null 2>&1 || true

BASE_VERSION="0.5.1"

LATEST_FIX="$(
  git -C "${ROOT_DIR}" tag --list "v${BASE_VERSION}_fix*" \
    | sed -n -E "s/^v${BASE_VERSION//./\\.}_fix([0-9]+)$/\\1/p" \
    | sort -n \
    | tail -n 1
)"

if [[ -z "${LATEST_FIX}" ]]; then
  NEXT_FIX=1
else
  NEXT_FIX=$((LATEST_FIX + 1))
fi

RELEASE_VERSION="${BASE_VERSION}_fix${NEXT_FIX}"
RELEASE_TAG="v${RELEASE_VERSION}"

IFS='.' read -r MAJOR MINOR PATCH <<<"${BASE_VERSION}"
BASE_CODE=$((MAJOR * 1000000 + MINOR * 1000 + PATCH))
ANDROID_VERSION_CODE=$((BASE_CODE * 100 + NEXT_FIX))
ANDROID_VERSION_CODE_LIMIT=2100000000
if (( ANDROID_VERSION_CODE <= 0 || ANDROID_VERSION_CODE > ANDROID_VERSION_CODE_LIMIT )); then
  echo "Computed Android versionCode ${ANDROID_VERSION_CODE} exceeds supported range." >&2
  exit 1
fi

if git -C "${ROOT_DIR}" rev-parse -q --verify "refs/tags/${RELEASE_TAG}" >/dev/null 2>&1; then
  echo "Resolved stable tag already exists locally: ${RELEASE_TAG}" >&2
  exit 1
fi

if git -C "${ROOT_DIR}" remote get-url origin >/dev/null 2>&1; then
  if git -C "${ROOT_DIR}" ls-remote --exit-code --tags origin "refs/tags/${RELEASE_TAG}" >/dev/null 2>&1; then
    echo "Resolved stable tag already exists on origin: ${RELEASE_TAG}" >&2
    exit 1
  fi
fi

if [[ -n "${OUTPUT_FILE}" ]]; then
  {
    echo "release_version=${RELEASE_VERSION}"
    echo "release_tag=${RELEASE_TAG}"
    echo "android_version_code=${ANDROID_VERSION_CODE}"
  } >> "${OUTPUT_FILE}"
fi

echo "release_version=${RELEASE_VERSION}"
echo "release_tag=${RELEASE_TAG}"
echo "android_version_code=${ANDROID_VERSION_CODE}"

if (( DRY_RUN == 1 )); then
  echo "Resolved in dry-run mode."
fi
