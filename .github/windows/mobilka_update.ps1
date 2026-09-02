param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('Provenance', 'Verify', 'VerifyFile', 'SafeImport', 'Handoff', 'ElevatedInstall', 'RotateLog')]
  [string]$Mode,

  [int]$AppPid,
  [string]$AppPath,
  [string]$UpdatesRoot,
  [string]$Basename,
  [long]$ExpectedSize,
  [string]$ExpectedSha256,
  [string]$IdentityToken,
  [string]$PartialName,
  [string]$HandoffId
)

$ErrorActionPreference = 'Stop'
$expectedFingerprint = '84EFAEE8B51EF463E312FC90D8B86613739961F11B0C6582B472BB3845D21BA4'

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;
public static class MobilkaSecureInstall {
  const uint FILE_READ_ATTRIBUTES = 0x80;
  const uint FILE_SHARE_READ = 1;
  const uint FILE_SHARE_WRITE = 2;
  const uint FILE_SHARE_DELETE = 4;
  const uint OPEN_EXISTING = 3;
  const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
  [StructLayout(LayoutKind.Sequential)]
  struct BY_HANDLE_FILE_INFORMATION {
    public uint FileAttributes;
    public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
    public uint VolumeSerialNumber;
    public uint FileSizeHigh;
    public uint FileSizeLow;
    public uint NumberOfLinks;
    public uint FileIndexHigh;
    public uint FileIndexLow;
  }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern SafeFileHandle CreateFile(string name, uint access, uint share,
    IntPtr security, uint creation, uint flags, IntPtr template);
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern bool GetFileInformationByHandle(
    SafeFileHandle file, out BY_HANDLE_FILE_INFORMATION information);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern uint GetSystemDirectoryW(System.Text.StringBuilder value, uint size);
  [DllImport("shell32.dll")] static extern int SHGetKnownFolderPath(
    [MarshalAs(UnmanagedType.LPStruct)] Guid id, uint flags, IntPtr token, out IntPtr path);
  static string KnownProgramData() {
    IntPtr value; var id = new Guid("62AB5D82-FDC1-4DC3-A9DD-070D1D495D97");
    if (SHGetKnownFolderPath(id, 0, IntPtr.Zero, out value) != 0) throw new IOException("ProgramData unavailable");
    try { return Marshal.PtrToStringUni(value); } finally { Marshal.FreeCoTaskMem(value); }
  }
  static string SystemExecutable(string name) {
    var value = new System.Text.StringBuilder(32768);
    if (GetSystemDirectoryW(value, (uint)value.Capacity) == 0) throw new IOException("System directory unavailable");
    return Path.Combine(value.ToString(), name);
  }
  public static string GetFileIdentity(string path) {
    using (var file = CreateFile(path, FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, IntPtr.Zero,
      OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero)) {
      if (file.IsInvalid) throw new IOException("Source identity unavailable", new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()));
      return GetFileIdentity(file);
    }
  }
  public static string GetFileIdentity(SafeFileHandle file) {
    BY_HANDLE_FILE_INFORMATION info;
    if (!GetFileInformationByHandle(file, out info)) throw new IOException("Source identity unavailable", new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()));
    return String.Format(CultureInfo.InvariantCulture, "{0}:{1}:{2}",
      info.VolumeSerialNumber, info.FileIndexHigh, info.FileIndexLow);
  }
  static DirectorySecurity RestrictedAcl() {
    var acl = new DirectorySecurity(); acl.SetAccessRuleProtection(true, false);
    var admins = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
    var system = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
    acl.SetOwner(admins);
    acl.AddAccessRule(new FileSystemAccessRule(admins, FileSystemRights.FullControl,
      InheritanceFlags.ContainerInherit|InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
    acl.AddAccessRule(new FileSystemAccessRule(system, FileSystemRights.FullControl,
      InheritanceFlags.ContainerInherit|InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
    return acl;
  }
  static void VerifyAcl(string path) {
    var acl = Directory.GetAccessControl(path); if (!acl.AreAccessRulesProtected) throw new UnauthorizedAccessException("ACL inheritance enabled");
    foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier))) {
      var sid = (SecurityIdentifier)rule.IdentityReference;
      if (rule.AccessControlType == AccessControlType.Allow &&
          !sid.IsWellKnown(WellKnownSidType.BuiltinAdministratorsSid) &&
          !sid.IsWellKnown(WellKnownSidType.LocalSystemSid)) throw new UnauthorizedAccessException("Writable protected directory");
    }
  }
  static void EnsureProtectedDirectory(string path) {
    if (Directory.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
      throw new IOException("Protected directory is a reparse point");
    if (!Directory.Exists(path)) Directory.CreateDirectory(path, RestrictedAcl());
    if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
      throw new IOException("Protected directory became a reparse point");
    Directory.SetAccessControl(path, RestrictedAcl()); VerifyAcl(path);
  }
  static void ValidateKnownRoot(string path) {
    if (!Directory.Exists(path) || (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
      throw new IOException("Known ProgramData root is unsafe");
  }
  public static string CreateProtectedCopy(string source, string basename, long expectedSize, string expectedHash, string expectedIdentity) {
    string programData = KnownProgramData(); ValidateKnownRoot(programData);
    string mobilka = Path.Combine(programData, "mobilka"); EnsureProtectedDirectory(mobilka);
    string parent = Path.Combine(mobilka, "updates"); EnsureProtectedDirectory(parent);
    byte[] random = new byte[24]; using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(random);
    string child = Path.Combine(parent, Convert.ToBase64String(random).Replace('/','_').Replace('+','-').TrimEnd('='));
    EnsureProtectedDirectory(child);
    string target = Path.Combine(child, basename);
    using (var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read))
    using (var output = new FileStream(target, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None)) {
      if (GetFileIdentity(input.SafeFileHandle) != expectedIdentity) throw new IOException("Update identity changed");
      input.CopyTo(output); output.Flush(true); output.Position=0;
      if (output.Length != expectedSize) throw new IOException("Protected copy size mismatch");
      using (var hash=SHA256.Create()) if (BitConverter.ToString(hash.ComputeHash(output)).Replace("-","").ToLowerInvariant()!=expectedHash) throw new IOException("Protected copy hash mismatch");
    }
    return target;
  }
  public static string TrustedMsiExec() { return SystemExecutable("msiexec.exe"); }
}
'@

$maxLogBytes = 262144
function Get-LogPath {
  $root = Get-SafeRoot $UpdatesRoot
  $path = Join-Path $root.FullName 'handoff.log'
  if (Test-Path -LiteralPath $path) {
    $item = Get-Item -LiteralPath $path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType) { throw 'Unsafe handoff log.' }
  }
  return $path
}
function Rotate-Log {
  $log = Get-LogPath
  if (Test-Path -LiteralPath $log -PathType Leaf) {
    $backup = "$log.1"
    Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    Move-Item -LiteralPath $log -Destination $backup -Force
  }
}
function Write-SafeLog([string]$Line) {
  try {
    $log = Get-LogPath
    if ((Test-Path -LiteralPath $log -PathType Leaf) -and (Get-Item -LiteralPath $log).Length -ge $maxLogBytes) { Rotate-Log }
    $bounded = if ($Line.Length -gt 256) { $Line.Substring(0, 256) } else { $Line }
    $bounded | Out-File -LiteralPath $log -Append -Encoding utf8
  } catch { }
}
function Get-HexSha256([IO.Stream]$Stream) {
  $hasher = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($hasher.ComputeHash($Stream))).Replace('-','').ToLowerInvariant() } finally { $hasher.Dispose() }
}
function Get-SafeRoot([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    [IO.Directory]::CreateDirectory($Path) | Out-Null
  }
  $item = Get-Item -LiteralPath $Path -Force
  if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'Updates root is not a no-follow directory.'
  }
  $resolved = [IO.Path]::GetFullPath($item.FullName)
  if ($resolved -ine [IO.Path]::GetFullPath($Path)) {
    throw 'Updates root canonical identity changed.'
  }
  return $item
}
function Import-VerifiedFile([string]$Root, [string]$PartName, [string]$Name) {
  if (-not (Test-GeneratedName $Name) -or [IO.Path]::GetFileName($Name) -ne $Name) { throw 'Invalid update basename.' }
  $rootItem = Get-SafeRoot $Root
  if ($PartName -ne "$Name.part") { throw 'Partial basename does not match final basename.' }
  $sourceItem = Get-SafeChild $Root $PartName
  if ($sourceItem.PSIsContainer -or ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe download source.' }
  $destination = Join-Path $rootItem.FullName $Name
  $input = [IO.FileStream]::new($sourceItem.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
  try {
    if ($input.Length -ne $ExpectedSize) { throw 'Update size differs from signed manifest.' }
    $hash = Get-HexSha256 $input
    if ($hash -ne $ExpectedSha256) { throw 'Update hash differs from signed manifest.' }
  } finally { $input.Dispose() }
  [IO.File]::Move($sourceItem.FullName, $destination)
  return Get-VerifiedFile $Root $Name
}
function Test-GeneratedName([string]$Name) {
  return $Name -match '^mobilka-\d+\.\d+\.\d+-(android|windows)-[A-Za-z0-9_-]+-[0-9a-f]+\.(apk|msi)(\.part)?$'
}
function Get-SafeChild([string]$Root, [string]$Name) {
  if (-not (Test-GeneratedName $Name) -or [IO.Path]::GetFileName($Name) -ne $Name) { throw 'Invalid update basename.' }
  $rootItem = Get-SafeRoot $Root
  $child = Get-Item -LiteralPath (Join-Path $rootItem.FullName $Name) -Force
  if ($child.PSIsContainer -or ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
      $child.Directory.FullName -ine $rootItem.FullName) { throw 'Unsafe update child.' }
  if ([IO.Path]::GetFullPath($child.FullName) -ine (Join-Path $rootItem.FullName $Name)) {
    throw 'Update child canonical identity changed.'
  }
  return $child
}
function Get-VerifiedFile([string]$Root, [string]$Name) {
  $item = Get-SafeChild $Root $Name
  $stream = [IO.File]::Open($item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  try {
    if ($stream.Length -ne $ExpectedSize) { throw 'Update size differs from signed manifest.' }
    $hash = Get-HexSha256 $stream
  } finally { $stream.Dispose() }
  if ($hash -ne $ExpectedSha256) { throw 'Update hash differs from signed manifest.' }
  return [pscustomobject]@{ Item=$item; Hash=$hash; Identity=($item.Length.ToString()+'|'+$item.LastWriteTimeUtc.Ticks.ToString()) }
}
function Get-VerifiedMsi([string]$Root, [string]$Name, [string]$ExpectedIdentity) {
  if ([string]::IsNullOrWhiteSpace($ExpectedIdentity)) { throw 'Expected MSI identity is required.' }
  $verified = Get-VerifiedFile $Root $Name
  $item = $verified.Item
  if ($item.Extension -ine '.msi') {
    throw 'The update is not an MSI file.'
  }
  $stream = [IO.File]::Open($item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  try {
    if ([MobilkaSecureInstall]::GetFileIdentity($stream.SafeFileHandle) -cne $ExpectedIdentity) { throw 'Update identity changed.' }
    if ($stream.Length -ne $ExpectedSize) { throw 'Update size differs from signed manifest.' }
    if ((Get-HexSha256 $stream) -cne $ExpectedSha256) { throw 'Update hash differs from signed manifest.' }
    $signature = Get-AuthenticodeSignature -LiteralPath $item.FullName
    if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid) { throw 'The MSI Authenticode signature is invalid.' }
    $certificate2 = $signature.SignerCertificate
    $fingerprint = $certificate2.GetCertHashString(
      [System.Security.Cryptography.HashAlgorithmName]::SHA256
    )
    if ($fingerprint -ne $expectedFingerprint) {
      throw 'The MSI signer certificate is not trusted by mobilka.'
    }
    return $item.FullName
  } finally { $stream.Dispose() }
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
    $verifiedPath = Get-VerifiedMsi $UpdatesRoot $Basename $IdentityToken
    [pscustomobject]@{ Status = 'Valid'; Basename = [IO.Path]::GetFileName($verifiedPath) } |
      ConvertTo-Json -Compress
  }
  'VerifyFile' {
    $verified = Get-VerifiedFile $UpdatesRoot $Basename
    if ($IdentityToken -and $verified.Identity -ne $IdentityToken) { throw 'Update identity changed.' }
    [pscustomobject]@{ basename=$Basename; size=$ExpectedSize; sha256=$verified.Hash; identityToken=$verified.Identity } | ConvertTo-Json -Compress
  }
  'SafeImport' {
    $verified = Import-VerifiedFile $UpdatesRoot $PartialName $Basename
    [pscustomobject]@{ basename=$Basename; size=$ExpectedSize; sha256=$verified.Hash; identityToken=$verified.Identity } | ConvertTo-Json -Compress
  }
  'RotateLog' { Rotate-Log }
  'Handoff' {
    Write-SafeLog "handoff started basename=$Basename"
    try {
      Wait-Process -Id $AppPid -ErrorAction SilentlyContinue
      Get-VerifiedMsi $UpdatesRoot $Basename $IdentityToken | Out-Null
      $id = [Guid]::NewGuid().ToString('N')
      $system = [MobilkaSecureInstall]::TrustedMsiExec()
      $powershell = Join-Path ([IO.Path]::GetDirectoryName($system)) 'WindowsPowerShell\v1.0\powershell.exe'
      $arguments = @('-NoLogo','-NoProfile','-NonInteractive','-File',"`"$PSCommandPath`"",'-Mode','ElevatedInstall','-UpdatesRoot',"`"$UpdatesRoot`"",'-Basename',$Basename,'-ExpectedSize',$ExpectedSize,'-ExpectedSha256',$ExpectedSha256,'-IdentityToken',$IdentityToken,'-HandoffId',$id)
      $elevated = Start-Process -FilePath $powershell -ArgumentList $arguments -Verb RunAs -Wait -PassThru
      Write-SafeLog "elevated exit=$($elevated.ExitCode)"
      if ($elevated.ExitCode -ne 0) {
        Write-SafeLog 'elevated install failed'
        exit $elevated.ExitCode
      }
    } catch {
      Write-SafeLog 'handoff failed'
      Start-Process -FilePath $AppPath
      exit 1603
    }
    Start-Process -FilePath $AppPath
  }
  'ElevatedInstall' {
    if ($HandoffId -notmatch '^[0-9a-f]{32}$') { throw 'Invalid handoff identity.' }
    $source = Get-VerifiedMsi $UpdatesRoot $Basename $IdentityToken
    $copy = [MobilkaSecureInstall]::CreateProtectedCopy($source, $Basename, $ExpectedSize, $ExpectedSha256, $IdentityToken)
    try {
      $signature = Get-AuthenticodeSignature -LiteralPath $copy
      if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or $signature.SignerCertificate.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256) -ne $expectedFingerprint) { throw 'Protected copy signature mismatch.' }
      $installer = Start-Process -FilePath ([MobilkaSecureInstall]::TrustedMsiExec()) -ArgumentList @('/i', "`"$copy`"", '/passive', '/norestart', 'REBOOT=ReallySuppress') -Wait -PassThru
      exit $installer.ExitCode
    } finally {
      Remove-Item -LiteralPath $copy -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath ([IO.Path]::GetDirectoryName($copy)) -Force -ErrorAction SilentlyContinue
    }
  }
}
