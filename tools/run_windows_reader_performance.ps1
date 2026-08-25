[CmdletBinding()]
param(
    [ValidateRange(60, 3600)]
    [int]$TimeoutSeconds = 1800
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$target = 'integration_test/reader_first_content_performance_test.dart'
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$artifactDirectory = Join-Path $projectRoot "artifacts/integration-tests/windows-reader-profile-$runId"
New-Item -ItemType Directory -Force -Path $artifactDirectory | Out-Null
$originalOutputDirectory = $env:FLUTTER_TEST_OUTPUTS_DIR
$env:FLUTTER_TEST_OUTPUTS_DIR = $artifactDirectory

try {
    Push-Location $projectRoot
    & flutter drive `
        --device-id windows `
        --profile `
        --target $target `
        --driver test_driver/android_integration_test.dart `
        --timeout $TimeoutSeconds `
        --no-pub
    $exitCode = $LASTEXITCODE
}
finally {
    Pop-Location
    $env:FLUTTER_TEST_OUTPUTS_DIR = $originalOutputDirectory
}

$result = [ordered]@{
    platform = 'windows'
    buildMode = 'profile'
    target = $target
    exitCode = $exitCode
    completedAt = (Get-Date).ToUniversalTime().ToString('o')
}
$result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $artifactDirectory 'result.json') -Encoding utf8
Write-Host "Windows reader Profile artifacts: $artifactDirectory"
exit $exitCode
