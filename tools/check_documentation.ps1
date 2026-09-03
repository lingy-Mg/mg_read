<#
.SYNOPSIS
审计 MgRead 的最小 AI 文档链、链接、锚点和重复规则。

.DESCRIPTION
职责：只基于 Git 跟踪文档检查根 docs 三文件拓扑、活动链接、退役入口和唯一规范来源，
并输出入口规模与疑似重复规则摘要。脚本只读工作区，不把字符数单独作为失败门槛。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$failures = [System.Collections.Generic.List[string]]::new()

function Get-MarkdownAnchors {
  param([string]$Path)

  $seen = @{}
  $anchors = [System.Collections.Generic.List[string]]::new()
  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -notmatch '^\s{0,3}#{1,6}\s+(?<heading>.+?)\s*#*\s*$') {
      continue
    }

    $heading = $Matches['heading']
    $heading = [regex]::Replace($heading, '\[([^\]]+)\]\([^)]+\)', '$1')
    $heading = [regex]::Replace($heading, '<[^>]+>', '')
    $heading = $heading.Replace('`', '').ToLowerInvariant()
    $slug = [regex]::Replace($heading, '[^\p{L}\p{Nd}\s_-]', '')
    $slug = [regex]::Replace($slug.Trim(), '\s+', '-')
    if ([string]::IsNullOrWhiteSpace($slug)) {
      continue
    }

    $baseSlug = $slug
    if ($seen.ContainsKey($baseSlug)) {
      $seen[$baseSlug]++
      $slug = "$baseSlug-$($seen[$baseSlug])"
    } else {
      $seen[$baseSlug] = 0
    }
    $anchors.Add($slug)
  }
  return $anchors
}

