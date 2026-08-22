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
  signer_count="$(printf '%s\n' "${output}" \
    | awk '/certificate SHA-256 digest:/ { count++ } END { print count + 0 }')"
  [[ "${signer_count}" -eq 1 ]] || { echo "Expected one APK signer: ${apk}" >&2; exit 1; }
  actual="$(printf '%s\n' "${output}" \
    | awk -F': ' '/certificate SHA-256 digest:/ { print $2; exit }' \
    | sed 's/../&:/g;s/:$//' \
    | tr '[:lower:]' '[:upper:]')"
  [[ -n "${actual}" ]] || { echo "APK signer digest missing: ${apk}" >&2; exit 1; }
  [[ "${actual}" == "${expected_signer}" ]] || { echo "APK signer mismatch: ${apk}" >&2; exit 1; }
  [[ "$(${apkanalyzer} manifest application-id "${apk}")" == "${application_id}" ]] || {
    echo "APK application ID mismatch: ${apk}" >&2; exit 1;
  }
  [[ "$(${apkanalyzer} manifest version-code "${apk}")" == "${version_code}" ]] || {
    echo "APK version code mismatch: ${apk}" >&2; exit 1;
  }
  case "$(basename "${apk}")" in
    *armeabi-v7a*) expected_abi="armeabi-v7a" ;;
    *arm64-v8a*) expected_abi="arm64-v8a" ;;
    *x86_64*) expected_abi="x86_64" ;;
    *) echo "APK filename does not declare a supported ABI: ${apk}" >&2; exit 1 ;;
  esac
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
