<# Verifies repeated local/CI packaging replaces removed files and keeps the
previous complete release when a new invocation has invalid input. Test data
and archives stay in an ignored, unique workspace directory. #>
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path $root ".dart_tool/package-regression-$([Guid]::NewGuid().ToString('N'))"
$inputRoot = Join-Path $testRoot 'input'
$outputBase = Join-Path $testRoot 'release'
New-Item -ItemType Directory -Path $inputRoot | Out-Null
Set-Content -LiteralPath (Join-Path $inputRoot 'keep.txt') -Value 'one'
Set-Content -LiteralPath (Join-Path $inputRoot 'obsolete.txt') -Value 'remove from the next archive'
& "$PSScriptRoot/package_windows_release.ps1" -InputDirectory $inputRoot -DestinationBase $outputBase
Remove-Item -LiteralPath (Join-Path $inputRoot 'obsolete.txt')
Set-Content -LiteralPath (Join-Path $inputRoot 'keep.txt') -Value 'two'
& "$PSScriptRoot/package_windows_release.ps1" -InputDirectory $inputRoot -DestinationBase $outputBase
Expand-Archive -LiteralPath "$outputBase.zip" -DestinationPath (Join-Path $testRoot 'zip')
$sevenZip = Join-Path $root '.dart_tool/packaging/7zip-26.05/7zr.exe'
& $sevenZip x "$outputBase.7z" "-o$testRoot/7z" -y
if ($LASTEXITCODE -ne 0) { throw '7z extraction failed.' }
foreach ($kind in @('zip','7z')) {
  $files = @(Get-ChildItem -LiteralPath (Join-Path $testRoot $kind) -File -Recurse)
  if ($files.Count -ne 1 -or $files[0].Name -ne 'keep.txt' -or (Get-Content -LiteralPath $files[0].FullName -Raw).Trim() -ne 'two') {
    throw "Stale or incorrect archive content: $kind"
  }
}
$before = (Get-FileHash -LiteralPath "$outputBase.zip").Hash
try {
  & "$PSScriptRoot/package_windows_release.ps1" -InputDirectory $inputRoot -DestinationBase $outputBase -Entry 'missing.txt'
  throw 'Invalid input unexpectedly succeeded.'
} catch {
  if ($_.Exception.Message -eq 'Invalid input unexpectedly succeeded.') { throw }
}
if ((Get-FileHash -LiteralPath "$outputBase.zip").Hash -ne $before) { throw 'Failed build changed the previous archive.' }
$manifest = Get-Content -LiteralPath "$outputBase.manifest.json" -Raw -Encoding utf8 | ConvertFrom-Json
foreach ($archive in $manifest.archives) {
  if ((Get-FileHash -LiteralPath (Join-Path $testRoot $archive.file)).Hash -ne $archive.sha256) { throw 'Archive manifest hash mismatch.' }
}
Write-Host 'PASS fresh archives, repeat packaging, removed entries, failure preservation and checksums'
