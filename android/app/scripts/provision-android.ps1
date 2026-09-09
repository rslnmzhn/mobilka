param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$AndroidNdk
)

$ErrorActionPreference = 'Stop'
$appRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$workspaceRoot = [IO.Path]::GetFullPath((Join-Path $appRoot '../..'))
$documentsRoot = Join-Path $workspaceRoot 'native/documents'
$manifestPath = Join-Path $documentsRoot 'dependency-versions.json'
$outputRoot = Join-Path $appRoot '.cxx/provision'
$assetRoot = Join-Path $workspaceRoot 'build/app/generated/document-assets/documents'
$work = Join-Path $outputRoot '_work'
$parallel = [Math]::Max(1, [Math]::Min(4, [Environment]::ProcessorCount))
$ninja = (Get-Command ninja -ErrorAction SilentlyContinue).Source
if ([string]::IsNullOrWhiteSpace($ninja)) {
    $sdkRoot = Split-Path -Parent (Split-Path -Parent $AndroidNdk)
    $cmakeRoot = Join-Path $sdkRoot 'cmake'
    $ninja = Get-ChildItem -LiteralPath $cmakeRoot -Filter ninja.exe -Recurse -File |
        Sort-Object FullName -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if ([string]::IsNullOrWhiteSpace($ninja) -or -not (Test-Path -LiteralPath $ninja -PathType Leaf)) {
    throw 'Ninja is required for document dependency provisioning'
}

function Assert-NoReparseAncestors([string]$Path) {
    $current = Get-Item -Force -LiteralPath ([IO.Path]::GetFullPath($Path))
    while ($null -ne $current) {
        if ($current.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
            throw 'Provisioning ancestry must not contain a reparse point'
        }
        $current = $current.Parent
    }
}

function Assert-OrdinaryPath([string]$Root, [string]$Path) {
    $canonicalRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar) +
        [IO.Path]::DirectorySeparatorChar
    $canonicalPath = [IO.Path]::GetFullPath($Path)
    if (-not ($canonicalPath + [IO.Path]::DirectorySeparatorChar).StartsWith(
            $canonicalRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Provisioning path escapes its fixed application directory'
    }
    $current = [IO.Path]::GetFullPath($Root)
    if ((Get-Item -Force -LiteralPath $current).Attributes.HasFlag(
            [IO.FileAttributes]::ReparsePoint)) {
        throw 'Provisioning root must not be a reparse point'
    }
    $relative = [IO.Path]::GetRelativePath($current, $canonicalPath)
    foreach ($part in $relative.Split([IO.Path]::DirectorySeparatorChar,
            [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $part
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -Force -LiteralPath $current).Attributes.HasFlag(
                    [IO.FileAttributes]::ReparsePoint)) {
                throw 'Provisioning path contains a reparse point'
            }
        }
    }
}

Assert-NoReparseAncestors $appRoot
Assert-OrdinaryPath $appRoot $outputRoot
Assert-OrdinaryPath $workspaceRoot $assetRoot
New-Item -ItemType Directory -Force -Path $work, $assetRoot | Out-Null
Assert-OrdinaryPath $appRoot $outputRoot
Assert-OrdinaryPath $workspaceRoot $assetRoot

$lock = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json

