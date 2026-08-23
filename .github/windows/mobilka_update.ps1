param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('Provenance', 'Verify', 'Handoff')]
  [string]$Mode,

  [string]$MsiPath,
  [int]$AppPid,
  [string]$AppPath,
  [string]$MsiExecPath
)

$ErrorActionPreference = 'Stop'
$expectedFingerprint = '84EFAEE8B51EF463E312FC90D8B86613739961F11B0C6582B472BB3845D21BA4'

function Get-VerifiedMsi([string]$Path) {
  $resolved = Resolve-Path -LiteralPath $Path
  $item = Get-Item -LiteralPath $resolved.ProviderPath
  if ($item.PSIsContainer -or $item.Extension -ine '.msi') {
    throw 'The update is not an MSI file.'
  }

  $signature = Get-AuthenticodeSignature -LiteralPath $resolved.ProviderPath
  if ($null -eq $signature.SignerCertificate) {
    throw 'The MSI has no Authenticode signer.'
  }
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $fingerprint = ([BitConverter]::ToString(
      $sha.ComputeHash($signature.SignerCertificate.RawData)
    )).Replace('-', '')
  } finally {
    $sha.Dispose()
  }
  if ($fingerprint -ne $expectedFingerprint) {
    throw 'The MSI signer certificate is not trusted by mobilka.'
  }
  if ($signature.Status -notin @('Valid', 'UnknownError')) {
    throw "The MSI Authenticode signature status is $($signature.Status)."
  }
  return $resolved.ProviderPath
}

switch ($Mode) {
  'Provenance' {
    $key = 'Registry::HKEY_LOCAL_MACHINE\Software\mobilka'
    if (-not (Test-Path -LiteralPath $key -PathType Container)) { exit 3 }
    $marker = Get-ItemProperty -LiteralPath $key
    [pscustomobject]@{
      InstallType = [string]$marker.InstallType
      InstallLocation = [string]$marker.InstallLocation
      UpgradeCode = [string]$marker.UpgradeCode
    } | ConvertTo-Json -Compress
  }
  'Verify' {
    $verifiedPath = Get-VerifiedMsi $MsiPath
    [pscustomobject]@{ Status = 'Valid'; Path = $verifiedPath } |
      ConvertTo-Json -Compress
  }
  'Handoff' {
    Wait-Process -Id $AppPid -ErrorAction SilentlyContinue
    # Reverify after shutdown to close the preflight-to-install replacement gap.
    $verifiedPath = Get-VerifiedMsi $MsiPath
    try {
      # perMachine installs (including the nested removal of a previously
      # managed product) require an elevated engine; a non-elevated msiexec
      # fails with error 1730/1603.
      $installer = Start-Process -FilePath $MsiExecPath `
        -ArgumentList @('/i', "`"$verifiedPath`"", '/passive', '/norestart', 'REBOOT=ReallySuppress') `
        -Verb RunAs -Wait -PassThru
      $exitCode = $installer.ExitCode
    } catch {
      Start-Process -FilePath $AppPath
      exit 1602
    }
    if ($exitCode -ne 0 -and $exitCode -ne 3010) {
      exit $exitCode
    }
    Start-Process -FilePath $AppPath
  }
}
