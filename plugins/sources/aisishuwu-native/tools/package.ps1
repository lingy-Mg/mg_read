# Deterministically packages the three already-built Alice native libraries.
# Build ownership stays in build.ps1; this script only hashes inputs and writes
# the portable .mgplugin archive used by Runtime import and acceptance tests.
param(
  [string]$WindowsDll = (Join-Path $PSScriptRoot '..\target\x86_64-pc-windows-msvc\release\aisishuwu_native.dll'),
  [string]$AndroidArm64So = (Join-Path $PSScriptRoot '..\target\aarch64-linux-android\release\libaisishuwu_native.so'),
  [string]$AndroidX64So = (Join-Path $PSScriptRoot '..\target\x86_64-linux-android\release\libaisishuwu_native.so'),
  [string]$Output = (Join-Path $PSScriptRoot '..\dist\aisishuwu-native-0.1.0.mgplugin')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression

$libraries = [ordered]@{
  'windows-x86_64' = @{ Path = $WindowsDll; ArchivePath = 'native/windows-x86_64/aisishuwu_native.dll' }
  'android-arm64-v8a' = @{ Path = $AndroidArm64So; ArchivePath = 'native/android-arm64-v8a/libaisishuwu_native.so' }
  'android-x86_64' = @{ Path = $AndroidX64So; ArchivePath = 'native/android-x86_64/libaisishuwu_native.so' }
}

foreach ($target in $libraries.Keys) {
  $path = [System.IO.Path]::GetFullPath($libraries[$target].Path)
  if (-not [System.IO.File]::Exists($path)) { throw "Required native library for '$target' was not found: $path" }
  $libraries[$target].Path = $path
}

$targets = [ordered]@{}
foreach ($target in $libraries.Keys) {
  $library = $libraries[$target]
  $hash = (Get-FileHash -LiteralPath $library.Path -Algorithm SHA256).Hash.ToLowerInvariant()
  $targets[$target] = [ordered]@{ path = $library.ArchivePath; sha256 = $hash }
}
$manifest = [ordered]@{
  format = 'mgread-native'
  engine = 'native'
  abi = 1
  id = 'org.mgread.aisishuwu.native'
  name = '爱丽丝书屋 Native'
  version = '0.1.0'
  description = '爱丽丝书屋 Rust 原生小说来源'
  contentKinds = @('novel')
  capabilities = @('discover', 'search', 'searchSuggestions', 'getDetail', 'getChapters', 'getContent')
  targets = $targets
}
$manifestBytes = [System.Text.UTF8Encoding]::new($false).GetBytes(($manifest | ConvertTo-Json -Depth 10 -Compress))

$outputPath = [System.IO.Path]::GetFullPath($Output)
$outputDirectory = [System.IO.Path]::GetDirectoryName($outputPath)
[System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
$temporaryPath = "$outputPath.tmp"
if ([System.IO.File]::Exists($temporaryPath)) { [System.IO.File]::Delete($temporaryPath) }

$stream = [System.IO.File]::Open($temporaryPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
try {
  $archive = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create, $true)
  try {
    $entries = [ordered]@{ 'manifest.json' = $manifestBytes }
    foreach ($target in $libraries.Keys) {
      $library = $libraries[$target]
      $entries[$library.ArchivePath] = [System.IO.File]::ReadAllBytes($library.Path)
    }
    foreach ($entryName in $entries.Keys) {
      $entry = $archive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::NoCompression)
      $entry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
      $entry.ExternalAttributes = 0
      $entryStream = $entry.Open()
      try { $entryStream.Write($entries[$entryName], 0, $entries[$entryName].Length) }
      finally { $entryStream.Dispose() }
    }
  }
  finally { $archive.Dispose() }
}
finally { $stream.Dispose() }

if ([System.IO.File]::Exists($outputPath)) { [System.IO.File]::Delete($outputPath) }
[System.IO.File]::Move($temporaryPath, $outputPath)
$packageHash = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Output "Packaged $outputPath"
Write-Output "SHA-256 $packageHash"
