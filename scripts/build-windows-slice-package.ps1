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
        Write-Host "Built $OutputPath"
    }
    finally {
        Pop-Location
    }
}