function Acquire([string]$Name, [string]$Url, [string]$Hash) {
    $uri = [Uri]$Url
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or
            -not [string]::IsNullOrEmpty($uri.UserInfo)) {
        throw "Manifest URL is not credential-free HTTPS: $Name"
    }
    if ($Hash -notmatch '^[0-9a-f]{64}$') {
        throw "Pinned SHA-256 is invalid: $Name"
    }
    $target = Join-Path $work $Name
    Assert-OrdinaryPath $outputRoot $target
    if (-not (Test-Path -LiteralPath $target)) {
        Write-Host "NETWORK: acquiring pinned dependency $Name (HTTPS, at most three redirects)"
        & curl.exe '--fail' '--silent' '--show-error' '--location' '--max-redirs' '3' `
            '--proto' '=https' '--proto-redir' '=https' '--output' $target '--url' $uri.AbsoluteUri
        if ($LASTEXITCODE -ne 0) { throw "Pinned download failed: $Name" }
    }
    Assert-OrdinaryPath $outputRoot $target
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
    if ($actual -ne $Hash) {
        Remove-Item -Force -LiteralPath $target
        throw "SHA-256 mismatch: $Name"
    }
    return $target
}

function Expand-CheckedTar([string]$Archive, [string]$Destination) {
    $names = @(& tar -tzf $Archive)
    if ($LASTEXITCODE -ne 0 -or $names.Count -eq 0) { throw 'Archive listing failed' }
    $verbose = @(& tar -tvzf $Archive)
    if ($LASTEXITCODE -ne 0 -or $verbose.Count -ne $names.Count) {
        throw 'Archive type listing failed'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    for ($index = 0; $index -lt $names.Count; $index++) {
        $name = [string]$names[$index]
        $type = ([string]$verbose[$index])[0]
        if ($type -ne '-' -and $type -ne 'd') { throw 'Archive contains a link or special entry' }
        if ([string]::IsNullOrWhiteSpace($name) -or $name -eq '.' -or $name -eq './' -or
                $name.StartsWith('/') -or $name.StartsWith('\') -or
                $name.Contains('\') -or $name -match '^[A-Za-z]:' -or
                $name.Split('/') -contains '..' -or -not $seen.Add($name.TrimEnd('/'))) {
            throw 'Archive contains an unsafe or duplicate path'
        }
    }
    Assert-OrdinaryPath $outputRoot $Destination
    New-Item -ItemType Directory -Path $Destination | Out-Null
    & tar -xzf $Archive --strip-components=1 -C $Destination
    if ($LASTEXITCODE -ne 0) { throw 'Archive extraction failed' }
    Assert-OrdinaryPath $outputRoot $Destination
}

$sources = @{}
foreach ($name in @('ZLIB', 'PNG', 'JPEG', 'LEPTONICA', 'TESSERACT')) {
    $entry = $lock.sources.$name
    $archive = Acquire "$($name.ToLowerInvariant()).tar.gz" $entry.url $entry.sha256
    $tree = Join-Path $work $name.ToLowerInvariant()
    if (-not (Test-Path -LiteralPath $tree)) { Expand-CheckedTar $archive $tree }
    $sources[$name] = $tree
}

$licenseFiles = [ordered]@{
    ZLIB = Join-Path $sources.ZLIB 'LICENSE'
    PNG = Join-Path $sources.PNG 'LICENSE'
    JPEG = Join-Path $sources.JPEG 'LICENSE.md'
    LEPTONICA = Join-Path $sources.LEPTONICA 'leptonica-license.txt'
    TESSERACT = Join-Path $sources.TESSERACT 'LICENSE'
    TESSDATA_FAST = Join-Path $sources.TESSERACT 'LICENSE'
}
$noticeParts = @()
foreach ($dependency in $licenseFiles.Keys) {
    $license = $licenseFiles[$dependency]
    if (-not (Test-Path -LiteralPath $license -PathType Leaf) -or
            (Get-Item -LiteralPath $license).Length -eq 0) {
        throw "Complete license file is absent for $dependency"
    }
    $noticeParts += "===== $dependency LICENSE =====`n" +
        (Get-Content -Raw -LiteralPath $license).TrimEnd()
}
$expectedNotice = $null

$dataRoot = Join-Path $outputRoot 'assets'
New-Item -ItemType Directory -Force -Path $dataRoot | Out-Null
foreach ($language in @('eng', 'rus')) {
    $entry = $lock.tessdata_fast.$language
    $data = Acquire "$language.traineddata" $entry.url $entry.sha256
    Copy-Item -Force -LiteralPath $data -Destination (Join-Path $assetRoot "$language.traineddata")
    Copy-Item -Force -LiteralPath $data -Destination (Join-Path $dataRoot "$language.traineddata")
}

