# Package only Windows x64 and Android arm64 in one standard Deflate ZIP.
# NanaZip 7.0 (2609.2) uses exhaustive Deflate passes for the smallest
# compatible local-import archive; LAN sync sends only the receiver's binary.
param(
  [string]$WindowsDll = (Join-Path $PSScriptRoot '..\target\x86_64-pc-windows-msvc\release\aisishuwu_native.dll'),
  [string]$AndroidArm64So = (Join-Path $PSScriptRoot '..\target\aarch64-linux-android\release\libaisishuwu_native.so'),
  [string]$Output = (Join-Path $PSScriptRoot '..\dist\aisishuwu-native-0.3.0.mgplugin')
)

$ErrorActionPreference = 'Stop'
$archiver = (Get-Command 7z -ErrorAction Stop).Source
$archiverBanner = (& $archiver i | Where-Object { $_ -match '^NanaZip ' } | Select-Object -First 1)
if ($archiverBanner -notmatch '^NanaZip 7\.0 , version 2609\.2 \(x64\)') {
  throw 'Packaging requires NanaZip 7.0 version 2609.2 (x64) on PATH as 7z.'
}

$libraries = [ordered]@{
  'windows-x86_64' = @{ Path = $WindowsDll; ArchivePath = 'native/windows-x86_64/aisishuwu_native.dll' }
  'android-arm64-v8a' = @{ Path = $AndroidArm64So; ArchivePath = 'native/android-arm64-v8a/libaisishuwu_native.so' }
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
    abi = 3
    id = 'org.mgread.aisishuwu.native'
    name = '爱丽丝书屋 Native'
    version = '0.3.0'
    description = '爱丽丝书屋 Rust 原生小说来源'
    contentKinds = @('novel')
    capabilities = @('discover', 'search', 'searchSuggestions', 'getDetail', 'getChapters', 'getContent')
    targets = $targets
  }
  $manifestBytes = [System.Text.UTF8Encoding]::new($false).GetBytes(($manifest | ConvertTo-Json -Depth 10 -Compress))
  $outputPath = [System.IO.Path]::GetFullPath($Path)
  [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($outputPath)) | Out-Null
  $temporaryPath = "$outputPath.tmp"
  $stage = Join-Path ([System.IO.Path]::GetDirectoryName($outputPath)) ('.alice-package-' + [Guid]::NewGuid().ToString('N'))
  [System.IO.Directory]::CreateDirectory($stage) | Out-Null
  try {
    $archivePaths = @('manifest.json')
    [System.IO.File]::WriteAllBytes((Join-Path $stage 'manifest.json'), $manifestBytes)
    foreach ($target in $SelectedTargets) {
      $library = $libraries[$target]
      $destination = Join-Path $stage ($library.ArchivePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
      [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($destination)) | Out-Null
      [System.IO.File]::Copy($library.Path, $destination)
      $archivePaths += $library.ArchivePath
    }
    foreach ($entry in $archivePaths) {
      [System.IO.File]::SetLastWriteTimeUtc((Join-Path $stage $entry), [DateTime]::new(1980, 1, 1, 0, 0, 0, [DateTimeKind]::Utc))
    }
    if ([System.IO.File]::Exists($temporaryPath)) { [System.IO.File]::Delete($temporaryPath) }
    Push-Location $stage
    try {
      & $archiver a -tzip $temporaryPath @archivePaths -mm=Deflate -mx=9 -mfb=258 -mpass=15 -mtc=off -mtm=off -mta=off | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "High-compression ZIP packaging failed ($LASTEXITCODE)." }
    }
    finally { Pop-Location }
  }
  finally {
    $outputDirectory = [System.IO.Path]::GetDirectoryName($outputPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $stage.StartsWith($outputDirectory, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Package staging directory escaped the output directory: $stage"
    }
    [System.IO.Directory]::Delete($stage, $true)
  }

  if ([System.IO.File]::Exists($outputPath)) { [System.IO.File]::Delete($outputPath) }
  [System.IO.File]::Move($temporaryPath, $outputPath)
  Write-Output "Packaged $outputPath"
  Write-Output "SHA-256 $((Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash.ToLowerInvariant())"
}

Write-Package $Output @('windows-x86_64', 'android-arm64-v8a')
