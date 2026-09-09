param(
  [Parameter(Mandatory = $true)][string]$Worker,
  [Parameter(Mandatory = $true)][string]$RuntimeDirectory,
  [Parameter(Mandatory = $true)][string]$Output
)
$ErrorActionPreference = 'Stop'
$files = @('document_worker.exe', 'pdfium.dll', 'eng.traineddata', 'rus.traineddata', 'document-worker-notices.txt')
$workerPath = [IO.Path]::GetFullPath($Worker)
$runtimePath = [IO.Path]::GetFullPath($RuntimeDirectory).TrimEnd('\') + '\'
$entries = foreach ($name in $files) {
  $candidate = if ($name -eq 'document_worker.exe') {
    $workerPath
  } else {
    Join-Path $RuntimeDirectory $name
  }
  $path = [IO.Path]::GetFullPath($candidate)
  if ([IO.Path]::GetFileName($path) -cne $name -or
      -not $path.StartsWith($runtimePath, [StringComparison]::OrdinalIgnoreCase) -or
      -not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Manifest input is absent or not exact: $name"
  }
  $item = Get-Item -Force -LiteralPath $path
  if ($item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
    throw "Manifest input is a reparse point: $name"
  }
  $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
  "    {L`"$name`", `"$hash`"},"
}
$content = @(
  '#pragma once', '#include <array>', '#include <utility>',
  'inline constexpr std::array<std::pair<const wchar_t*, const char*>, 5>',
  '    kDocumentWorkerManifest = {{', $entries, '}};'
) -join "`n"
$parent = Split-Path -Parent $Output
New-Item -ItemType Directory -Force -Path $parent | Out-Null
[IO.File]::WriteAllText($Output, $content + "`n", [Text.UTF8Encoding]::new($false))
