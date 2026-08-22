# Build, Release, And Packaging

This file summarizes the active build and packaging path for release artifacts.

## Main CI workflow

- `.github/workflows/build.yml`

Key jobs:

- `resolve_release`
- `build_android_release`
- `build_linux`
- `build_windows`
- `publish_release`

## GitHub Releases update contract

Stable updates consume GitHub Releases as the source of truth. Stable tags use
the exact `vX.Y.Z` format, and each release includes this machine-readable
manifest:

- `mobilka-vX.Y.Z-release-manifest.json`
- `mobilka-vX.Y.Z-release-manifest.sig`

The producer streams each final artifact through SHA-256 and writes deterministic,
compact JSON as canonical exact bytes with no trailing newline. The manifest
records platform, architecture, format, primary status, apply mode, install
status, file name, size, digest, and download URL. Android entries additionally
pin application ID `com.rslnmzhn.mobilka` and the resolved numeric version code.

Current stable release assets:

- `mobilka-vX.Y.Z-android-armeabi-v7a.apk`
- `mobilka-vX.Y.Z-android-arm64-v8a.apk`
- `mobilka-vX.Y.Z-android-x86_64.apk`
- `mobilka-vX.Y.Z-linux-x86_64.AppImage`
- `mobilka-vX.Y.Z-linux-x64.zip`
- `mobilka-vX.Y.Z-windows-x64.zip`
- `mobilka-vX.Y.Z-windows-x64.msi`
- `mobilka-vX.Y.Z-release-manifest.json`
- `mobilka-vX.Y.Z-release-manifest.sig`

After final MSI/APK signing and final asset naming, CI signs the exact manifest
bytes with Ed25519 using OpenSSL `3.0.13` on the pinned Ubuntu 24.04 runner. The
raw 64-byte detached signature is published beside the manifest. The private PEM
comes only from `UPDATE_MANIFEST_PRIVATE_KEY`; the temporary mode-`0600` key file
is removed by an exit trap and an `always()` cleanup step. Never print the key.

## Version resolution

- The first stable release uses the version in `pubspec.yaml`.
- Later releases increment the highest stable tag using the decimal patch
  convention, carrying when patch or minor exceeds 9.
- Prerelease tags are ignored.
- Android version codes use `major * 1000000 + minor * 1000 + patch`.

## Android signing

Release builds require `ANDROID_KEYSTORE_BASE64`,
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, and
`ANDROID_KEY_PASSWORD`. Pull request and non-publishing manual runs build a
debug APK and do not require signing secrets.

Every release APK is verified with Android SDK `apksigner` before upload. CI
requires the sole signer certificate SHA-256 fingerprint
`4A:76:9B:92:8D:47:82:77:30:E3:C5:E1:5A:E3:86:5C:D8:B8:99:93:13:A3:E5:79:BA:A9:B7:34:56:46:55:CD`.

Normal local development and debug APK builds do not need signing secrets.
Do not copy Landa's signing identity into mobilka. Create a mobilka-specific
keystore and configure its values directly as GitHub Actions secrets. A local
signed release build may use ignored `android/key.properties` and a local
keystore, but neither file belongs in Git.

## Windows MSI

The Windows job retains the portable ZIP and also builds a signed per-machine
MSI with pinned WiX Toolset 5. The MSI installs to Program Files and uses stable
UpgradeCode `FDE6F32F-2EFE-5295-A1FA-534DFD36A8A9`, allowing later MSI releases
to upgrade the installed product. The release manifest marks MSI as the primary
Windows artifact and the ZIP as non-installer portable distribution.

Publishing requires `WINDOWS_CERTIFICATE_BASE64` and
`WINDOWS_CERTIFICATE_PASSWORD`. CI signs the MSI with Authenticode, verifies the
signature, and removes the temporary PFX before uploading artifacts.
After `signtool` verification, CI reads the certificate embedded in the MSI and
requires SHA-256 fingerprint
`84EFAEE8B51EF463E312FC90D8B86613739961F11B0C6582B472BB3845D21BA4`.

Local packaging after `flutter build windows --release`:

```powershell
dotnet tool install --global wix --version 5.0.2
.github/scripts/package_windows_msi.ps1 -Version 0.0.1
```

The local command creates an unsigned MSI for packaging validation. Public
releases are signed only in CI with a dedicated Windows code-signing certificate
configured outside Git.

The Windows update bridge auto-applies only when the 64-bit per-machine registry
marker at `HKLM\Software\mobilka` identifies this UpgradeCode and the running
executable is inside the marker's exact `InstallLocation`. Portable and unknown
installs are denied. Before handoff, PowerShell requires a valid Authenticode
signature whose leaf certificate SHA-256 fingerprint matches the pinned mobilka
certificate. The fixed `mobilka_update.ps1` script is packaged beside the app
and receives paths as separate `-File` arguments. A detached handoff waits for mobilka to exit,
rechecks the signature, invokes the system `msiexec.exe` without shell-built
arguments, and restarts mobilka only after installation succeeds. The caller
must terminate promptly after `WindowsMsiInstallHandoff.exitRequired`; a failed
or cancelled installation leaves the app closed and requires manual restart.

## AppImage packaging

The Linux release job builds the Flutter bundle and packages it with the pinned
`appimage-builder` version using `.github/appimage/AppImageBuilder.yml`. The
desktop entry uses application ID `com.rslnmzhn.mobilka`, executable `mobilka`,
and the existing Android launcher icon.
