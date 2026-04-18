param(
    [string]$OutputPath = $(Join-Path $env:TEMP ("cmux_windows_shell_host_spike_" + [guid]::NewGuid().Guid + '.exe')),
    [string]$SwiftRoot = $env:CMUX_SWIFT_ROOT,
    [string]$SwiftVersion = $env:CMUX_SWIFT_VERSION,
    [string]$MsvcVersion = $env:CMUX_MSVC_VERSION
)

$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
. (Join-Path $PSScriptRoot 'windows-slice-toolchain.ps1')
$null = Initialize-CmuxWindowsSliceToolchain `
    -RepoRoot $repoRoot.Path `
    -SwiftRoot $SwiftRoot `
    -SwiftVersion $SwiftVersion `
    -MsvcVersion $MsvcVersion

$helperSource = Join-Path $PSScriptRoot 'windows-shell-host-spike.cpp'
$ghosttyInclude = Resolve-Path (Join-Path $repoRoot '..\ghostty\include')

foreach ($requiredPath in @($helperSource, $ghosttyInclude)) {
    if (-not (Test-Path $requiredPath)) {
        throw "Required shell-host spike dependency not found: $requiredPath"
    }
}

$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path $outputDirectory)) {
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
}

zig c++ `
    -std=c++17 `
    -I $ghosttyInclude `
    $helperSource `
    -o $OutputPath `
    -lgdi32 `
    -lopengl32 `
    -luser32 `
    -limm32 `
    -lshell32 `
    -lole32 `
    -lshlwapi `
    -luuid `
    -ladvapi32

if ($LASTEXITCODE -ne 0) {
    throw "Failed to build shell host spike helper"
}

Write-Host "Built $OutputPath"
