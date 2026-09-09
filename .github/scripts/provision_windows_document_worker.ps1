$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$documents = Join-Path $root 'native/documents'
$lock = Get-Content -Raw -LiteralPath (Join-Path $documents 'dependency-versions.json') | ConvertFrom-Json
$output = [IO.Path]::GetFullPath((Join-Path $root 'build/windows-document-provision'))
if ([string]::IsNullOrWhiteSpace($env:VSCMD_ARG_TGT_ARCH)) {
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
  if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { throw 'Visual Studio discovery is unavailable' }
  $installation = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
  $devcmd = Join-Path $installation 'Common7/Tools/VsDevCmd.bat'
  if (-not (Test-Path -LiteralPath $devcmd -PathType Leaf)) { throw 'MSVC developer environment is unavailable' }
  & cmd.exe /d /s /c "`"$devcmd`" -arch=x64 -host_arch=x64 >nul && set" | ForEach-Object {
    $parts = $_ -split '=', 2
    if ($parts.Length -eq 2) { [Environment]::SetEnvironmentVariable($parts[0], $parts[1]) }
  }
}
$sources = Join-Path $output 'sources'; $downloads = Join-Path $output 'downloads'
$install = Join-Path $output 'install'; $runtime = Join-Path $output 'runtime'

function Assert-NoReparseAncestors([string]$Path) {
  $current = Get-Item -Force -LiteralPath ([IO.Path]::GetFullPath($Path))
  while ($null -ne $current) {
    if ($current.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
      throw 'Provisioning ancestry must not contain a reparse point'
    }
    $current = $current.Parent
  }
}

function Remove-OwnedDirectory([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return }
  Assert-NoReparseAncestors (Split-Path -Parent $Path)
  $item = Get-Item -Force -LiteralPath $Path
  if (-not $item.PSIsContainer -or $item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
    throw 'Provisioning cache path is not an operation-owned ordinary directory'
  }
  Remove-Item -Recurse -Force -LiteralPath $Path
}

function Assert-OrdinaryTree([string]$Root) {
  Assert-NoReparseAncestors $Root
  foreach ($item in Get-ChildItem -Force -Recurse -LiteralPath $Root) {
    if ($item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
      throw 'Extracted tree contains a reparse point'
    }
    $full = [IO.Path]::GetFullPath($item.FullName)
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
      throw 'Extracted member escaped the operation-owned directory'
    }
  }
}

$outputParent = Split-Path -Parent $output
if (-not (Test-Path -LiteralPath $outputParent)) {
  New-Item -ItemType Directory -Path $outputParent | Out-Null
}
Assert-NoReparseAncestors $outputParent
Remove-OwnedDirectory $output
New-Item -ItemType Directory -Path $output | Out-Null
New-Item -ItemType Directory -Path $sources,$downloads,$install,$runtime | Out-Null
Assert-OrdinaryTree $output

function Expand-CheckedTar([string]$Archive, [string]$Destination) {
  $names = @(& tar -tzf $Archive)
  $verbose = @(& tar -tvzf $Archive)
  if ($LASTEXITCODE -ne 0 -or $names.Count -eq 0 -or $verbose.Count -ne $names.Count) {
    throw 'Archive listing failed'
  }
  $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  for ($index = 0; $index -lt $names.Count; $index++) {
    $name = [string]$names[$index]
    $type = ([string]$verbose[$index])[0]
    if ($type -ne '-' -and $type -ne 'd') { throw 'Archive contains a link or special entry' }
    $normalized = $name.TrimEnd('/')
    $segments = $normalized.Split('/')
    if ([string]::IsNullOrWhiteSpace($normalized) -or
        $name.StartsWith('/') -or $name.StartsWith('\') -or $name.Contains('\') -or
        $name.Contains(':') -or $segments -contains '' -or $segments -contains '.' -or
        $segments -contains '..' -or -not $seen.Add($normalized)) {
      throw 'Archive contains an unsafe or duplicate member path'
    }
  }
  Remove-OwnedDirectory $Destination
  New-Item -ItemType Directory -Path $Destination | Out-Null
  Assert-NoReparseAncestors $Destination
  & tar -xzf $Archive --strip-components=1 -C $Destination
  if ($LASTEXITCODE -ne 0) { throw 'Archive extraction failed' }
  Assert-OrdinaryTree $Destination
}

function Fetch([string]$Name, [string]$Url, [string]$Sha, [switch]$Raw) {
  $archive = Join-Path $downloads "$Name.archive"
  $partial = "$archive.part"
  & curl.exe --fail --location --proto '=https' --proto-redir '=https' `
    --max-redirs 3 --retry 3 --retry-all-errors --connect-timeout 20 `
    --output $partial -- $Url
  if ($LASTEXITCODE -ne 0 -or
      (Get-FileHash -Algorithm SHA256 -LiteralPath $partial).Hash -ne $Sha) {
    Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $partial
    throw "$Name download or digest verification failed"
  }
  Move-Item -LiteralPath $partial -Destination $archive
  if ((Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash -ne $Sha) {
    throw "$Name pinned digest changed before extraction"
  }
  if ($Raw) { return $archive }
  $destination = Join-Path $sources $Name
  Expand-CheckedTar $archive $destination
  return $destination
}
$sourcePaths = @{}
foreach ($name in 'ZLIB','PNG','JPEG','LEPTONICA','TESSERACT') {
  $entry = $lock.sources.$name
  $sourcePaths[$name] = Fetch $name $entry.url $entry.sha256
}
$pdf = $lock.pdfium.assets.'windows-x64'
$pdfSource = Fetch 'PDFIUM' $pdf.url $pdf.sha256
$ninja = (Get-Command ninja -ErrorAction SilentlyContinue).Source
if ([string]::IsNullOrWhiteSpace($ninja)) {
  $ninja = Get-ChildItem -LiteralPath (Join-Path ${env:ProgramFiles} 'Microsoft Visual Studio') `
    -Filter ninja.exe -Recurse -File -ErrorAction Stop |
    Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if ([string]::IsNullOrWhiteSpace($ninja)) { throw 'Ninja is required' }
$build = Join-Path $output 'build'
$cmakePath = { param($value) ([IO.Path]::GetFullPath($value)).Replace('\', '/') }
cmake -DDOCUMENTS_SOURCES_REVIEWED=ON -DDOCUMENTS_TARGET=windows-x64 `
  "-DDOCUMENTS_BUILD_ROOT=$(& $cmakePath $build)" `
  "-DDOCUMENTS_INSTALL_PREFIX=$(& $cmakePath $install)" "-DDOCUMENTS_NINJA=$(& $cmakePath $ninja)" `
  "-DDOCUMENTS_ZLIB_SOURCE=$(& $cmakePath $sourcePaths.ZLIB)" `
  "-DDOCUMENTS_PNG_SOURCE=$(& $cmakePath $sourcePaths.PNG)" `
  "-DDOCUMENTS_JPEG_SOURCE=$(& $cmakePath $sourcePaths.JPEG)" `
  "-DDOCUMENTS_LEPTONICA_SOURCE=$(& $cmakePath $sourcePaths.LEPTONICA)" `
  "-DDOCUMENTS_TESSERACT_SOURCE=$(& $cmakePath $sourcePaths.TESSERACT)" `
  -P (Join-Path $documents 'build-dependencies.cmake')
if ($LASTEXITCODE) { throw 'Document dependency build failed' }
$eng = Fetch 'ENG_DATA' $lock.tessdata_fast.eng.url $lock.tessdata_fast.eng.sha256 -Raw
$rus = Fetch 'RUS_DATA' $lock.tessdata_fast.rus.url $lock.tessdata_fast.rus.sha256 -Raw
Copy-Item (Join-Path $pdfSource 'pdfium.dll') $runtime
Copy-Item $eng (Join-Path $runtime 'eng.traineddata')
Copy-Item $rus (Join-Path $runtime 'rus.traineddata')
$licenseFiles = [ordered]@{
  ZLIB = Join-Path $sourcePaths.ZLIB 'LICENSE'
  PNG = Join-Path $sourcePaths.PNG 'LICENSE'
  JPEG = Join-Path $sourcePaths.JPEG 'LICENSE.md'
  LEPTONICA = Join-Path $sourcePaths.LEPTONICA 'leptonica-license.txt'
  TESSERACT = Join-Path $sourcePaths.TESSERACT 'LICENSE'
  TESSDATA_FAST = Join-Path $sourcePaths.TESSERACT 'LICENSE'
}
$noticeParts = @()
foreach ($dependency in $licenseFiles.Keys) {
  $license = $licenseFiles[$dependency]
  if (-not (Test-Path -LiteralPath $license -PathType Leaf) -or (Get-Item -LiteralPath $license).Length -eq 0) {
    throw "Complete license file is absent for $dependency"
  }
  $noticeParts += "===== $dependency LICENSE =====`n" +
    (Get-Content -Raw -LiteralPath $license).TrimEnd()
}
$noticeText = ($noticeParts -join "`n`n") + "`n"
$pdfNotices = @(Get-ChildItem -LiteralPath $pdfSource -File -Filter '*.txt' |
  Sort-Object Name)
if ($pdfNotices.Count -eq 0 -or -not ($pdfNotices.Name -contains 'pdfium.txt')) {
  throw 'Complete license file is absent for PDFIUM'
}
$pdfNotice = (($pdfNotices | ForEach-Object {
  "===== PDFIUM/$($_.Name) =====`n" +
    (Get-Content -Raw -LiteralPath $_.FullName).TrimEnd()
}) -join "`n`n") + "`n"
$noticeText += $pdfNotice
[IO.File]::WriteAllText((Join-Path $runtime 'document-worker-notices.txt'),
  $noticeText, [Text.UTF8Encoding]::new($false))
$provision = @"
set(DOCUMENTS_PDFIUM_LIBRARY "$($pdfSource.Replace('\','/'))/pdfium.dll.lib")
set(DOCUMENTS_PDFIUM_INCLUDE "$($pdfSource.Replace('\','/'))")
set(DOCUMENTS_TESSERACT_LIBRARY "$($install.Replace('\','/'))/lib/tesseract55.lib")
set(DOCUMENTS_LEPTONICA_LIBRARY "$($install.Replace('\','/'))/lib/leptonica-1.85.0.lib")
set(DOCUMENTS_PNG_LIBRARY "$($install.Replace('\','/'))/lib/libpng16_static.lib")
set(DOCUMENTS_JPEG_LIBRARY "$($install.Replace('\','/'))/lib/jpeg-static.lib")
set(DOCUMENTS_ZLIB_LIBRARY "$($install.Replace('\','/'))/lib/zlibstatic.lib")
set(DOCUMENTS_TESSERACT_INCLUDE "$($install.Replace('\','/'))/include")
set(DOCUMENTS_LEPTONICA_INCLUDE "$($install.Replace('\','/'))/include")
set(DOCUMENTS_ENG_DATA "$($runtime.Replace('\','/'))/eng.traineddata")
set(DOCUMENTS_RUS_DATA "$($runtime.Replace('\','/'))/rus.traineddata")
set(DOCUMENTS_PROVISIONING_MANIFEST "$($documents.Replace('\','/'))/dependency-versions.json")
set(DOCUMENTS_LICENSES "$($runtime.Replace('\','/'))/document-worker-notices.txt")
set(DOCUMENTS_RUNTIME_FILES "$($runtime.Replace('\','/'))/pdfium.dll;$($runtime.Replace('\','/'))/eng.traineddata;$($runtime.Replace('\','/'))/rus.traineddata;$($runtime.Replace('\','/'))/document-worker-notices.txt")
"@
$verified = @('PDFIUM','TESSERACT','LEPTONICA','PNG','JPEG','ZLIB')
foreach ($name in $verified) {
  $pattern = 'set\(DOCUMENTS_{0}_LIBRARY "([^"]+)"\)' -f $name
  $match = [regex]::Match($provision, $pattern)
  if (-not $match.Success -or -not (Test-Path -LiteralPath $match.Groups[1].Value -PathType Leaf)) {
    throw "Missing built $name library"
  }
  $digest = (Get-FileHash -Algorithm SHA256 -LiteralPath $match.Groups[1].Value).Hash.ToLower()
  $provision += ('{0}set(DOCUMENTS_{1}_LIBRARY_SHA256 "{2}")' -f "`n", $name, $digest)
}
foreach ($entry in @{
  DOCUMENTS_ENG_DATA=(Join-Path $runtime 'eng.traineddata');
  DOCUMENTS_RUS_DATA=(Join-Path $runtime 'rus.traineddata');
  DOCUMENTS_PROVISIONING_MANIFEST=(Join-Path $documents 'dependency-versions.json');
  DOCUMENTS_LICENSES=(Join-Path $runtime 'document-worker-notices.txt')
}.GetEnumerator()) {
  $digest = (Get-FileHash -Algorithm SHA256 -LiteralPath $entry.Value).Hash.ToLower()
  $provision += ('{0}set({1}_SHA256 "{2}")' -f "`n", $entry.Key, $digest)
}
Set-Content -NoNewline -Encoding UTF8 -LiteralPath (Join-Path $output 'provision.cmake') -Value $provision
"DOCUMENTS_PROVISION_ROOT=$output" | Set-Content -NoNewline -Encoding ASCII -LiteralPath (Join-Path $output 'flutter-build.env')
