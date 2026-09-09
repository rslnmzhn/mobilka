param(
    [Parameter(Mandatory = $true)][string]$AndroidNdk,
    [string]$OutputRoot = "$PSScriptRoot/../../android/app/.cxx/provision",
    [string]$AssetRoot = "$PSScriptRoot/../../android/app/build/generated/document-assets/documents"
)
$ErrorActionPreference = 'Stop'
$manifestPath = Join-Path $PSScriptRoot 'dependency-versions.json'
$lock = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$work = Join-Path $OutputRoot '_work'
New-Item -ItemType Directory -Force -Path $work, $OutputRoot, $AssetRoot | Out-Null

function Acquire([string]$Name, [string]$Url, [string]$Hash) {
    if ($Url -notmatch '^https://') { throw "HTTPS required for $Name" }
    if ($Hash -notmatch '^[0-9a-f]{64}$') { throw "Pinned SHA-256 required for $Name" }
    $target = Join-Path $work $Name
    if (-not (Test-Path -LiteralPath $target)) {
        Write-Host "NETWORK: downloading pinned $Url"
        Invoke-WebRequest -Uri $Url -OutFile $target -MaximumRedirection 5
    }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
    if ($actual -ne $Hash) { throw "SHA-256 mismatch for $Name" }
    return $target
}

$sources = @{}
foreach ($name in @('ZLIB','PNG','JPEG','LEPTONICA','TESSERACT')) {
    $entry = $lock.sources.$name
    $archive = Acquire "$($name.ToLowerInvariant()).tar.gz" $entry.url $entry.sha256
    $tree = Join-Path $work $name.ToLowerInvariant()
    if (-not (Test-Path -LiteralPath $tree)) {
        New-Item -ItemType Directory -Path $tree | Out-Null
        tar -xzf $archive --strip-components=1 -C $tree
    }
    $sources[$name] = $tree
}

foreach ($language in @('eng','rus')) {
    $entry = $lock.tessdata_fast.$language
    $asset = Acquire "$language.traineddata" $entry.url $entry.sha256
    Copy-Item -Force -LiteralPath $asset -Destination (Join-Path $AssetRoot "$language.traineddata")
    New-Item -ItemType Directory -Force -Path (Join-Path $OutputRoot 'assets') | Out-Null
    Copy-Item -Force -LiteralPath $asset -Destination (Join-Path $OutputRoot "assets/$language.traineddata")
}

