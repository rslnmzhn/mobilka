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

$log = Join-Path $env:TEMP 'mobilka-update-handoff.log'
"=== invocation $(Get-Date -Format o) mode=$Mode ===" | Out-File $log -Append
function Get-VerifiedMsi([string]$Path) {
  $resolved = Resolve-Path -LiteralPath $Path
  $item = Get-Item -LiteralPath $resolved.ProviderPath
  if ($item.PSIsContainer -or $item.Extension -ine '.msi') {
    throw 'The update is not an MSI file.'
  }

  # Pure .NET on purpose: PSModulePath in the detached handoff session can be
  # stripped or mixed (5.1 + pwsh), which breaks autoloading of the Security
  # cmdlets. X509Certificate needs no PowerShell module.
  $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate]::CreateFromSignedFile(
    $resolved.ProviderPath
  )
  if ($null -eq $certificate) {
    throw 'The MSI has no Authenticode signer.'
  }
  $certificate2 = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
    $certificate
  )
  $fingerprint = $certificate2.GetCertHashString(
    [System.Security.Cryptography.HashAlgorithmName]::SHA256
  )
  if ($fingerprint -ne $expectedFingerprint) {
    throw 'The MSI signer certificate is not trusted by mobilka.'
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
    "=== handoff $(Get-Date -Format o) ===" | Out-File $log -Append
    try {
      Wait-Process -Id $AppPid -ErrorAction SilentlyContinue
      # Reverify after shutdown to close the preflight-to-install replacement gap.
      $verifiedPath = Get-VerifiedMsi $MsiPath
      "verified=$verifiedPath" | Out-File $log -Append
    } catch {
      $_ | Out-File $log -Append
      Start-Process -FilePath $AppPath
      exit 1603
    }
    try {
      # perMachine installs (including the nested removal of a previously
      # managed product) require an elevated engine; a non-elevated msiexec
      # fails with error 1730/1603.
      $installer = Start-Process -FilePath $MsiExecPath `
        -ArgumentList @('/i', "`"$verifiedPath`"", '/passive', '/norestart', 'REBOOT=ReallySuppress') `
        -Verb RunAs -Wait -PassThru
      $exitCode = $installer.ExitCode
      "msiexec exit=$exitCode" | Out-File $log -Append
    } catch {
      $_ | Out-File $log -Append
      Start-Process -FilePath $AppPath
      exit 1602
    }
    if ($exitCode -ne 0 -and $exitCode -ne 3010) {
      Start-Process -FilePath $AppPath
      exit $exitCode
    }
    Start-Process -FilePath $AppPath
  }
}