$abis = [ordered]@{
    'armeabi-v7a' = 'android-armeabi-v7a'
    'arm64-v8a' = 'android-arm64-v8a'
    'x86_64' = 'android-x86_64'
}
foreach ($abi in $abis.Keys) {
    Write-Host "[documents] provisioning $abi with $parallel parallel build jobs"
    $pdfEntry = $lock.pdfium.assets.($abis[$abi])
    $pdfArchive = Acquire "pdfium-$abi.tgz" $pdfEntry.url $pdfEntry.sha256
    $pdfRoot = Join-Path $work "pdfium-$abi"
    if (-not (Test-Path -LiteralPath $pdfRoot)) { Expand-CheckedTar $pdfArchive $pdfRoot }
    $pdfLicense = Join-Path $pdfRoot 'LICENSE'
    if (-not (Test-Path -LiteralPath $pdfLicense -PathType Leaf) -or
            (Get-Item -LiteralPath $pdfLicense).Length -eq 0) {
        throw 'Complete license file is absent for PDFIUM'
    }
    $root = Join-Path $outputRoot $abi
    $install = Join-Path $root 'install'
    New-Item -ItemType Directory -Force -Path $root, $install | Out-Null
    Assert-OrdinaryPath $outputRoot $root
    & cmake '-DDOCUMENTS_SOURCES_REVIEWED=ON' '-DDOCUMENTS_TARGET=android' `
        "-DDOCUMENTS_NINJA=$ninja" `
        "-DDOCUMENTS_NDK=$AndroidNdk" "-DDOCUMENTS_ABI=$abi" `
        "-DDOCUMENTS_PARALLEL=$parallel" `
        "-DDOCUMENTS_BUILD_ROOT=$(Join-Path $root 'build')" `
        "-DDOCUMENTS_INSTALL_PREFIX=$install" `
        "-DDOCUMENTS_ZLIB_SOURCE=$($sources.ZLIB)" "-DDOCUMENTS_PNG_SOURCE=$($sources.PNG)" `
        "-DDOCUMENTS_JPEG_SOURCE=$($sources.JPEG)" `
        "-DDOCUMENTS_LEPTONICA_SOURCE=$($sources.LEPTONICA)" `
        "-DDOCUMENTS_TESSERACT_SOURCE=$($sources.TESSERACT)" `
        -P (Join-Path $documentsRoot 'build-dependencies.cmake')
    if ($LASTEXITCODE -ne 0) { throw "Native dependency build failed for $abi" }

    $pdfLibrary = @(Get-ChildItem -LiteralPath $pdfRoot -Recurse -File -Filter 'libpdfium.so')
    $pdfHeader = @(Get-ChildItem -LiteralPath $pdfRoot -Recurse -File -Filter 'fpdfview.h')
    if ($pdfLibrary.Count -ne 1 -or $pdfHeader.Count -ne 1) {
        throw "Pinned PDFium archive has an unexpected layout for $abi"
    }
    $pdfInclude = $pdfHeader[0].Directory.FullName
    Copy-Item -Force -LiteralPath $pdfLibrary[0].FullName `
        -Destination (Join-Path $root 'libpdfium.so')
    $libraries = [ordered]@{
        PDFIUM = $pdfLibrary[0].FullName
        TESSERACT = Join-Path $install 'lib/libtesseract.a'
        LEPTONICA = (@(Get-ChildItem -LiteralPath (Join-Path $install 'lib') -File -Filter '*lept*.a'))[0].FullName
        PNG = (@(Get-ChildItem -LiteralPath (Join-Path $install 'lib') -File -Filter '*png*.a'))[0].FullName
        JPEG = (@(Get-ChildItem -LiteralPath (Join-Path $install 'lib') -File -Filter '*jpeg*.a'))[0].FullName
        ZLIB = (@(Get-ChildItem -LiteralPath (Join-Path $install 'lib') -File -Filter '*z*.a'))[0].FullName
    }
    foreach ($library in $libraries.Values) {
        if (-not (Test-Path -LiteralPath $library -PathType Leaf)) {
            throw "Expected native library is absent for $abi"
        }
        Assert-OrdinaryPath $outputRoot $library
    }

    $identity = Join-Path $root 'provisioning-manifest.txt'
    $notices = Join-Path $root 'LICENSES.txt'
    $identityLines = @(
        "dependency-lock-sha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash.ToLowerInvariant())",
        "abi=$abi"
    )
    foreach ($name in $libraries.Keys) {
        $identityLines += "$name=$((Get-FileHash -Algorithm SHA256 -LiteralPath $libraries[$name]).Hash.ToLowerInvariant())"
    }
    $configuration += "set(DOCUMENTS_PDFIUM_RUNTIME `"$($libraries.PDFIUM.Replace('\', '/'))`")"
    Set-Content -LiteralPath $identity -Value $identityLines -Encoding utf8NoBOM
    $completeNotice = (($noticeParts + "===== PDFIUM LICENSE =====`n" +
        (Get-Content -Raw -LiteralPath $pdfLicense).TrimEnd()) -join "`n`n") + "`n"
    if ($null -eq $expectedNotice) {
        $expectedNotice = $completeNotice
    } elseif ($completeNotice -cne $expectedNotice) {
        throw 'PDFIUM license differs between provisioned Android ABIs'
    }
    [IO.File]::WriteAllText($notices, $completeNotice,
        [Text.UTF8Encoding]::new($false))

    $configuration = @()
    foreach ($name in $libraries.Keys) {
        $library = $libraries[$name]
        $configuration += "set(DOCUMENTS_${name}_LIBRARY `"$($library.Replace('\', '/'))`")"
        $configuration += "set(DOCUMENTS_${name}_LIBRARY_SHA256 `"$((Get-FileHash -Algorithm SHA256 -LiteralPath $library).Hash.ToLowerInvariant())`")"
    }
    $configuration += "set(DOCUMENTS_PDFIUM_INCLUDE `"$($pdfInclude.Replace('\', '/'))`")"
    $configuration += "set(DOCUMENTS_TESSERACT_INCLUDE `"$((Join-Path $install 'include').Replace('\', '/'))`")"
    $configuration += "set(DOCUMENTS_LEPTONICA_INCLUDE `"$((Join-Path $install 'include').Replace('\', '/'))`")"
    foreach ($entry in ([ordered]@{
        ENG_DATA = Join-Path $dataRoot 'eng.traineddata'
        RUS_DATA = Join-Path $dataRoot 'rus.traineddata'
        PROVISIONING_MANIFEST = $identity
        LICENSES = $notices
    }).GetEnumerator()) {
        $configuration += "set(DOCUMENTS_$($entry.Key) `"$($entry.Value.Replace('\', '/'))`")"
        $configuration += "set(DOCUMENTS_$($entry.Key)_SHA256 `"$((Get-FileHash -Algorithm SHA256 -LiteralPath $entry.Value).Hash.ToLowerInvariant())`")"
    }
    Set-Content -LiteralPath (Join-Path $root 'provision.cmake') `
        -Value $configuration -Encoding utf8NoBOM
}
[IO.File]::WriteAllText((Join-Path $assetRoot 'NOTICE.txt'), $expectedNotice,
    [Text.UTF8Encoding]::new($false))
