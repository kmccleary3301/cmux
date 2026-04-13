param(
    [string]$InstallRoot = $(Resolve-Path (Join-Path $PSScriptRoot '..')),
    [string]$RootArtifactDirectory = $(Join-Path $InstallRoot 'artifacts\smoke'),
    [string]$LogDirectory = $(Join-Path $InstallRoot 'logs')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows-slice-package-lock.ps1')

Invoke-CmuxWindowsSlicePackageLocked {
    New-Item -ItemType Directory -Force -Path $RootArtifactDirectory | Out-Null
    New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null

    $sliceExecutablePath = Join-Path $InstallRoot 'bin\cmux-windows-slice.exe'
    $ghosttyExecutablePath = Join-Path $InstallRoot 'bin\ghostty.exe'
    if (-not (Test-Path $sliceExecutablePath)) {
        $repoCandidate = Join-Path $env:TEMP 'cmux_windows_slice.exe'
        if (Test-Path $repoCandidate) {
            $sliceExecutablePath = $repoCandidate
        } else {
            throw "Slice executable not found at $sliceExecutablePath"
        }
    }
    if (-not (Test-Path $ghosttyExecutablePath)) {
        throw "Ghostty executable not found at $ghosttyExecutablePath"
    }

    $logPath = Join-Path $LogDirectory 'windows-lane-ci.log'
    Start-Transcript -Path $logPath -Force | Out-Null
    try {
        $previousGhosttyExecutablePath = $env:CMUX_GHOSTTY_EXE
        $env:CMUX_GHOSTTY_EXE = $ghosttyExecutablePath
        & (Join-Path $PSScriptRoot 'test-windows-all.ps1') `
            -RootArtifactDirectory $RootArtifactDirectory `
            -SliceExecutablePath $sliceExecutablePath
    }
    finally {
        if ($null -ne $previousGhosttyExecutablePath) {
            $env:CMUX_GHOSTTY_EXE = $previousGhosttyExecutablePath
        } else {
            Remove-Item Env:CMUX_GHOSTTY_EXE -ErrorAction SilentlyContinue
        }
        Stop-Transcript | Out-Null
    }
    Write-Host "Windows lane CI log: $logPath"
}
