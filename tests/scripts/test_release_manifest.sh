#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/mobilka-manifest-test.XXXXXX")"
trap 'rm -rf -- "${work}"' EXIT
version="1.2.3"
for name in \
  android-armeabi-v7a.apk android-arm64-v8a.apk android-x86_64.apk \
  linux-x86_64.AppImage linux-x64.zip windows-x64.msi windows-x64.zip; do
  printf 'dummy asset %s\n' "${name}" > "${work}/mobilka-v${version}-${name}"
done

command=(bash "${root}/.github/scripts/generate_release_manifest.sh"
  --assets-dir "${work}" --version "${version}" --tag "v${version}"
  --repository "rslnmzhn/mobilka" --android-version-code 1002003)
"${command[@]}" >/dev/null
manifest="${work}/mobilka-v${version}-release-manifest.json"
first="$(sha256sum "${manifest}" | cut -d' ' -f1)"
"${command[@]}" >/dev/null
second="$(sha256sum "${manifest}" | cut -d' ' -f1)"
[[ "${first}" == "${second}" ]]

python3 - "${manifest}" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
raw = path.read_bytes()
value = json.loads(raw)
canonical = json.dumps(value, ensure_ascii=True, allow_nan=False,
                       sort_keys=True, separators=(",", ":")).encode()
assert raw == canonical
android = [asset for asset in value["assets"] if asset["platform"] == "android"]
assert len(android) == 3
assert all(asset["applicationId"] == "com.rslnmzhn.mobilka" for asset in android)
assert all(asset["versionCode"] == 1002003 for asset in android)
assert all(asset["applyMode"] == "packageInstaller" and asset["install"] for asset in android)
assert all(len(asset["sha256"]) == 64 and asset["size"] > 0 for asset in value["assets"])
PY

if command -v openssl >/dev/null 2>&1; then
  openssl_version="$(openssl version | awk '{print $2}')"
  key="${work}/test-ed25519.pem"
  public="${work}/test-ed25519-public.pem"
  openssl genpkey -algorithm Ed25519 -out "${key}" >/dev/null 2>&1
  openssl pkey -in "${key}" -pubout -out "${public}" >/dev/null 2>&1
  expected_public_key="$(openssl pkey -pubin -in "${public}" -outform DER | tail -c 32 | base64 -w 0)"
  UPDATE_MANIFEST_PRIVATE_KEY="$(<"${key}")" \
    EXPECTED_OPENSSL_VERSION="${openssl_version}" \
    EXPECTED_PUBLIC_KEY_BASE64="${expected_public_key}" \
    bash "${root}/.github/scripts/sign_release_manifest.sh" "${manifest}" >/dev/null
  signature="${work}/mobilka-v${version}-release-manifest.sig"
  [[ "$(wc -c < "${signature}")" -eq 64 ]]
  openssl pkeyutl -verify -rawin -pubin -inkey "${public}" \
    -in "${manifest}" -sigfile "${signature}" >/dev/null 2>&1
fi

if bash "${root}/.github/scripts/generate_release_manifest.sh" \
  --assets-dir "${work}" --version "${version}" --tag v9.9.9 \
  --repository rslnmzhn/mobilka --android-version-code 1002003 >/dev/null 2>&1; then
  echo "Generator accepted a mismatched tag." >&2
  exit 1
fi

android_home="${work}/android-sdk"
mkdir -p "${android_home}/build-tools/35.0.0" "${android_home}/cmdline-tools/latest/bin"
cat > "${android_home}/build-tools/35.0.0/apksigner" <<'SH'
#!/usr/bin/env bash
echo "Signer #1 certificate SHA-256 digest: 4a769b928d47827730e3c5e15ae3865cd8b8999313a3e579baa9b734564655cd"
SH
cat > "${android_home}/cmdline-tools/latest/bin/apkanalyzer" <<'SH'
#!/usr/bin/env bash
case "$2" in
  application-id) echo com.rslnmzhn.mobilka ;;
  version-code) echo 1002003 ;;
  *) exit 1 ;;
esac
SH
cat > "${work}/unzip" <<'SH'
#!/usr/bin/env bash
echo lib/arm64-v8a/libapp.so
SH
chmod +x "${android_home}/build-tools/35.0.0/apksigner" \
  "${android_home}/cmdline-tools/latest/bin/apkanalyzer" "${work}/unzip"
PATH="${work}:${PATH}" \
ANDROID_HOME="${android_home}" \
ANDROID_SIGNER_SHA256="4A:76:9B:92:8D:47:82:77:30:E3:C5:E1:5A:E3:86:5C:D8:B8:99:93:13:A3:E5:79:BA:A9:B7:34:56:46:55:CD" \
  bash "${root}/.github/scripts/verify_android_release.sh" \
    com.rslnmzhn.mobilka 1002003 \
    "${work}/mobilka-v${version}-android-arm64-v8a.apk"
if ANDROID_HOME="${android_home}" ANDROID_SIGNER_SHA256="00:00" \
  bash "${root}/.github/scripts/verify_android_release.sh" \
    com.rslnmzhn.mobilka 1002003 \
    "${work}/mobilka-v${version}-android-arm64-v8a.apk" >/dev/null 2>&1; then
  echo "Android verifier accepted a mismatched signer." >&2
  exit 1
fi
echo "release manifest tests passed"
