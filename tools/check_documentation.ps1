<#
.SYNOPSIS
检查 MgRead 的最小文档树、相对链接和 AI 入口预算。

.DESCRIPTION
职责：保证根 docs 只保留核心规范、入口和最小路由，并检查活动 Markdown 中的本地断链。
注意：脚本只读工作区；排除依赖自带文档，不要求历史设计继续存在于活动文档树。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$failures = [System.Collections.Generic.List[string]]::new()

Push-Location $repoRoot
try {
  $documentPaths = @(
    git ls-files --cached --others --exclude-standard -- '*.md' 'AGENTS.md' '**/AGENTS.md'
  ) | ForEach-Object { $_.Replace('\', '/') } | Where-Object {
    $_ -and
    $_ -notlike 'packages/mg_read_runtime/tools/*' -and
    $_ -notlike 'node_modules/*' -and
    $_ -notlike '*/node_modules/*'
  } | Sort-Object -Unique

  if ($LASTEXITCODE -ne 0) {
    throw '无法枚举 Git 文档。'
  }

  $expectedCoreDocs = @(
    'docs/README.md'
    'docs/core.md'
    'docs/development/README.md'
  )
  $actualCoreDocs = Get-ChildItem -LiteralPath (Join-Path $repoRoot 'docs') -Filter '*.md' -File -Recurse |
    ForEach-Object { [System.IO.Path]::GetRelativePath($repoRoot, $_.FullName).Replace('\', '/') } |
    Sort-Object
  $unexpectedCoreDocs = @($actualCoreDocs | Where-Object { $_ -notin $expectedCoreDocs })
  $missingCoreDocs = @($expectedCoreDocs | Where-Object { $_ -notin $actualCoreDocs })
  foreach ($path in $unexpectedCoreDocs) {
    $failures.Add("根 docs 存在非核心文档: $path")
  }
  foreach ($path in $missingCoreDocs) {
    $failures.Add("根 docs 缺少核心文档: $path")
  }

  $checkedLinks = 0
  $retiredReferencePattern = 'docs/(architecture|implementation|planning)/|docs/development/(diagnostics-instrumentation|documentation|source-file-governance|workflow)\.md'
  foreach ($relativePath in $documentPaths) {
    $fullPath = Join-Path $repoRoot $relativePath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
      continue
    }

    $text = Get-Content -LiteralPath $fullPath -Raw
    if ($text -match $retiredReferencePattern) {
      $failures.Add("仍引用已退役根文档: $relativePath")
    }

    $linkMatches = [regex]::Matches($text, '!?\[[^\]]*\]\((?<target>[^)]+)\)')
    foreach ($linkMatch in $linkMatches) {
      $target = $linkMatch.Groups['target'].Value.Trim()
      if ($target.StartsWith('<') -and $target.EndsWith('>')) {
        $target = $target.Substring(1, $target.Length - 2)
      }
      if ($target -match '^(https?://|mailto:|#|app://|file://)') {
        continue
      }

      $pathPart = ($target -split '#', 2)[0]
      if ([string]::IsNullOrWhiteSpace($pathPart)) {
        continue
      }

      $pathPart = [uri]::UnescapeDataString($pathPart)
      $candidate = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $fullPath) $pathPart))
      $checkedLinks++
      if (-not (Test-Path -LiteralPath $candidate)) {
        $lineNumber = ([regex]::Matches($text.Substring(0, $linkMatch.Index), "\n")).Count + 1
        $failures.Add("断链: ${relativePath}:${lineNumber} -> ${target}")
      }
    }
  }

  $instructionBudgets = @(
    @{ Path = 'AGENTS.md'; MaxLines = 55; MaxChars = 3500 }
    @{ Path = 'docs/README.md'; MaxLines = 20; MaxChars = 1200 }
    @{ Path = 'docs/development/README.md'; MaxLines = 40; MaxChars = 3500 }
    @{ Path = 'docs/core.md'; MaxLines = 220; MaxChars = 10000 }
  )
  foreach ($budget in $instructionBudgets) {
    $budgetPath = Join-Path $repoRoot $budget.Path
    $budgetText = Get-Content -LiteralPath $budgetPath -Raw
    $budgetLines = (Get-Content -LiteralPath $budgetPath).Count
    if ($budgetLines -gt $budget.MaxLines -or $budgetText.Length -gt $budget.MaxChars) {
      $failures.Add(
        "入口超预算: $($budget.Path) lines=${budgetLines}/$($budget.MaxLines) chars=$($budgetText.Length)/$($budget.MaxChars)"
      )
    }
  }

  $nestedAgentPaths = $documentPaths | Where-Object {
    $_ -ne 'AGENTS.md' -and $_ -match '(^|/)AGENTS\.md$'
  }
  foreach ($agentPath in $nestedAgentPaths) {
    $agentText = Get-Content -LiteralPath (Join-Path $repoRoot $agentPath) -Raw
    if ($agentText.Length -gt 3000) {
      $failures.Add("嵌套 AGENTS 超预算: ${agentPath} chars=$($agentText.Length)/3000")
    }
  }

  Write-Host "DOCUMENTATION_FILES=$($documentPaths.Count)"
  Write-Host "RELATIVE_LINKS=$checkedLinks"
  Write-Host "CORE_DOC_FILES=$($actualCoreDocs.Count)"
  Write-Host "FAILURES=$($failures.Count)"
  if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "ERROR: $_" }
    exit 1
  }
}
finally {
  Pop-Location
}
