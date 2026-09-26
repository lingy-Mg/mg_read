# Deterministically package the already-built Alice libraries. The portable
# archive retains all targets for later cross-platform sync; the Windows and
# Android archives are small, directly importable distribution artifacts.
param(
  [string]$WindowsDll = (Join-Path $PSScriptRoot '..\target\x86_64-pc-windows-msvc\release\aisishuwu_native.dll'),
  [string]$AndroidArm64So = (Join-Path $PSScriptRoot '..\target\aarch64-linux-android\release\libaisishuwu_native.so'),
  [string]$AndroidX64So = (Join-Path $PSScriptRoot '..\target\x86_64-linux-android\release\libaisishuwu_native.so'),
  [string]$Output = (Join-Path $PSScriptRoot '..\dist\aisishuwu-native-0.1.0.mgplugin'),
  [string]$WindowsOutput = (Join-Path $PSScriptRoot '..\dist\aisishuwu-native-0.1.0-windows.mgplugin'),
  [string]$AndroidOutput = (Join-Path $PSScriptRoot '..\dist\aisishuwu-native-0.1.0-android.mgplugin')
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

function Write-Package([string]$Path, [string[]]$SelectedTargets) {
  $targets = [ordered]@{}
  foreach ($target in $SelectedTargets) {
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
  $outputPath = [System.IO.Path]::GetFullPath($Path)
  [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($outputPath)) | Out-Null
  $temporaryPath = "$outputPath.tmp"
  if ([System.IO.File]::Exists($temporaryPath)) { [System.IO.File]::Delete($temporaryPath) }

  $stream = [System.IO.File]::Open($temporaryPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
  try {
    $archive = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create, $true)
    try {
      $entries = [ordered]@{ 'manifest.json' = $manifestBytes }
      foreach ($target in $SelectedTargets) {
        $library = $libraries[$target]
        $entries[$library.ArchivePath] = [System.IO.File]::ReadAllBytes($library.Path)
      }
      foreach ($entryName in $entries.Keys) {
        $entry = $archive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::SmallestSize)
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
  Write-Output "Packaged $outputPath"
  Write-Output "SHA-256 $((Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash.ToLowerInvariant())"
}

$paths = @($Output, $WindowsOutput, $AndroidOutput) | ForEach-Object { [System.IO.Path]::GetFullPath($_) }
if (($paths | Select-Object -Unique).Count -ne 3) { throw 'Package output paths must be distinct.' }
Write-Package $Output @('windows-x86_64', 'android-arm64-v8a', 'android-x86_64')
Write-Package $WindowsOutput @('windows-x86_64')
Write-Package $AndroidOutput @('android-arm64-v8a', 'android-x86_64')
