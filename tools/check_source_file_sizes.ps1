[CmdletBinding()]
param(
  [string]$PolicyPath = (Join-Path $PSScriptRoot 'source_file_size_policy.json')
)

$ErrorActionPreference = 'Stop'

function Normalize-RepositoryPath {
  param([string]$Path)
  return $Path.Replace('\\', '/').TrimStart('./')
}

function Has-SourceExtension {
  param([string]$Path, [object[]]$Extensions)
  return $Extensions | Where-Object { $Path.EndsWith([string]$_, [System.StringComparison]::OrdinalIgnoreCase) }
}

function Is-ExcludedPath {
  param([string]$Path, [object]$Policy)

  foreach ($prefix in $Policy.excludedPathPrefixes) {
    if ($Path.StartsWith([string]$prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      return $true
    }
  }
  foreach ($segment in $Policy.excludedPathSegments) {
    if ($Path -match "(^|/)$([regex]::Escape([string]$segment))(/|$)") {
      return $true
    }
  }
  foreach ($suffix in $Policy.generatedSuffixes) {
    if ($Path.EndsWith([string]$suffix, [System.StringComparison]::OrdinalIgnoreCase)) {
      return $true
    }
  }
  return $false
}

function Get-NonEmptyLineCount {
  param([string]$Path)
  $count = 0
  foreach ($line in [System.IO.File]::ReadLines($Path)) {
    if ($line.Trim().Length -gt 0) {
      $count++
    }
  }
  return $count
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$resolvedPolicyPath = (Resolve-Path $PolicyPath).Path
$policy = Get-Content -LiteralPath $resolvedPolicyPath -Raw | ConvertFrom-Json
$baseline = @{}
foreach ($property in $policy.legacyBaseline.PSObject.Properties) {
  $baseline[$property.Name] = [int]$property.Value
}
$legacyRationale = @{}
foreach ($property in $policy.legacyRationale.PSObject.Properties) {
  $legacyRationale[$property.Name] = [string]$property.Value
}

$gitPaths = & git -C $repositoryRoot ls-files --cached --others --exclude-standard
if ($LASTEXITCODE -ne 0) {
  throw 'Unable to enumerate repository files with git ls-files.'
}

$errors = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()
$seenBaseline = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

foreach ($rawPath in $gitPaths | Sort-Object -Unique) {
  $relativePath = Normalize-RepositoryPath $rawPath
  if (-not (Has-SourceExtension $relativePath $policy.extensions) -or (Is-ExcludedPath $relativePath $policy)) {
    continue
  }

  $absolutePath = Join-Path $repositoryRoot ($relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
  if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
    continue
  }
  $lineCount = Get-NonEmptyLineCount $absolutePath
  if ($baseline.ContainsKey($relativePath)) {
    [void]$seenBaseline.Add($relativePath)
    if ($lineCount -ne $baseline[$relativePath]) {
      if ($lineCount -lt $policy.hardLimit) {
        $errors.Add("$relativePath is now $lineCount non-empty lines; remove it from legacyBaseline.")
      } elseif ($lineCount -gt $baseline[$relativePath]) {
        $errors.Add("$relativePath grew from baseline $($baseline[$relativePath]) to $lineCount non-empty lines.")
      } else {
        $errors.Add("$relativePath decreased from baseline $($baseline[$relativePath]) to $lineCount; lower its baseline in the same change.")
      }
    }
    continue
  }

  if ($lineCount -ge $policy.hardLimit) {
    $errors.Add("$relativePath has $lineCount non-empty lines (hard limit: $($policy.hardLimit)).")
  } elseif ($lineCount -ge $policy.warningLimit) {
    $warnings.Add("$relativePath has $lineCount non-empty lines (warning limit: $($policy.warningLimit)).")
  }
}

foreach ($path in $baseline.Keys) {
  if (-not $seenBaseline.Contains($path)) {
    $errors.Add("legacyBaseline entry $path no longer maps to a tracked source file; remove it.")
  }
  if (-not $legacyRationale.ContainsKey($path) -or [string]::IsNullOrWhiteSpace($legacyRationale[$path])) {
    $errors.Add("legacyBaseline entry $path requires a non-empty legacyRationale.")
  }
}
foreach ($path in $legacyRationale.Keys) {
  if (-not $baseline.ContainsKey($path)) {
    $errors.Add("legacyRationale entry $path has no matching legacyBaseline; remove it.")
  }
}

foreach ($warning in $warnings) {
  Write-Warning $warning
}
if ($errors.Count -gt 0) {
  $errors | ForEach-Object { Write-Error $_ }
  exit 1
}

Write-Output "Source file-size policy passed: $($baseline.Count) legacy files are frozen and can only shrink."
