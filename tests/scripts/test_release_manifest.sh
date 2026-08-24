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
scaled = {"armeabi-v7a": 1003003, "arm64-v8a": 1004003, "x86_64": 1006003}
assert all(asset["versionCode"] == scaled[asset["arch"]] for asset in android)
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
echo "Signer #1 certificate DN: O=mobilka, CN=mobilka"
echo "Signer #1 certificate SHA-256 digest: 4a:76:9b:92:8d:47:82:77:30:e3:c5:e1:5a:e3:86:5c:d8:b8:99:93:13:a3:e5:79:ba:a9:b7:34:56:46:55:cd"
SH
cat > "${android_home}/cmdline-tools/latest/bin/apkanalyzer" <<'SH'
#!/usr/bin/env bash
if [ "$2" = application-id ]; then echo com.rslnmzhn.mobilka; exit 0; fi
if [ "$2" = version-code ]; then
  case "$3" in
    *armeabi-v7a*) abi=1 ;;
    *arm64-v8a*) abi=2 ;;
    *x86_64*) abi=4 ;;
  esac
  echo $((abi * 1000 + 1002003))
  exit 0
fi
exit 1
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
# Android assets must carry scaled split-per-ABI version codes:
# abi*1000 + build number (armeabi=1, arm64=2, x86_64=4) for 1.2.3/1002003.
python3 - "${work}/mobilka-v1.2.3-release-manifest.json" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
codes = {
    asset["arch"]: asset["versionCode"]
    for asset in manifest["assets"]
    if asset["platform"] == "android"
}
expected = {"armeabi-v7a": 1003003, "arm64-v8a": 1004003, "x86_64": 1006003}
if codes != expected:
    raise SystemExit(f"Unexpected scaled version codes: {codes}")
PY

echo "release manifest tests passed"
