#!/usr/bin/env bash
set -euo pipefail

ASSETS_DIR=""
RELEASE_VERSION=""
RELEASE_TAG=""
REPOSITORY=""
ANDROID_VERSION_CODE=""

usage() {
  cat <<'EOF'
Usage: generate_release_manifest.sh --assets-dir PATH --version X.Y.Z --tag vX.Y.Z --repository owner/repo --android-version-code INTEGER

Generate canonical, compact UTF-8 JSON after all release assets have their final
published names. The output has no trailing newline and is byte-for-byte stable.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --assets-dir) ASSETS_DIR="${2:-}"; shift 2 ;;
    --version) RELEASE_VERSION="${2:-}"; shift 2 ;;
    --tag) RELEASE_TAG="${2:-}"; shift 2 ;;
    --repository) REPOSITORY="${2:-}"; shift 2 ;;
    --android-version-code) ANDROID_VERSION_CODE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ ! "${RELEASE_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
   [[ "${RELEASE_TAG}" != "v${RELEASE_VERSION}" ]] ||
   [[ ! "${REPOSITORY}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
   [[ ! "${ANDROID_VERSION_CODE}" =~ ^[1-9][0-9]*$ ]] ||
   (( ANDROID_VERSION_CODE > 2100000000 )); then
  echo "Invalid release manifest arguments." >&2
  usage >&2
  exit 1
fi
if [[ ! -d "${ASSETS_DIR}" ]]; then
  echo "Assets directory not found: ${ASSETS_DIR}" >&2
  exit 1
fi

MANIFEST_PATH="${ASSETS_DIR}/mobilka-v${RELEASE_VERSION}-release-manifest.json"
python3 - "${ASSETS_DIR}" "${RELEASE_VERSION}" "${RELEASE_TAG}" \
  "${REPOSITORY}" "${ANDROID_VERSION_CODE}" "${MANIFEST_PATH}" <<'PY'
import hashlib
import json
import os
import pathlib
import sys
import tempfile

assets_dir = pathlib.Path(sys.argv[1])
version, tag, repository = sys.argv[2:5]
version_code = int(sys.argv[5])
major, minor, patch = map(int, version.split('.'))
expected_version_code = major * 1000000 + minor * 1000 + patch
if version_code != expected_version_code:
    raise SystemExit(
        f"Android versionCode {version_code} does not match release version {version}"
    )
# Flutter's Gradle plugin scales split-per-ABI APKs the same way the release
# verifier expects: <abi code> * 1000 + <pubspec build number>.
abi_codes = {"armeabi-v7a": 1, "arm64-v8a": 2, "x86_64": 4}
manifest_path = pathlib.Path(sys.argv[6])

specs = [
    dict(platform="android", arch="armeabi-v7a", format="apk", primary=True,
         applyMode="packageInstaller", install=True,
         applicationId="com.rslnmzhn.mobilka",
         versionCode=abi_codes["armeabi-v7a"] * 1000 + version_code,
         fileName=f"mobilka-v{version}-android-armeabi-v7a.apk"),
    dict(platform="android", arch="arm64-v8a", format="apk", primary=True,
         applyMode="packageInstaller", install=True,
         applicationId="com.rslnmzhn.mobilka",
         versionCode=abi_codes["arm64-v8a"] * 1000 + version_code,
         fileName=f"mobilka-v{version}-android-arm64-v8a.apk"),
    dict(platform="android", arch="x86_64", format="apk", primary=True,
         applyMode="packageInstaller", install=True,
         applicationId="com.rslnmzhn.mobilka",
         versionCode=abi_codes["x86_64"] * 1000 + version_code,
         fileName=f"mobilka-v{version}-android-x86_64.apk"),
    dict(platform="linux", arch="x86_64", format="appimage", primary=True,
         applyMode="manual", install=False,
         fileName=f"mobilka-v{version}-linux-x86_64.AppImage"),
    dict(platform="linux", arch="x86_64", format="zip", primary=False,
         applyMode="manual", install=False,
         fileName=f"mobilka-v{version}-linux-x64.zip"),
    dict(platform="windows", arch="x86_64", format="msi", primary=True,
         installer=True, applyMode="msi", install=True,
         fileName=f"mobilka-v{version}-windows-x64.msi"),
    dict(platform="windows", arch="x86_64", format="zip", primary=False,
         installer=False, applyMode="manual", install=False,
         fileName=f"mobilka-v{version}-windows-x64.zip"),
]

assets = []
for spec in specs:
    path = assets_dir / spec["fileName"]
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"Missing or unsafe release asset: {path}")
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
            size += len(chunk)
    if size <= 0:
        raise SystemExit(f"Release asset is empty: {path}")
    assets.append({
        **spec,
        "size": size,
        "sha256": digest.hexdigest(),
        "downloadUrl": f"https://github.com/{repository}/releases/download/{tag}/{spec['fileName']}",
    })

manifest = {
    "schemaVersion": 1,
    "release": {
        "channel": "stable", "tag": tag, "version": version,
        "draft": False, "prerelease": False,
    },
    "assets": assets,
}
encoded = json.dumps(
    manifest, ensure_ascii=True, allow_nan=False, sort_keys=True,
    separators=(",", ":"),
).encode("utf-8")
fd, temporary_name = tempfile.mkstemp(prefix=f".{manifest_path.name}.", dir=assets_dir)
try:
    with os.fdopen(fd, "wb") as output:
        output.write(encoded)
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary_name, manifest_path)
except BaseException:
    try:
        os.unlink(temporary_name)
    except FileNotFoundError:
        pass
    raise
print(manifest_path)
PY
