param(
    [string]$OutputRoot = $(Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')) 'dist\windows-lane'),
    [string]$ArchiveRoot = $(Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')) 'dist\releases'),
    [string]$VersionLabel = '',
    [string]$ReleaseLabel = '',
    [string]$SwiftRoot = $env:CMUX_SWIFT_ROOT,
    [string]$SwiftVersion = $env:CMUX_SWIFT_VERSION,
    [string]$MsvcVersion = $env:CMUX_MSVC_VERSION,
    [switch]$SkipGhosttyBuild
)

$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$projectRoot = Resolve-Path (Join-Path $repoRoot '..')

if (-not $SkipGhosttyBuild) {
    Push-Location (Join-Path $projectRoot 'ghostty')
    try {
        zig build -j1
    }
    finally {
        Pop-Location
    }
}

& (Join-Path $PSScriptRoot 'package-windows-lane.ps1') `
    -OutputRoot $OutputRoot `
    -SwiftRoot $SwiftRoot `
    -SwiftVersion $SwiftVersion `
    -MsvcVersion $MsvcVersion `
    -VersionLabel $VersionLabel `
    -ReleaseLabel $ReleaseLabel | Out-Null

$buildInfoPath = Join-Path $OutputRoot 'build-info.json'
if (-not (Test-Path $buildInfoPath)) {
    throw "Expected build-info.json at $buildInfoPath"
}

$buildInfo = Get-Content $buildInfoPath -Raw | ConvertFrom-Json
New-Item -ItemType Directory -Force -Path $ArchiveRoot | Out-Null
$archivePath = Join-Path $ArchiveRoot ([string]$buildInfo.artifactName)
if (Test-Path $archivePath) {
    Remove-Item -Force $archivePath
}
Compress-Archive -Path (Join-Path $OutputRoot '*') -DestinationPath $archivePath -CompressionLevel Optimal

Write-Host "Packaged Windows release at $OutputRoot"
Write-Host "Release archive: $archivePath"
