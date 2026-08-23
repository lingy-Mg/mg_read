[CmdletBinding()]
param(
    [ValidateSet('small', 'large')]
    [string]$ChangeType = 'small',

    [string]$AgentsPath = (Join-Path $PSScriptRoot '..\AGENTS.md')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedAgentsPath = [System.IO.Path]::GetFullPath(
    (Resolve-Path -LiteralPath $AgentsPath).Path
)
$content = [System.IO.File]::ReadAllText($resolvedAgentsPath)
$pattern = '(?m)^<!-- AGENTS_VERSION: (?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+) -->\r?$'
$matches = [System.Text.RegularExpressions.Regex]::Matches($content, $pattern)

if ($matches.Count -ne 1) {
    throw "Expected exactly one AGENTS_VERSION marker in '$resolvedAgentsPath', found $($matches.Count)."
}

$marker = $matches[0]
$major = [int]$marker.Groups['major'].Value
$minor = [int]$marker.Groups['minor'].Value
$patch = [int]$marker.Groups['patch'].Value

if ($major -ne 0) {
    throw "AGENTS.md version must use the 0.x.y format; found $major.$minor.$patch."
}

$oldVersion = "$major.$minor.$patch"
if ($ChangeType -eq 'small') {
    $patch++
} else {
    $minor++
    $patch = 0
}

$newVersion = "$major.$minor.$patch"
$newMarker = "<!-- AGENTS_VERSION: $newVersion -->"
$updatedContent = $content.Substring(0, $marker.Index) +
    $newMarker +
    $content.Substring($marker.Index + $marker.Length)

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($resolvedAgentsPath, $updatedContent, $utf8NoBom)

Write-Output "AGENTS.md version: $oldVersion -> $newVersion ($ChangeType change)"
