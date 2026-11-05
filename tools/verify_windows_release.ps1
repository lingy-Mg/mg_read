<#
Verifies the actual Flutter release directory before local/CI packaging.
Runs the existing Node/Bun contracts with the pinned repository Node, preserves
the caller's environment, and never uses a user's Runtime data directory.
#>
[CmdletBinding()]
param([string]$InputDirectory = 'build/windows/x64/runner/Release')
$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$releaseRoot = (Resolve-Path -LiteralPath $InputDirectory).Path
$runtimeRoot = Join-Path $releaseRoot 'data/flutter_assets/packages/mgread_plugin_runtime/assets/runtime/windows-x64'
$packageRoot = Join-Path $repositoryRoot 'packages/mg_read_node_runtime'
$node = Join-Path $packageRoot 'tools/node-v26.10.0-win-x64/node.exe'
$previousNodeRoot = $env:MGREAD_WINDOWS_BUNDLE_ROOT
$previousBunRoot = $env:MGREAD_BUN_BUNDLE_ROOT
$previousBunExecutable = $env:MGREAD_BUN_EXECUTABLE
try {
  $env:MGREAD_WINDOWS_BUNDLE_ROOT = $runtimeRoot
  $env:MGREAD_BUN_BUNDLE_ROOT = $runtimeRoot
  $env:MGREAD_BUN_EXECUTABLE = Join-Path $runtimeRoot 'node/MgReadBun.exe'
  foreach ($check in @('verify-staged-windows-runtime.mjs', 'verify-staged-bun-runtime.mjs')) {
    & $node --test (Join-Path $packageRoot "tools/$check")
    if ($LASTEXITCODE -ne 0) { throw "Windows release verification failed: $check" }
  }
} finally {
  $env:MGREAD_WINDOWS_BUNDLE_ROOT = $previousNodeRoot
  $env:MGREAD_BUN_BUNDLE_ROOT = $previousBunRoot
  $env:MGREAD_BUN_EXECUTABLE = $previousBunExecutable
}
