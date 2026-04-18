param(
    [string]$OutputPath = $(Join-Path $env:TEMP ("cmux_windows_slice_" + [guid]::NewGuid().Guid + '.exe')),
    [switch]$Run,
    [string]$SwiftRoot = $env:CMUX_SWIFT_ROOT,
    [string]$SwiftVersion = $env:CMUX_SWIFT_VERSION,
    [string]$MsvcVersion = $env:CMUX_MSVC_VERSION,
    [string]$BootstrapCommand = $env:CMUX_WINDOWS_COMMAND,
    [string]$BootstrapValue = $env:CMUX_WINDOWS_COMMAND_VALUE,
    [string]$BootstrapTitle = $env:CMUX_WINDOWS_COMMAND_TITLE,
    [string]$SmokeOutputPath = $env:CMUX_SMOKE_OUTPUT_PATH,
    [string]$ArtifactDirectory = $env:CMUX_SMOKE_ARTIFACT_DIR
)

$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
. (Join-Path $PSScriptRoot 'windows-slice-toolchain.ps1')
$null = Initialize-CmuxWindowsSliceToolchain `
    -RepoRoot $repoRoot.Path `
    -SwiftRoot $SwiftRoot `
    -SwiftVersion $SwiftVersion `
    -MsvcVersion $MsvcVersion

$manifestPath = Join-Path $PSScriptRoot 'windows-slice-sources.txt'
if (-not (Test-Path $manifestPath)) {
    throw "Windows slice source manifest not found: $manifestPath"
}

$sourceFiles = Get-Content -Path $manifestPath | Where-Object {
    $trimmed = $_.Trim()
    $trimmed -and -not $trimmed.StartsWith('#')
}

$absoluteSources = $sourceFiles | ForEach-Object { Join-Path $repoRoot $_ }
$browserHelperPath = Join-Path (Split-Path -Parent $OutputPath) 'cmux_windows_webview2_spike.exe'
$browserChildHelperPath = Join-Path (Split-Path -Parent $OutputPath) 'cmux_windows_webview2_child_host.exe'
$shellHostHelperPath = Join-Path (Split-Path -Parent $OutputPath) 'cmux_windows_shell_host_spike.exe'

Push-Location $repoRoot
try {
    swiftc @absoluteSources -o $OutputPath
    & (Join-Path $PSScriptRoot 'build-windows-webview2-spike.ps1') -OutputPath $browserHelperPath | Out-Null
    & (Join-Path $PSScriptRoot 'build-windows-webview2-child-host.ps1') -OutputPath $browserChildHelperPath | Out-Null
    & (Join-Path $PSScriptRoot 'build-windows-shell-host-spike.ps1') -OutputPath $shellHostHelperPath | Out-Null
    Write-Host "Built $OutputPath"
    Write-Host "Built $browserHelperPath"
    Write-Host "Built $browserChildHelperPath"
    Write-Host "Built $shellHostHelperPath"

    if ($Run) {
        if (-not [string]::IsNullOrWhiteSpace($BootstrapCommand)) {
            $env:CMUX_WINDOWS_COMMAND = $BootstrapCommand
        }
        if (-not [string]::IsNullOrWhiteSpace($BootstrapValue)) {
            $env:CMUX_WINDOWS_COMMAND_VALUE = $BootstrapValue
        }
        if (-not [string]::IsNullOrWhiteSpace($BootstrapTitle)) {
            $env:CMUX_WINDOWS_COMMAND_TITLE = $BootstrapTitle
        }
        if (-not [string]::IsNullOrWhiteSpace($SmokeOutputPath)) {
            $env:CMUX_SMOKE_OUTPUT_PATH = $SmokeOutputPath
        }
        if (-not [string]::IsNullOrWhiteSpace($ArtifactDirectory)) {
            $env:CMUX_SMOKE_ARTIFACT_DIR = $ArtifactDirectory
        }
        $env:CMUX_WINDOWS_BROWSER_HELPER_EXE = $browserHelperPath
        $env:CMUX_WINDOWS_BROWSER_CHILD_HELPER_EXE = $browserChildHelperPath
        $env:CMUX_WINDOWS_SHELL_HOST_HELPER_EXE = $shellHostHelperPath
        & $OutputPath
    }
}
finally {
    Pop-Location
}
