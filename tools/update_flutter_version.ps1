[CmdletBinding()]
param(
    [ValidateSet('small', 'large')]
    [string]$ChangeType = 'small',

    [string]$PubspecPath = (Join-Path $PSScriptRoot '..\pubspec.yaml')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedPubspecPath = [System.IO.Path]::GetFullPath(
    (Resolve-Path -LiteralPath $PubspecPath).Path
)
$content = [System.IO.File]::ReadAllText($resolvedPubspecPath)
$pattern = '(?m)^version:\s*(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(?:\+(?<build>\d+))?\r?$'
$matches = [System.Text.RegularExpressions.Regex]::Matches($content, $pattern)

if ($matches.Count -ne 1) {
    throw "Expected exactly one Flutter version in '$resolvedPubspecPath', found $($matches.Count)."
}

$match = $matches[0]
$major = [int]$match.Groups['major'].Value
$minor = [int]$match.Groups['minor'].Value
$patch = [int]$match.Groups['patch'].Value

if ($major -ne 0) {
    throw "Flutter application version must use the 0.x.y format; found $major.$minor.$patch."
}

$oldVersion = "$major.$minor.$patch"
if ($ChangeType -eq 'small') {
    $patch++
} else {
    $minor++
    $patch = 0
}

$newVersion = "$major.$minor.$patch"
$buildSuffix = ''
if ($match.Groups['build'].Success) {
    $build = [int]$match.Groups['build'].Value + 1
    $buildSuffix = "+$build"
}

$newLine = "version: $newVersion$buildSuffix"
$updatedContent = $content.Substring(0, $match.Index) +
    $newLine +
    $content.Substring($match.Index + $match.Length)

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($resolvedPubspecPath, $updatedContent, $utf8NoBom)

Write-Output "Flutter version: $oldVersion$($match.Groups['build'].Value | ForEach-Object { if ($_ -ne '') { "+$_" } }) -> $newVersion$buildSuffix ($ChangeType change)"
