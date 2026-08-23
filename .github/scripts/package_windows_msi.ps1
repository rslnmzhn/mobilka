param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^\d+\.\d+\.\d+$')]
  [string]$Version,

  [string]$BundleDir = 'build/windows/x64/runner/Release',

  [string]$OutputDir = 'build/windows/x64/installer'
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$bundlePath = Join-Path $root $BundleDir
if (-not (Test-Path -LiteralPath $bundlePath -PathType Container)) {
  throw "Windows bundle directory does not exist: $bundlePath. Run flutter build windows --release first."
}
$bundle = (Resolve-Path $bundlePath).Path
$wixSource = Join-Path $root '.github/windows/Package.wxs'
$output = Join-Path $root $OutputDir
$msi = Join-Path $output "mobilka-v$Version-windows-x64.msi"

if (-not (Test-Path -LiteralPath (Join-Path $bundle 'mobilka.exe') -PathType Leaf)) {
  throw "Windows bundle does not contain mobilka.exe: $bundle"
}

$updateScript = Join-Path $root '.github/windows/mobilka_update.ps1'
Copy-Item -LiteralPath $updateScript -Destination (Join-Path $bundle 'mobilka_update.ps1') -Force

if (-not (Get-Command wix -ErrorAction SilentlyContinue)) {
  throw 'WiX CLI is unavailable. Install the pinned wix tool before packaging.'
}

# The installer UI lives in the WiX UI extension; register the pinned version
# on demand so CI and local machines behave identically.
$listedExtensions = & wix extension list -g 2>$null
if (-not ($listedExtensions -match 'WixToolset\.UI\.wixext')) {
  & wix extension add -g WixToolset.UI.wixext/5.0.2
  if ($LASTEXITCODE -ne 0) {
    throw 'Failed to add the pinned WixToolset.UI.wixext extension.'
  }
}

New-Item -ItemType Directory -Force -Path $output | Out-Null
& wix build $wixSource -ext WixToolset.UI.wixext -arch x64 `
  -d "Version=$Version" -d "BundleDir=$bundle" -o $msi
if ($LASTEXITCODE -ne 0) {
  throw "WiX failed with exit code $LASTEXITCODE"
}
if (-not (Test-Path -LiteralPath $msi -PathType Leaf)) {
  throw "MSI was not created: $msi"
}

$msi