Push-Location $repoRoot
try {
  $documentPaths = @(
    git ls-files --cached -- '*.md' 'AGENTS.md' '**/AGENTS.md'
  ) | ForEach-Object { $_.Replace('\', '/') } | Where-Object {
    $_ -and
    $_ -notlike 'packages/mg_read_node_runtime/tools/*' -and
    $_ -notlike 'node_modules/*' -and
    $_ -notlike '*/node_modules/*'
  } | Sort-Object -Unique

  if ($LASTEXITCODE -ne 0) {
    throw '无法枚举 Git 跟踪文档。'
  }

  $expectedCoreDocs = @(
    'docs/README.md'
    'docs/core.md'
    'docs/development/README.md'
  )
  $actualCoreDocs = Get-ChildItem -LiteralPath (Join-Path $repoRoot 'docs') -Filter '*.md' -File -Recurse |
    ForEach-Object { [System.IO.Path]::GetRelativePath($repoRoot, $_.FullName).Replace('\', '/') } |
    Sort-Object
  foreach ($path in @($actualCoreDocs | Where-Object { $_ -notin $expectedCoreDocs })) {
    $failures.Add("根 docs 存在非核心文档: $path")
  }
  foreach ($path in @($expectedCoreDocs | Where-Object { $_ -notin $actualCoreDocs })) {
    $failures.Add("根 docs 缺少核心文档: $path")
  }

  foreach ($path in @($documentPaths | Where-Object { $_ -cmatch '(^|/)agent\.md$' })) {
    $failures.Add("存在小写 Agent 兼容入口: $path")
  }

  $retiredReferencePatterns = @(
    'docs/(architecture|implementation|planning)/'
    'docs/development/(diagnostics-instrumentation|documentation|source-file-governance|workflow)\.md'
    'packages/mg_read_reader_ui/docs/(DEVELOPMENT|PROJECT_GOAL|UI_DESIGN)\.md'
    'packages/mg_read_node_runtime/(agent\.md|docs/(desktop-runtime-bridge|standalone-runtime-contract)\.md)'
    'mgread-source-development/references/verification\.md'
    'plugins/sources/[^/\s`]+/README\.md'
  )
  $readmeRulePatterns = @(
    'git\s+status\s+--short'
    'dart\s+format\s+\.'
    'flutter\s+test(?:\s|`|$)'
    '开始任何修改前[^\r\n]*Git'
    '每次修改[^\r\n]*全仓'
  )
  $anchorCache = @{}
  $checkedLinks = 0
  $checkedAnchors = 0
  $totalCharacters = 0
  $documentSizes = [System.Collections.Generic.List[object]]::new()

  foreach ($relativePath in $documentPaths) {
    $fullPath = Join-Path $repoRoot $relativePath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
      continue
    }

    $text = Get-Content -LiteralPath $fullPath -Raw
    $totalCharacters += $text.Length
    $documentSizes.Add([pscustomobject]@{ Path = $relativePath; Characters = $text.Length })

    foreach ($pattern in $retiredReferencePatterns) {
      if ($text -match $pattern) {
        $failures.Add("仍引用已退役文档: $relativePath")
        break
      }
    }
    if ($relativePath -match '(^|/)README\.md$') {
      foreach ($pattern in $readmeRulePatterns) {
        if ($text -match $pattern) {
          $failures.Add("README 重新承载 AI 验证规则: $relativePath")
          break
        }
      }
    }

    $linkMatches = [regex]::Matches($text, '!?\[[^\]]*\]\((?<target>[^)]+)\)')
    foreach ($linkMatch in $linkMatches) {
      $target = $linkMatch.Groups['target'].Value.Trim()
      if ($target.StartsWith('<') -and $target.EndsWith('>')) {
        $target = $target.Substring(1, $target.Length - 2)
      }
      if ($target -match '^(https?://|mailto:|app://|file://)') {
        continue
      }

      $targetParts = $target -split '#', 2
      $pathPart = $targetParts[0]
      $fragment = if ($targetParts.Count -gt 1) { [uri]::UnescapeDataString($targetParts[1]) } else { '' }
      if ([string]::IsNullOrWhiteSpace($pathPart)) {
        $candidate = $fullPath
      } else {
        $pathPart = [uri]::UnescapeDataString($pathPart)
        $candidate = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $fullPath) $pathPart))
        $checkedLinks++
        if (-not (Test-Path -LiteralPath $candidate)) {
          $lineNumber = ([regex]::Matches($text.Substring(0, $linkMatch.Index), "\n")).Count + 1
          $failures.Add("断链: ${relativePath}:${lineNumber} -> ${target}")
          continue
        }
      }

      if (-not [string]::IsNullOrWhiteSpace($fragment) -and [System.IO.Path]::GetExtension($candidate) -eq '.md') {
        $checkedAnchors++
        if (-not $anchorCache.ContainsKey($candidate)) {
          $anchorCache[$candidate] = @(Get-MarkdownAnchors -Path $candidate)
        }
        if ($fragment.ToLowerInvariant() -notin $anchorCache[$candidate]) {
          $lineNumber = ([regex]::Matches($text.Substring(0, $linkMatch.Index), "\n")).Count + 1
          $failures.Add("缺失锚点: ${relativePath}:${lineNumber} -> ${target}")
        }
      }
    }
  }

  $rulePaths = @($documentPaths | Where-Object {
    $_ -eq 'docs/core.md' -or $_ -match '(^|/)(AGENTS|SKILL)\.md$'
  })
  $ruleLines = foreach ($relativePath in $rulePaths) {
    $fullPath = Join-Path $repoRoot $relativePath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
      continue
    }
    foreach ($line in Get-Content -LiteralPath $fullPath) {
      $normalized = [regex]::Replace($line.Trim(), '\s+', ' ')
      if ($normalized.Length -ge 28 -and $normalized.StartsWith('- ')) {
        [pscustomobject]@{ Rule = $normalized; Path = $relativePath }
      }
    }
  }
  $duplicateRuleGroups = @($ruleLines | Group-Object Rule | Where-Object { $_.Count -gt 1 })

  $rootAgentCharacters = (Get-Content -LiteralPath (Join-Path $repoRoot 'AGENTS.md') -Raw).Length
  $coreCharacters = (Get-Content -LiteralPath (Join-Path $repoRoot 'docs/core.md') -Raw).Length
  $largestDocuments = @($documentSizes | Sort-Object Characters -Descending | Select-Object -First 5)

  Write-Host 'ENTRY_CHAIN=AGENTS.md -> nearest AGENTS.md -> target header/types/tests -> docs/development/README.md -> one core section'
  Write-Host "DOCUMENTATION_FILES=$($documentPaths.Count)"
  Write-Host "DOCUMENTATION_CHARS=$totalCharacters"
  Write-Host "ROOT_AGENT_CHARS=$rootAgentCharacters"
  Write-Host "CORE_CHARS=$coreCharacters"
  Write-Host "RELATIVE_LINKS=$checkedLinks"
  Write-Host "ANCHORS=$checkedAnchors"
  Write-Host "CORE_DOC_FILES=$($actualCoreDocs.Count)"
  Write-Host "SUSPECTED_DUPLICATE_RULES=$($duplicateRuleGroups.Count)"
  foreach ($document in $largestDocuments) {
    Write-Host "LARGEST_DOCUMENT=$($document.Path) chars=$($document.Characters)"
  }
  foreach ($group in $duplicateRuleGroups | Select-Object -First 5) {
    $paths = ($group.Group.Path | Sort-Object -Unique) -join ','
    Write-Host "DUPLICATE_RULE=count=$($group.Count) paths=$paths"
  }
  Write-Host "FAILURES=$($failures.Count)"
  if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "ERROR: $_" }
    exit 1
  }
}
finally {
  Pop-Location
}
