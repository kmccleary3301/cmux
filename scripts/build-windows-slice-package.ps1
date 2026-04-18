param(
    [string]$PackageRoot = $(Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')) 'WindowsSlicePackage'),
    [string]$OutputPath = $(Join-Path $env:TEMP 'cmux_windows_slice_package.exe'),
    [string]$SwiftRoot = $env:CMUX_SWIFT_ROOT,
    [string]$SwiftVersion = $env:CMUX_SWIFT_VERSION,
    [string]$MsvcVersion = $env:CMUX_MSVC_VERSION,
    [switch]$Sync
)

$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
. (Join-Path $PSScriptRoot 'windows-slice-toolchain.ps1')
. (Join-Path $PSScriptRoot 'windows-slice-package-lock.ps1')
$null = Initialize-CmuxWindowsSliceToolchain `
    -RepoRoot $repoRoot.Path `
    -SwiftRoot $SwiftRoot `
    -SwiftVersion $SwiftVersion `
    -MsvcVersion $MsvcVersion

Invoke-CmuxWindowsSlicePackageLocked {
    if ($Sync -or -not (Test-Path (Join-Path $PackageRoot 'Package.swift'))) {
        & (Join-Path $PSScriptRoot 'sync-windows-slice-package.ps1') -PackageRoot $PackageRoot | Out-Null
    }

    Push-Location $PackageRoot
    try {
        swift build --product cmux-windows-slice

        $builtExe = Join-Path $PackageRoot '.build\debug\cmux-windows-slice.exe'
        if (-not (Test-Path $builtExe)) {
            throw "SwiftPM build did not produce expected executable: $builtExe"
        }

        $outputDirectory = Split-Path -Parent $OutputPath
        if ($outputDirectory) {
            New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
        }
        Copy-Item -Path $builtExe -Destination $OutputPath -Force
        $browserHelperPath = Join-Path $outputDirectory 'cmux_windows_webview2_spike.exe'
        $browserChildHelperPath = Join-Path $outputDirectory 'cmux_windows_webview2_child_host.exe'
        $shellHostHelperPath = Join-Path $outputDirectory 'cmux_windows_shell_host_spike.exe'
        & (Join-Path $PSScriptRoot 'build-windows-webview2-spike.ps1') `
            -OutputPath $browserHelperPath `
            -SwiftRoot $SwiftRoot `
            -SwiftVersion $SwiftVersion `
            -MsvcVersion $MsvcVersion | Out-Null
        & (Join-Path $PSScriptRoot 'build-windows-webview2-child-host.ps1') `
            -OutputPath $browserChildHelperPath `
            -SwiftRoot $SwiftRoot `
            -SwiftVersion $SwiftVersion `
            -MsvcVersion $MsvcVersion | Out-Null
        & (Join-Path $PSScriptRoot 'build-windows-shell-host-spike.ps1') `
            -OutputPath $shellHostHelperPath `
            -SwiftRoot $SwiftRoot `
            -SwiftVersion $SwiftVersion `
            -MsvcVersion $MsvcVersion | Out-Null
        Write-Host "Built $OutputPath"
        Write-Host "Built $browserHelperPath"
        Write-Host "Built $browserChildHelperPath"
        Write-Host "Built $shellHostHelperPath"
    }
    finally {
        Pop-Location
    }
}
