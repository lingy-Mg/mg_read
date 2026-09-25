<#
.SYNOPSIS
Build the independent Rust worker; no Node/npm is used.
.DESCRIPTION
Owns reproducible host compilation and staging only. Does not build Flutter or
install devices. Native libraries use Android API 24 and 16 KiB ELF alignment.
#>
[CmdletBinding()]
param(
    [ValidateSet('windows','android','all')][string]$Platform='all',
    [string]$NdkRoot="$env:LOCALAPPDATA/Android/Sdk/ndk/28.2.13676358"
)
$ErrorActionPreference='Stop'
$nativeRepo=Split-Path -Parent $PSScriptRoot
$nativePackage=Join-Path $nativeRepo 'packages/mg_read_native_runtime'
$nativeLogs=Join-Path $nativeRepo 'artifacts/native-runtime'
New-Item -ItemType Directory -Force -Path $nativeLogs | Out-Null
function Build-NativeTarget([string]$Target,[string]$Abi) {
    $nativeLog=Join-Path $nativeLogs "build-host-$Target.log"
    $nativeArgs=@('build','--manifest-path',"$nativePackage/Cargo.toml",'--locked','--release','--target',$Target)
    if($Target -like '*android'){$nativeArgs+='--lib'}else{$nativeArgs+=@('--bin','mgread-native-host')}
    & cargo '+1.97.1' @nativeArgs *> $nativeLog
    if($LASTEXITCODE -ne 0){Get-Content -LiteralPath $nativeLog -Tail 35;throw "Native build failed: $Target"}
    if($Target -like '*android'){
        $nativeOut=Join-Path $nativeRepo "packages/mgread_plugin_runtime/android/src/native/jniLibs/$Abi"
        New-Item -ItemType Directory -Force -Path $nativeOut | Out-Null
        Copy-Item -LiteralPath "$nativePackage/target/$Target/release/libmgread_native_runtime.so" -Destination "$nativeOut/libmgread_native_runtime.so"
    }else{
        $nativeOut=Join-Path $nativePackage 'dist/windows-x86_64'
        New-Item -ItemType Directory -Force -Path $nativeOut | Out-Null
        Copy-Item -LiteralPath "$nativePackage/target/$Target/release/mgread-native-host.exe" -Destination "$nativeOut/mgread-native-host.exe"
    }
    Write-Host "PASS native host $Target"
}
if($Platform -in @('windows','all')){Build-NativeTarget 'x86_64-pc-windows-msvc' ''}
if($Platform -in @('android','all')){
    $nativeBin=Join-Path $NdkRoot 'toolchains/llvm/prebuilt/windows-x86_64/bin'
    if(-not(Test-Path -LiteralPath "$nativeBin/clang.exe")){throw 'Android NDK compiler is unavailable'}
    $nativeEnvNames=@('CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER','CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER','CC_aarch64_linux_android','CC_x86_64_linux_android','AR_aarch64_linux_android','AR_x86_64_linux_android','RUSTFLAGS')
    $nativeSaved=@{}
    foreach($name in $nativeEnvNames){$nativeSaved[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
    try {
        $env:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$nativeBin/aarch64-linux-android24-clang.cmd"
        $env:CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER="$nativeBin/x86_64-linux-android24-clang.cmd"
        $env:CC_aarch64_linux_android=$env:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER
        $env:CC_x86_64_linux_android=$env:CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER
        $env:AR_aarch64_linux_android="$nativeBin/llvm-ar.exe"
        $env:AR_x86_64_linux_android="$nativeBin/llvm-ar.exe"
        $env:RUSTFLAGS='-C link-arg=-Wl,-z,max-page-size=16384'
        Build-NativeTarget 'x86_64-linux-android' 'x86_64'
        Build-NativeTarget 'aarch64-linux-android' 'arm64-v8a'
    }finally{foreach($name in $nativeEnvNames){[Environment]::SetEnvironmentVariable($name,$nativeSaved[$name],'Process')}}
}
