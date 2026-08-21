[CmdletBinding(DefaultParameterSetName = 'Single')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('127.0.0.1:7555', 'emulator-5556')]
    [string]$DeviceId,

    [Parameter(ParameterSetName = 'Single')]
    [ValidatePattern('^integration_test[\\/].+\.dart$')]
    [string]$Target = 'integration_test/android_plugin_runtime_test.dart',

    [Parameter(Mandatory, ParameterSetName = 'All')]
    [switch]$All,

    [ValidateRange(1, 3600)]
    [int]$TimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$adb = Get-Command adb -ErrorAction Stop

$deviceState = (& $adb.Source -s $DeviceId get-state).Trim()
if ($LASTEXITCODE -ne 0 -or $deviceState -ne 'device') {
    throw "Android emulator '$DeviceId' is not connected and ready. Start it yourself, then rerun this command."
}

$avdName = if ($DeviceId -eq '127.0.0.1:7555') {
    'user-approved-local-android-target'
}
else {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $avdName = (& $adb.Source -s $DeviceId emu avd name 2>$null | Out-String).Trim()
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($avdName)) {
        # `emulator-5556` is explicitly allowlisted above and was confirmed by
        # the caller. Some emulator-compatible Android hosts expose a device
        # shell but not the optional AVD console command.
        $avdName = 'user-approved-emulator-5556'
    }
    $avdName
}
if ([string]::IsNullOrWhiteSpace($avdName) -or $avdName -match 'unknown command') {
    throw "'$DeviceId' is not a connected user-approved Android test target. No test was started."
}

if ($All) {
    $targets = Get-ChildItem -LiteralPath (Join-Path $projectRoot 'integration_test') -Filter '*.dart' -File -Recurse |
        ForEach-Object { $_.FullName.Substring($projectRoot.Length + 1).Replace('\', '/') } |
        Sort-Object
}
else {
    $targets = @($Target.Replace('\', '/'))
}

if ($targets.Count -eq 0) {
    throw 'No Integration Test targets were found. No test was started.'
}

$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$artifactDirectory = Join-Path $projectRoot "artifacts/integration-tests/$runId"
New-Item -ItemType Directory -Force -Path $artifactDirectory | Out-Null
$originalOutputDirectory = $env:FLUTTER_TEST_OUTPUTS_DIR
$testExitCode = 0

try {
    Push-Location $projectRoot
    foreach ($testTarget in $targets) {
        $targetName = ($testTarget -replace '[^A-Za-z0-9._-]', '_') -replace '\.dart$', ''
        $testArtifactDirectory = Join-Path $artifactDirectory $targetName
        New-Item -ItemType Directory -Force -Path $testArtifactDirectory | Out-Null
        $env:FLUTTER_TEST_OUTPUTS_DIR = $testArtifactDirectory
        $result = [ordered]@{
            deviceId = $DeviceId
            avdName = $avdName
            target = $testTarget
            startedAt = (Get-Date).ToUniversalTime().ToString('o')
            status = 'running'
        }

        Write-Host "Running Android Integration Test on user-provided $DeviceId ($avdName): $testTarget"
        & flutter drive `
            --device-id $DeviceId `
            --target $testTarget `
            --driver test_driver/android_integration_test.dart `
            --timeout $TimeoutSeconds `
            --no-pub
        $commandExitCode = $LASTEXITCODE
        $result.exitCode = $commandExitCode
        $result.completedAt = (Get-Date).ToUniversalTime().ToString('o')
        $result.status = if ($commandExitCode -eq 0) { 'passed' } else { 'failed' }
        $result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $testArtifactDirectory 'result.json') -Encoding utf8

        if ($commandExitCode -ne 0) {
            $testExitCode = $commandExitCode
            break
        }
    }
}
finally {
    Pop-Location
    $env:FLUTTER_TEST_OUTPUTS_DIR = $originalOutputDirectory
}

Write-Host "Integration Test artifacts: $artifactDirectory"
if ($testExitCode -ne 0) {
    exit $testExitCode
}
