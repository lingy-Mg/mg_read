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
$androidApplicationId = 'com.mgread.mg_read'
$runtimeNodeRoot = Join-Path $projectRoot 'packages/mg_read_runtime/tools/node-v24.16.0-win-x64'
$runtimeNpm = Join-Path $runtimeNodeRoot 'npm.cmd'

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

if (-not (Test-Path -LiteralPath $runtimeNpm -PathType Leaf)) {
    throw 'The pinned Runtime npm toolchain is unavailable. No Android test was started.'
}

$developmentPluginArtifacts = @()
$pluginSourceDirectories = @(
    (Join-Path $projectRoot 'plugins/sources/aisishuwu'),
    (Join-Path $projectRoot 'plugins/sources/mgread-discovery-demo')
)
$originalPath = $env:PATH
try {
    $env:PATH = "$runtimeNodeRoot;$env:PATH"
    foreach ($pluginSourceDirectory in $pluginSourceDirectories) {
        $packageJsonPath = Join-Path $pluginSourceDirectory 'package.json'
        $packageJson = Get-Content -LiteralPath $packageJsonPath -Raw | ConvertFrom-Json
        $artifactName = "$($packageJson.mgread.id)-$($packageJson.version).mgplugin"
        Push-Location $pluginSourceDirectory
        try {
            & $runtimeNpm run verify
            if ($LASTEXITCODE -ne 0) {
                throw "Android test plugin packaging failed for '$($packageJson.mgread.id)'."
            }
        }
        finally {
            Pop-Location
        }
        $artifactPath = Join-Path $pluginSourceDirectory "artifacts/$artifactName"
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
            throw "Android test plugin artifact '$artifactName' was not created."
        }
        $developmentPluginArtifacts += Get-Item -LiteralPath $artifactPath
    }
}
finally {
    $env:PATH = $originalPath
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
        & flutter build apk --debug --target $testTarget --no-pub
        if ($LASTEXITCODE -ne 0) {
            throw "Android Integration Test APK build failed for '$testTarget'."
        }
        $testApk = Join-Path $projectRoot 'build/app/outputs/flutter-apk/app-debug.apk'
        & $adb.Source -s $DeviceId install -r -t $testApk
        if ($LASTEXITCODE -ne 0) {
            throw "Android Integration Test APK installation failed for '$testTarget'."
        }
        & $adb.Source -s $DeviceId shell run-as $androidApplicationId mkdir -p files/mgread-runtime/import-inbox
        if ($LASTEXITCODE -ne 0) {
            throw 'The debug application plugin inbox could not be created.'
        }
        foreach ($pluginArtifact in $developmentPluginArtifacts) {
            $deviceTemporaryPath = "/data/local/tmp/$($pluginArtifact.Name)"
            $applicationInboxPath = "files/mgread-runtime/import-inbox/$($pluginArtifact.Name)"
            & $adb.Source -s $DeviceId push $pluginArtifact.FullName $deviceTemporaryPath
            if ($LASTEXITCODE -ne 0) {
                throw "ADB could not push '$($pluginArtifact.Name)'."
            }
            & $adb.Source -s $DeviceId shell run-as $androidApplicationId rm -f $applicationInboxPath
            if ($LASTEXITCODE -ne 0) {
                throw "The previous Android test plugin '$($pluginArtifact.Name)' could not be cleared."
            }
            & $adb.Source -s $DeviceId shell run-as $androidApplicationId cp $deviceTemporaryPath $applicationInboxPath
            if ($LASTEXITCODE -ne 0) {
                throw "The Android application could not receive '$($pluginArtifact.Name)'."
            }
            & $adb.Source -s $DeviceId shell rm -f $deviceTemporaryPath
            if ($LASTEXITCODE -ne 0) {
                throw "The temporary ADB plugin '$($pluginArtifact.Name)' could not be removed."
            }
        }
        & flutter drive `
            --device-id $DeviceId `
            --target $testTarget `
            --driver test_driver/android_integration_test.dart `
            --use-application-binary $testApk `
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
