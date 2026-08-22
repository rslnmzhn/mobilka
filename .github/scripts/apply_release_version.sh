#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PUBSPEC_PATH="${ROOT_DIR}/pubspec.yaml"
RELEASE_VERSION=""
RELEASE_VERSION_CODE=""

usage() {
  cat <<'EOF'
Usage: apply_release_version.sh --version X.Y.Z --version-code N [--pubspec PATH]

This helper is the only release-path script allowed to rewrite pubspec.yaml.
PR and CI-only jobs must not call it.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      RELEASE_VERSION="$2"
      shift 2
      ;;
    --version-code)
      RELEASE_VERSION_CODE="$2"
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

if [[ -z "${RELEASE_VERSION}" || -z "${RELEASE_VERSION_CODE}" ]]; then
  usage >&2
  exit 1
fi

TEMP_FILE="${PUBSPEC_PATH}.tmp"
awk -v version="${RELEASE_VERSION}" -v version_code="${RELEASE_VERSION_CODE}" '
  BEGIN { updated = 0 }
  {
    line = $0
    sub(/\r$/, "", line)
  }
  line ~ /^[[:space:]]*version:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+(\+[0-9]+)?[[:space:]]*$/ && updated == 0 {
    print "version: " version "+" version_code
    updated = 1
    next
  }
  { print }
  END {
    if (updated == 0) {
      exit 1
    }
  }
' "${PUBSPEC_PATH}" > "${TEMP_FILE}" || {
  rm -f "${TEMP_FILE}"
  echo "Unable to update version line in ${PUBSPEC_PATH}" >&2
  exit 1
}

mv "${TEMP_FILE}" "${PUBSPEC_PATH}"

grep -n "^version:" "${PUBSPEC_PATH}"
