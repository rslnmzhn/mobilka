param(
  [Parameter(Mandatory = $true)][string]$Worker,
  [Parameter(Mandatory = $true)][string]$RuntimeDirectory,
  [Parameter(Mandatory = $true)][string]$Output
)
$ErrorActionPreference = 'Stop'
$files = @('document_worker.exe', 'pdfium.dll', 'eng.traineddata', 'rus.traineddata', 'document-worker-notices.txt')
$workerPath = [IO.Path]::GetFullPath($Worker)
$runtimePath = [IO.Path]::GetFullPath($RuntimeDirectory).TrimEnd('\', '/')
$entries = foreach ($name in $files) {
  $candidate = if ($name -eq 'document_worker.exe') {
    $workerPath
  } else {
    Join-Path $RuntimeDirectory $name
  }
  $path = [IO.Path]::GetFullPath($candidate)
  if ([IO.Path]::GetFileName($path) -cne $name -or
      -not [string]::Equals([IO.Path]::GetDirectoryName($path), $runtimePath,
          [StringComparison]::OrdinalIgnoreCase) -or
      -not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Manifest input is absent or not exact: $name"
  }
  $item = Get-Item -Force -LiteralPath $path
  if ($item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
    throw "Manifest input is a reparse point: $name"
  }
  $stream = [IO.File]::OpenRead($path)
  $algorithm = [Security.Cryptography.SHA256]::Create()
  try {
    $hash = [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
  } finally {
    $algorithm.Dispose()
    $stream.Dispose()
  }
  "    {L`"$name`", `"$hash`"},"
}
$lines = @(
  '#pragma once', '#include <array>', '#include <utility>',
  'inline constexpr std::array<std::pair<const wchar_t*, const char*>, 5>',
  '    kDocumentWorkerManifest = {{'
)
$lines += @($entries)
$lines += '}};'
$content = $lines -join "`n"
$parent = Split-Path -Parent $Output
New-Item -ItemType Directory -Force -Path $parent | Out-Null
[IO.File]::WriteAllText($Output, $content + "`n", [Text.UTF8Encoding]::new($false))
