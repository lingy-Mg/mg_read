<#
.SYNOPSIS
Run Android integration tests against the selected Runtime backend.

.DESCRIPTION
Builds and installs a test APK on an explicitly selected connected device.
Javet remains the default; the private Node process requires arm64-v8a and
uses Core CLI's private import inbox. Results are saved per target.
#>
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
    [int]$TimeoutSeconds = 600,

    [ValidateSet('debug', 'profile')]
    [string]$BuildMode = 'debug',

    [ValidateSet('javet', 'node-process')]
    [string]$AndroidBackend = 'javet'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$adb = Get-Command adb -ErrorAction Stop
$androidApplicationId = 'com.mgread.mg_read'
$runtimeNodeRoot = Join-Path $projectRoot 'packages/mg_read_node_runtime/tools/node-v26.10.0-win-x64'
$runtimeNpm = Join-Path $runtimeNodeRoot 'npm.cmd'
$runtimeNode = Join-Path $runtimeNodeRoot 'node.exe'

$deviceStateOutput = & $adb.Source -s $DeviceId get-state 2>$null | Out-String
$deviceStateExitCode = $LASTEXITCODE
$deviceState = $deviceStateOutput.Trim()
if ($deviceStateExitCode -ne 0 -or $deviceState -ne 'device') {
    throw "Android emulator '$DeviceId' is not connected and ready. Start it yourself, then rerun this command."
}
if ($AndroidBackend -eq 'node-process') {
    $deviceAbi = (& $adb.Source -s $DeviceId shell getprop ro.product.cpu.abi | Out-String).Trim()
    $deviceAbiList = (& $adb.Source -s $DeviceId shell getprop ro.product.cpu.abilist | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or 'arm64-v8a' -notin $deviceAbiList.Split(',')) {
        throw "Android Node process tests require arm64-v8a support; '$DeviceId' reports '$deviceAbiList'."
    }
    if ($deviceAbi -ne 'arm64-v8a' -and $BuildMode -eq 'debug') {
        throw "Android Node process tests on an arm64-translating emulator require -BuildMode profile so the APK is arm64-only."
    }
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

$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$artifactDirectory = Join-Path $projectRoot "artifacts/integration-tests/$runId"
New-Item -ItemType Directory -Force -Path $artifactDirectory | Out-Null

$developmentPluginArtifacts = @()
$pluginSourceDirectories = @()
if ($All -or $targets -contains 'integration_test/android_plugin_runtime_test.dart') {
    $pluginSourceDirectories += Join-Path $projectRoot 'plugins/sources/aisishuwu'
}
$originalPath = $env:PATH
try {
    $env:PATH = "$runtimeNodeRoot;$env:PATH"
    foreach ($pluginSourceDirectory in $pluginSourceDirectories) {
        $packageJsonPath = Join-Path $pluginSourceDirectory 'package.json'
        $packageJson = Get-Content -LiteralPath $packageJsonPath -Raw | ConvertFrom-Json
        $packageMode = [string]$packageJson.mgread.packageMode
        $artifactSuffix = switch ($packageMode) {
            'archive' { '.mgplugin' }
            'single-file' { '.mgplugin.js' }
            default { throw "Unsupported MgRead package mode '$packageMode' for '$($packageJson.mgread.id)'." }
        }
        $artifactName = "$($packageJson.mgread.id)-$($packageJson.version)$artifactSuffix"
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

if ($All -or $targets -contains 'integration_test/android_browser_session_test.dart' -or
    $targets -contains 'integration_test/android_plugin_runtime_test.dart') {
    $fixturePath = Join-Path $artifactDirectory 'org.mgread.android-runtime-fixture-1.0.0.mgplugin.js'
    & $runtimeNode (Join-Path $projectRoot 'tools/build_android_runtime_fixture.mjs') $fixturePath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
        throw 'Android Runtime fixture packaging failed.'
    }
    $developmentPluginArtifacts += Get-Item -LiteralPath $fixturePath
}
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
            androidBackend = $AndroidBackend
            target = $testTarget
            buildMode = $BuildMode
            startedAt = (Get-Date).ToUniversalTime().ToString('o')
            status = 'running'
        }

        Write-Host "Running Android Integration Test on user-provided $DeviceId ($avdName): $testTarget"
        $buildModeFlag = "--$BuildMode"
        $buildArguments = @('build', 'apk', $buildModeFlag, '--target', $testTarget, '--no-pub')
        if ($AndroidBackend -eq 'node-process') {
            $buildArguments += @('--target-platform', 'android-arm64', '--dart-define=MGREAD_ANDROID_NODE_PROCESS=true')
        }
        & flutter @buildArguments
        if ($LASTEXITCODE -ne 0) {
            throw "Android Integration Test APK build failed for '$testTarget'."
        }
        $testApk = Join-Path $projectRoot "build/app/outputs/flutter-apk/app-$BuildMode.apk"
        & $adb.Source -s $DeviceId install -r -t $testApk
        if ($LASTEXITCODE -ne 0) {
            throw "Android Integration Test APK installation failed for '$testTarget'."
        }
        $inboxPath = if ($AndroidBackend -eq 'node-process') {
            'files/mgread-runtime/data/import-inbox'
        } else {
            'files/mgread-runtime/import-inbox'
        }
        & $adb.Source -s $DeviceId shell run-as $androidApplicationId mkdir -p $inboxPath
        if ($LASTEXITCODE -ne 0) {
            throw 'The debug application plugin inbox could not be created.'
        }
        foreach ($pluginArtifact in $developmentPluginArtifacts) {
            $deviceTemporaryPath = "/data/local/tmp/$($pluginArtifact.Name)"
            $applicationInboxPath = "$inboxPath/$($pluginArtifact.Name)"
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
        $driveArguments = @(
            'drive',
            '--device-id', $DeviceId,
            '--target', $testTarget,
            '--driver', 'test_driver/android_integration_test.dart',
            '--use-application-binary', $testApk,
            '--timeout', $TimeoutSeconds,
            '--no-pub'
        )
        if ($BuildMode -eq 'profile') {
            $driveArguments += '--profile'
        }
        & flutter @driveArguments
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
