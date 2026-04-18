param(
    [string]$ArtifactDirectory = $(Join-Path $env:TEMP ("cmux-ghostty-embed-spike-" + [guid]::NewGuid().Guid)),
    [string]$OutputPath = '',
    [string]$GhosttyRoot = $(Join-Path $PSScriptRoot '..\..\ghostty'),
    [string]$Command = 'echo embedded-libghostty-spike && echo proof-line'
)

$ErrorActionPreference = 'Stop'

$ghosttyRootPath = (Resolve-Path $GhosttyRoot).Path
$ghosttyInclude = Join-Path $ghosttyRootPath 'zig-out\include'
$ghosttyLibrary = Join-Path $ghosttyRootPath 'zig-out\lib\libghostty.so'
$ghosttyResources = Join-Path $ghosttyRootPath 'zig-out\share\ghostty'
$sourcePath = Join-Path $PSScriptRoot 'windows-libghostty-embed-spike.c'
$artifactPath = New-Item -ItemType Directory -Force -Path $ArtifactDirectory
$resolvedOutputPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    Join-Path $artifactPath.FullName 'cmux-ghostty-embed-spike.exe'
} else {
    $OutputPath
}
$fontconfigPath = Join-Path $artifactPath.FullName 'fonts.conf'
$fontconfigConfDir = Join-Path $artifactPath.FullName 'conf.d'

if (-not (Test-Path $ghosttyInclude)) {
    throw "Ghostty include directory not found: $ghosttyInclude"
}
if (-not (Test-Path $ghosttyLibrary)) {
    throw "Ghostty shared library not found: $ghosttyLibrary"
}
if (-not (Test-Path $ghosttyResources)) {
    throw "Ghostty resources directory not found: $ghosttyResources"
}

$fontconfigPackage = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'zig\p') -Recurse -File -Filter 'fonts.conf.in' |
    Select-Object -First 1
if (-not $fontconfigPackage) {
    throw 'Could not locate cached fontconfig package source'
}
$fontconfigPackageRoot = Split-Path -Parent $fontconfigPackage.FullName
New-Item -ItemType Directory -Force -Path $fontconfigConfDir | Out-Null
Copy-Item -Path (Join-Path $fontconfigPackageRoot 'conf.d\*') -Destination $fontconfigConfDir -Recurse -Force

$fontconfigContents = @"
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <description>cmux embedded ghostty spike</description>
  <dir>C:/Windows/Fonts</dir>
  <dir prefix="xdg">fonts</dir>
  <include ignore_missing="yes">$($fontconfigConfDir -replace '\\','/')</include>
  <cachedir>LOCAL_APPDATA_FONTCONFIG_CACHE</cachedir>
  <cachedir prefix="xdg">fontconfig</cachedir>
</fontconfig>
"@
Set-Content -Path $fontconfigPath -Value $fontconfigContents -Encoding ascii

$zig = (Get-Command zig -ErrorAction Stop).Source

& $zig cc `
    $sourcePath `
    -I $ghosttyInclude `
    -o $resolvedOutputPath `
    -lgdi32 `
    -lopengl32 `
    -luser32 `
    -limm32 `
    -lshell32 `
    -lole32 `
    -luuid

$env:CMUX_SMOKE_ARTIFACT_DIR = $artifactPath.FullName
$env:CMUX_GHOSTTY_EMBED_COMMAND = $Command
$env:CMUX_GHOSTTY_LIB = $ghosttyLibrary
$env:GHOSTTY_RESOURCES_DIR = $ghosttyResources
$env:FONTCONFIG_FILE = $fontconfigPath
$env:FONTCONFIG_PATH = $artifactPath.FullName

& $resolvedOutputPath

if ($LASTEXITCODE -ne 0) {
    throw "Embedded Ghostty spike failed with exit code $LASTEXITCODE"
}

$reportPath = Join-Path $artifactPath.FullName 'embedded-ghostty-report.json'
$transcriptPath = Join-Path $artifactPath.FullName 'embedded-ghostty-transcript.txt'

if (-not (Test-Path $reportPath)) {
    throw "Embedded Ghostty report not found: $reportPath"
}
if (-not (Test-Path $transcriptPath)) {
    throw "Embedded Ghostty transcript not found: $transcriptPath"
}

$report = Get-Content -Raw -Path $reportPath | ConvertFrom-Json
if (-not $report.transcriptContainsExpectedMarker) {
    throw "Embedded Ghostty transcript did not contain the expected marker"
}
if (-not $report.childExitSeen) {
    throw "Embedded Ghostty report did not record child exit"
}
if ($report.childExitCode -ne 0) {
    throw "Embedded Ghostty report recorded non-zero child exit code: $($report.childExitCode)"
}

Write-Host "Embedded Ghostty spike passed. Artifacts: $($artifactPath.FullName)"