$abis = @{
    'armeabi-v7a' = @('android-armeabi-v7a','armeabi-v7a')
    'arm64-v8a' = @('android-arm64-v8a','arm64-v8a')
    'x86_64' = @('android-x86_64','x86_64')
}
foreach ($abi in $abis.Keys) {
    $pdfEntry = $lock.pdfium.assets.($abis[$abi][0])
    $pdfArchive = Acquire "pdfium-$abi.tgz" $pdfEntry.url $pdfEntry.sha256
    $pdfRoot = Join-Path $work "pdfium-$abi"
    if (-not (Test-Path -LiteralPath $pdfRoot)) {
        New-Item -ItemType Directory -Path $pdfRoot | Out-Null
        tar -xzf $pdfArchive -C $pdfRoot
    }
    $root = Join-Path $OutputRoot $abi
    $install = Join-Path $root 'install'
    New-Item -ItemType Directory -Force -Path $root, $install | Out-Null
    & cmake "-DDOCUMENTS_SOURCES_REVIEWED=ON" "-DDOCUMENTS_TARGET=android" `
        "-DDOCUMENTS_ANDROID_NDK=$AndroidNdk" "-DDOCUMENTS_ANDROID_ABI=$abi" `
        "-DDOCUMENTS_BUILD_ROOT=$root/build" "-DDOCUMENTS_INSTALL_PREFIX=$install" `
        "-DDOCUMENTS_ZLIB_SOURCE=$($sources.ZLIB)" "-DDOCUMENTS_PNG_SOURCE=$($sources.PNG)" `
        "-DDOCUMENTS_JPEG_SOURCE=$($sources.JPEG)" "-DDOCUMENTS_LEPTONICA_SOURCE=$($sources.LEPTONICA)" `
        "-DDOCUMENTS_TESSERACT_SOURCE=$($sources.TESSERACT)" -P (Join-Path $PSScriptRoot 'build-dependencies.cmake')
    if ($LASTEXITCODE -ne 0) { throw "Native dependency build failed for $abi" }
    $pdfLib = Get-ChildItem -LiteralPath $pdfRoot -Recurse -File -Filter 'libpdfium.so' | Select-Object -Single
    if ($null -eq $pdfLib) { throw "PDFium library layout invalid for $abi" }
    $pdfInclude = Get-ChildItem -LiteralPath $pdfRoot -Recurse -Directory -Filter 'include' | Select-Object -First 1
    if ($null -eq $pdfInclude) { throw "PDFium headers missing for $abi" }
    $libraries = @{
        PDFIUM=$pdfLib.FullName; TESSERACT=(Join-Path $install 'lib/libtesseract.a');
        LEPTONICA=(Get-ChildItem (Join-Path $install 'lib') -Filter '*lept*.a' | Select-Object -First 1).FullName;
        PNG=(Get-ChildItem (Join-Path $install 'lib') -Filter '*png*.a' | Select-Object -First 1).FullName;
        JPEG=(Get-ChildItem (Join-Path $install 'lib') -Filter '*jpeg*.a' | Select-Object -First 1).FullName;
        ZLIB=(Get-ChildItem (Join-Path $install 'lib') -Filter '*z*.a' | Select-Object -First 1).FullName
    }
    $identity = Join-Path $root 'provisioning-manifest.txt'
    $notices = Join-Path $root 'LICENSES.txt'
    $identityLines = @("dependency-lock-sha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash.ToLowerInvariant())", "abi=$abi")
    foreach ($name in $libraries.Keys) {
        $identityLines += "$name=$((Get-FileHash -Algorithm SHA256 -LiteralPath $libraries[$name]).Hash.ToLowerInvariant())"
    }
    Set-Content -LiteralPath $identity -Value $identityLines -Encoding utf8NoBOM
    Set-Content -LiteralPath $notices -Value (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'DEPENDENCIES.md')) -Encoding utf8NoBOM
    $lines = @()
    foreach ($name in $libraries.Keys) {
        $path = $libraries[$name].Replace('\','/')
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $libraries[$name]).Hash.ToLowerInvariant()
        $lines += "set(DOCUMENTS_${name}_LIBRARY `"$path`")"
        $lines += "set(DOCUMENTS_${name}_LIBRARY_SHA256 `"$hash`")"
    }
    $lines += "set(DOCUMENTS_PDFIUM_INCLUDE `"$($pdfInclude.FullName.Replace('\','/'))`")"
    $lines += "set(DOCUMENTS_TESSERACT_INCLUDE `"$((Join-Path $install 'include').Replace('\','/'))`")"
    $lines += "set(DOCUMENTS_LEPTONICA_INCLUDE `"$((Join-Path $install 'include').Replace('\','/'))`")"
    foreach ($entry in @{
        ENG_DATA=(Join-Path $OutputRoot 'assets/eng.traineddata');
        RUS_DATA=(Join-Path $OutputRoot 'assets/rus.traineddata');
        PROVISIONING_MANIFEST=$identity; LICENSES=$notices
    }.GetEnumerator()) {
        $path = $entry.Value.Replace('\','/')
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $entry.Value).Hash.ToLowerInvariant()
        $lines += "set(DOCUMENTS_$($entry.Key) `"$path`")"
        $lines += "set(DOCUMENTS_$($entry.Key)_SHA256 `"$hash`")"
    }
    Set-Content -LiteralPath (Join-Path $root 'provision.cmake') -Value $lines -Encoding utf8NoBOM
}
