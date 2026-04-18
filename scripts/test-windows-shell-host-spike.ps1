param(
    [string]$ArtifactDirectory = $(Join-Path $env:TEMP ("cmux-shell-host-spike-" + [guid]::NewGuid().Guid)),
    [string]$OutputPath = $(Join-Path $ArtifactDirectory 'cmux_windows_shell_host_spike.exe'),
    [string]$BrowserHelperPath = $(Join-Path $ArtifactDirectory 'cmux_windows_webview2_child_host.exe'),
    [string]$GhosttyRoot = $(Join-Path $PSScriptRoot '..\..\ghostty'),
    [string]$Command = 'echo shell-host-spike && echo proof-line',
    [string]$BrowserUrl = 'data:text/html,<html><head><title>DG3 Shell Host Spike</title></head><body>shell-host-browser</body></html>',
    [string]$BrowserTitle = 'DG3 Shell Host Spike'
)

$ErrorActionPreference = 'Stop'

$artifactPath = New-Item -ItemType Directory -Force -Path $ArtifactDirectory
$ghosttyRootPath = (Resolve-Path $GhosttyRoot).Path
$ghosttyLibrary = Join-Path $ghosttyRootPath 'zig-out\lib\libghostty.so'
$ghosttyResources = Join-Path $ghosttyRootPath 'zig-out\share\ghostty'
$fontconfigPath = Join-Path $artifactPath.FullName 'fonts.conf'
$fontconfigConfDir = Join-Path $artifactPath.FullName 'conf.d'

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
  <description>cmux shell host spike</description>
  <dir>C:/Windows/Fonts</dir>
  <dir prefix="xdg">fonts</dir>
  <include ignore_missing="yes">$($fontconfigConfDir -replace '\\','/')</include>
  <cachedir>LOCAL_APPDATA_FONTCONFIG_CACHE</cachedir>
  <cachedir prefix="xdg">fontconfig</cachedir>
</fontconfig>
"@
Set-Content -Path $fontconfigPath -Value $fontconfigContents -Encoding ascii

& (Join-Path $PSScriptRoot 'build-windows-shell-host-spike.ps1') -OutputPath $OutputPath | Out-Null
& (Join-Path $PSScriptRoot 'build-windows-webview2-child-host.ps1') -OutputPath $BrowserHelperPath | Out-Null

$env:CMUX_GHOSTTY_LIB = $ghosttyLibrary
$env:GHOSTTY_RESOURCES_DIR = $ghosttyResources
$env:FONTCONFIG_FILE = $fontconfigPath
$env:FONTCONFIG_PATH = $artifactPath.FullName

$reportPath = Join-Path $artifactPath.FullName 'shell-host-report.json'
& $OutputPath --report $reportPath --command $Command --browser-url $BrowserUrl --browser-title $BrowserTitle --browser-helper $BrowserHelperPath | Out-Null
if (-not (Test-Path $reportPath)) {
    throw "Shell host spike report was not written to $reportPath"
}

$report = Get-Content $reportPath -Raw | ConvertFrom-Json

if (-not $report.pmv2Enabled) {
    throw 'Expected pmv2Enabled=true'
}
if (-not $report.terminalSurfaceCreated) {
    throw 'Expected terminalSurfaceCreated=true'
}
if (-not $report.browserControllerReady) {
    throw 'Expected browserControllerReady=true'
}
if (-not $report.browserNavigationCompleted) {
    throw 'Expected browserNavigationCompleted=true'
}
if ($report.browserFinalTitle -ne $BrowserTitle) {
    throw "Expected browserFinalTitle='$BrowserTitle' but found '$($report.browserFinalTitle)'"
}
if ($report.browserFinalURL -notmatch '^data:text/html,') {
    throw "Expected browserFinalURL to use the data: scheme but found '$($report.browserFinalURL)'"
}
if ($report.browserStatus -ne 'webview2-ready') {
    throw "Expected browserStatus='webview2-ready' but found '$($report.browserStatus)'"
}
if (-not $report.transcriptContainsExpectedMarker) {
    throw 'Expected transcriptContainsExpectedMarker=true'
}
if (-not $report.childExitSeen) {
    throw 'Expected childExitSeen=true'
}
if ($report.childExitCode -ne 0) {
    throw "Expected childExitCode=0 but found $($report.childExitCode)"
}
if ($report.focusTransferCount -lt 3) {
    throw "Expected focusTransferCount >= 3 but found $($report.focusTransferCount)"
}
if ($report.layoutPassCount -lt 2) {
    throw "Expected layoutPassCount >= 2 but found $($report.layoutPassCount)"
}
if (-not $report.maximizeRoundTripSeen) {
    throw 'Expected maximizeRoundTripSeen=true'
}

Write-Host "Shell host spike passed"
Write-Host $reportPath
