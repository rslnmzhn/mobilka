#!/usr/bin/env bash
set -euo pipefail

EXPECTED_OPENSSL_VERSION="${EXPECTED_OPENSSL_VERSION:-3.0.13}"
EXPECTED_PUBLIC_KEY_BASE64="${EXPECTED_PUBLIC_KEY_BASE64:-}"
if [[ $# -ne 1 || ! -f "$1" || -L "$1" ]]; then
  echo "Usage: sign_release_manifest.sh MANIFEST.json" >&2
  exit 1
fi
if [[ -z "${UPDATE_MANIFEST_PRIVATE_KEY:-}" ]]; then
  echo "UPDATE_MANIFEST_PRIVATE_KEY is required." >&2
  exit 1
fi
if [[ "$(openssl version | awk '{print $2}')" != "${EXPECTED_OPENSSL_VERSION}" ]]; then
  echo "Unexpected OpenSSL version; expected ${EXPECTED_OPENSSL_VERSION}." >&2
  exit 1
fi

manifest="$1"
signature="${manifest%.json}.sig"
key_file=""
public_file=""
cleanup() {
  [[ -z "${key_file}" ]] || rm -f -- "${key_file}"
  [[ -z "${public_file}" ]] || rm -f -- "${public_file}"
}
trap cleanup EXIT HUP INT TERM
umask 077
temp_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
key_file="$(mktemp "${temp_root%/}/mobilka-manifest-key.XXXXXX")"
public_file="$(mktemp "${temp_root%/}/mobilka-manifest-public.XXXXXX")"
chmod 600 "${key_file}" "${public_file}"
printf '%s\n' "${UPDATE_MANIFEST_PRIVATE_KEY}" > "${key_file}"

openssl pkey -in "${key_file}" -pubout -out "${public_file}" >/dev/null 2>&1
actual_public_key="$(openssl pkey -pubin -in "${public_file}" -outform DER | tail -c 32 | base64 -w 0)"
if [[ -z "${EXPECTED_PUBLIC_KEY_BASE64}" || "${actual_public_key}" != "${EXPECTED_PUBLIC_KEY_BASE64}" ]]; then
  rm -f -- "${signature}"
  echo "Manifest signing key does not match the client-pinned public key." >&2
  exit 1
fi
openssl pkeyutl -sign -rawin -inkey "${key_file}" -in "${manifest}" -out "${signature}"
if [[ "$(wc -c < "${signature}")" -ne 64 ]] ||
   ! openssl pkeyutl -verify -rawin -pubin -inkey "${public_file}" \
     -in "${manifest}" -sigfile "${signature}" >/dev/null 2>&1; then
  rm -f -- "${signature}"
  echo "Manifest Ed25519 signature verification failed." >&2
  exit 1
fi
echo "${signature}"
