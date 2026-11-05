<#
Builds ZIP and compact 7z distributions from the same validated release files.
Owns only destination archives and a hash-verified build-tool cache; never edits
the input bundle or installs a global tool. Official standalone 7zr is pinned
to 26.05 and its GitHub release SHA-256. Every build creates fresh temporary
archives, validates them, then replaces outputs; obsolete entries cannot survive.
#>
[CmdletBinding()]
param(
  [string]$InputDirectory = 'build/windows/x64/runner/Release',
  [string]$DestinationBase = 'build/mgread-windows-x64',
  [string[]]$Entry
)
$ErrorActionPreference = 'Stop'
$inputRoot = (Resolve-Path -LiteralPath $InputDirectory).Path
$outputBase = [IO.Path]::GetFullPath($DestinationBase)
if (-not $Entry) { $Entry = @(Get-ChildItem -LiteralPath $inputRoot | Select-Object -ExpandProperty Name) }
if ($Entry.Count -eq 0) { throw 'Release input is empty.' }
$paths = foreach ($name in $Entry) {
  if ($name -in @('.', '..') -or $name -match '[/\\:*?]' -or [IO.Path]::IsPathRooted($name)) {
    throw 'Archive entries must be direct children of the input directory.'
  }
  (Resolve-Path -LiteralPath (Join-Path $inputRoot $name)).Path
}
foreach ($path in $paths) {
  if (Test-Path -LiteralPath $path -PathType Container) {
    $relative = [IO.Path]::GetRelativePath($path, $outputBase)
    if ($relative -ne '..' -and -not $relative.StartsWith('..' + [IO.Path]::DirectorySeparatorChar) -and -not [IO.Path]::IsPathRooted($relative)) {
      throw 'Destination archives must not be nested inside an archived entry.'
    }
  }
}
foreach ($suffix in @('.zip', '.7z', '.manifest.json')) {
  if (Test-Path -LiteralPath "$outputBase$suffix" -PathType Container) { throw "Output is a directory: $outputBase$suffix" }
}
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$cache = Join-Path $repositoryRoot '.dart_tool/packaging/7zip-26.05'
$sevenZip = Join-Path $cache '7zr.exe'
$digest = '9bf582b894dfa665f852d7e9112b02290a1c303c2d95a21fcdc41ffcb03143b7'
[IO.Directory]::CreateDirectory($cache) | Out-Null
if (-not (Test-Path -LiteralPath $sevenZip)) {
  $download = "$sevenZip.part"
  Invoke-WebRequest -Uri 'https://github.com/ip7z/7zip/releases/download/26.05/7zr.exe' -OutFile $download
  if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne $digest) { throw '7-Zip download checksum mismatch.' }
  Move-Item -LiteralPath $download -Destination $sevenZip
}
if ((Get-FileHash -LiteralPath $sevenZip -Algorithm SHA256).Hash -ne $digest) { throw '7-Zip cache checksum mismatch.' }
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($outputBase)) | Out-Null
$stageBase = "$outputBase.stage-$([Guid]::NewGuid().ToString('N'))"
try {
  Compress-Archive -LiteralPath $paths -DestinationPath "$stageBase.zip" -CompressionLevel Optimal
  Push-Location $inputRoot
  try {
    & $sevenZip a -t7z -mx=9 -mmt=4 "$stageBase.7z" @Entry
    if ($LASTEXITCODE -ne 0) { throw "7-Zip compression failed: $LASTEXITCODE" }
    & $sevenZip t "$stageBase.7z"
    if ($LASTEXITCODE -ne 0) { throw "7-Zip archive verification failed: $LASTEXITCODE" }
  } finally { Pop-Location }
  $archives = foreach ($suffix in @('.zip', '.7z')) {
    $file = Get-Item -LiteralPath "$stageBase$suffix"
    [ordered]@{ file = [IO.Path]::GetFileName("$outputBase$suffix"); bytes = $file.Length; sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
  }
  [ordered]@{ schemaVersion = 1; sevenZipVersion = '26.05'; entries = $Entry; archives = @($archives) } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$stageBase.manifest.json" -Encoding utf8
  foreach ($suffix in @('.zip', '.7z', '.manifest.json')) {
    Move-Item -LiteralPath "$stageBase$suffix" -Destination "$outputBase$suffix" -Force
  }
  Write-Host "Published ZIP, 7z and checksums: $outputBase"
} finally {
  foreach ($suffix in @('.zip', '.7z', '.manifest.json')) {
    if (Test-Path -LiteralPath "$stageBase$suffix" -PathType Leaf) { Remove-Item -LiteralPath "$stageBase$suffix" }
  }
}
