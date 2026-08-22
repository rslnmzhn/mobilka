#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: verify_android_release.sh APPLICATION_ID VERSION_CODE APK..." >&2
  exit 1
fi
application_id="$1"
version_code="$2"
shift 2
expected_signer="${ANDROID_SIGNER_SHA256:?ANDROID_SIGNER_SHA256 is required}"
apksigner="$(find "${ANDROID_HOME:?ANDROID_HOME is required}/build-tools" -name apksigner -type f | sort -V | tail -n 1)"
apkanalyzer="$(find "${ANDROID_HOME}/cmdline-tools" -name apkanalyzer -type f | sort -V | tail -n 1)"
[[ -x "${apksigner}" && -x "${apkanalyzer}" ]] || {
  echo "Android apksigner or apkanalyzer was not found." >&2
  exit 1
}

for apk in "$@"; do
  [[ -f "${apk}" ]] || { echo "APK not found: ${apk}" >&2; exit 1; }
  output="$(${apksigner} verify --print-certs "${apk}" 2>&1)" || {
    echo "APK signature verification failed: ${apk}" >&2
    exit 1
  }
  # Extract SHA-256 certificate digests as raw 64-char hex strings so the
  # check does not depend on apksigner's label formatting across versions.
  mapfile -t digests < <(
    printf '%s\n' "${output}" \
      | grep -E -A1 'SHA-256 digest' \
      | grep -oE '[0-9A-Fa-f]{64}' \
      | tr '[:lower:]' '[:upper:]' \
      | sort -u
  )
  [[ "${#digests[@]}" -eq 1 ]] || {
    echo "Expected exactly one APK signer digest: ${apk} (found ${#digests[@]})" >&2
    printf 'apksigner output:\n%s\n' "${output}" >&2
    exit 1
  }
  actual="$(printf '%s' "${digests[0]}" | sed 's/../&:/g;s/:$//')"
  [[ "${actual}" == "${expected_signer}" ]] || {
    echo "APK signer mismatch: ${apk} (expected ${expected_signer}, got ${actual})" >&2
    exit 1
  }
  actual_application_id="$(${apkanalyzer} manifest application-id "${apk}" 2>/dev/null | tail -n1 | tr -d '[:space:]')"
  [[ "${actual_application_id}" == "${application_id}" ]] || {
    echo "APK application ID mismatch: ${apk} (expected ${application_id}, got '${actual_application_id}')" >&2
    exit 1
  }
  case "$(basename "${apk}")" in
    *armeabi-v7a*) expected_abi="armeabi-v7a"; abi_version_code=1 ;;
    *arm64-v8a*) expected_abi="arm64-v8a"; abi_version_code=2 ;;
    *x86_64*) expected_abi="x86_64"; abi_version_code=4 ;;
    *) echo "APK filename does not declare a supported ABI: ${apk}" >&2; exit 1 ;;
  esac
  # Flutter's Gradle plugin overrides the versionCode of split-per-ABI APKs
  # as <abi code> * 1000 + <pubspec build number>.
  expected_version_code="$((abi_version_code * 1000 + version_code))"
  actual_version_code="$(${apkanalyzer} manifest version-code "${apk}" 2>/dev/null | tail -n1 | tr -d '[:space:]')"
  [[ "${actual_version_code}" == "${expected_version_code}" ]] || {
    echo "APK version code mismatch: ${apk} (expected ${expected_version_code}, got '${actual_version_code}')" >&2
    exit 1
  }
  mapfile -t packaged_abis < <(
    unzip -Z1 "${apk}" \
      | sed -n -E 's#^lib/([^/]+)/[^/]+$#\1#p' \
      | sort -u
  )
  [[ "${#packaged_abis[@]}" -eq 1 && "${packaged_abis[0]}" == "${expected_abi}" ]] || {
    echo "APK packaged ABI does not match filename: ${apk}" >&2
    exit 1
  }
done
