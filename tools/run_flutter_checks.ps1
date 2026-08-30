<#
.SYNOPSIS
按显式拥有路径运行 MgRead Flutter 检查。

.DESCRIPTION
职责：将编辑循环、任务收尾和明确的全量回归分开，避免对共享脏工作区执行全仓格式化或
无条件全量测试。调用者必须传入本次拥有的 Dart 文件；默认不枚举或格式化工作区中的其他文件。
每个阶段的完整输出写入被忽略的 .dart_tool/ai-checks，终端只显示阶段状态和有界失败摘要。
边界：此脚本不管理并发、不会终止进程，也不替代 Android integration_test 或发布构建。
#>
[CmdletBinding()]
param(
  [ValidateSet('Fast', 'Final', 'Full')]
  [string]$Mode = 'Fast',

  [Parameter(Mandatory)]
  [ValidateNotNullOrEmpty()]
  [string[]]$DartPath,

  [string[]]$TestPath
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$logDirectory = Join-Path $repositoryRoot '.dart_tool/ai-checks'

function Resolve-OwnedFile {
  param(
    [string]$Path,
    [string]$Label
  )

  $resolvedPath = (Resolve-Path -LiteralPath (Join-Path $repositoryRoot $Path)).Path
  $relativePath = [System.IO.Path]::GetRelativePath($repositoryRoot, $resolvedPath)
  if ($relativePath -eq '..' -or $relativePath.StartsWith("..$([System.IO.Path]::DirectorySeparatorChar)")) {
    throw "$Label must stay inside the repository: $Path"
  }
  if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
    throw "$Label must be a file: $Path"
  }
  return $relativePath.Replace('\', '/')
}

function Invoke-NativeCheck {
  param(
    [string]$Label,
    [string]$Program,
    [string[]]$Arguments
  )

  [System.IO.Directory]::CreateDirectory($logDirectory) | Out-Null
  $safeLabel = [regex]::Replace($Label.ToLowerInvariant(), '[^a-z0-9]+', '-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($safeLabel)) {
    $safeLabel = 'check'
  }
  $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
  $logPath = Join-Path $logDirectory "$timestamp-$safeLabel.log"
  $relativeLogPath = [System.IO.Path]::GetRelativePath($repositoryRoot, $logPath).Replace('\', '/')
  $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

  Write-Host "RUN $Label"
  try {
    & $Program @Arguments *> $logPath
    $exitCode = $LASTEXITCODE
  } catch {
    $_ | Out-File -LiteralPath $logPath -Append
    $exitCode = 1
  } finally {
    $stopwatch.Stop()
  }

  if ($exitCode -eq 0) {
    Write-Host "PASS $Label duration_ms=$($stopwatch.ElapsedMilliseconds) log=$relativeLogPath"
    return
  }

  Write-Host "FAIL $Label exit_code=$exitCode duration_ms=$($stopwatch.ElapsedMilliseconds) log=$relativeLogPath"
  Write-Host 'FAILURE_TAIL_BEGIN'
  Get-Content -LiteralPath $logPath -Tail 40 | ForEach-Object { Write-Host $_ }
  Write-Host 'FAILURE_TAIL_END'
  throw "$Label failed with exit code $exitCode. Full log: $relativeLogPath"
}

$dartFiles = @($DartPath | ForEach-Object { Resolve-OwnedFile -Path $_ -Label 'DartPath' } | Sort-Object -Unique)
foreach ($path in $dartFiles) {
  if (-not $path.EndsWith('.dart', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "DartPath must reference a .dart file: $path"
  }
}

$testFiles = @($TestPath | Where-Object { $_ } | ForEach-Object { Resolve-OwnedFile -Path $_ -Label 'TestPath' } | Sort-Object -Unique)
foreach ($path in $testFiles) {
  if (-not $path.EndsWith('_test.dart', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "TestPath must reference a Dart test file: $path"
  }
}
if ($Mode -eq 'Full' -and $testFiles.Count -gt 0) {
  throw 'Full mode always runs the complete flutter test suite; omit -TestPath to avoid duplicating target tests.'
}

Push-Location $repositoryRoot
try {
  Write-Host "MODE=$Mode"
  Write-Host "DART_FILES=$($dartFiles.Count)"
  Write-Host "TEST_FILES=$($testFiles.Count)"

  Invoke-NativeCheck -Label 'Source file-size policy' -Program 'pwsh' -Arguments @(
    '-NoProfile'
    '-File'
    (Join-Path $PSScriptRoot 'check_source_file_sizes.ps1')
  )

  Invoke-NativeCheck -Label 'Dart format (owned files)' -Program 'dart' -Arguments (@('format', '--output=none', '--set-exit-if-changed') + $dartFiles)

  if ($Mode -eq 'Fast') {
    Invoke-NativeCheck -Label 'Dart analyze (owned files)' -Program 'dart' -Arguments (@('analyze') + $dartFiles)
  } else {
    Invoke-NativeCheck -Label 'Flutter analyze (repository)' -Program 'flutter' -Arguments @('analyze')
  }

  if ($Mode -eq 'Full') {
    Invoke-NativeCheck -Label 'Flutter test (full suite)' -Program 'flutter' -Arguments @('test')
  } elseif ($testFiles.Count -gt 0) {
    Invoke-NativeCheck -Label 'Flutter test (owned tests)' -Program 'flutter' -Arguments (@('test') + $testFiles)
  } else {
    Write-Warning 'No TestPath supplied. Run the directly affected tests separately before reporting completion.'
  }
}
finally {
  Pop-Location
}
