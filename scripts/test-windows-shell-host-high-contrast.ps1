param(
    [string]$ArtifactDirectory = $(Join-Path $env:TEMP ("cmux-shell-host-high-contrast-" + [guid]::NewGuid().Guid)),
    [string]$OutputPath = $(Join-Path $ArtifactDirectory 'cmux_windows_shell_host_spike.exe'),
    [string]$BrowserHelperPath = $(Join-Path $ArtifactDirectory 'cmux_windows_webview2_child_host.exe'),
    [string]$GhosttyRoot = $(Join-Path $PSScriptRoot '..\..\ghostty'),
    [string]$Command = 'echo shell-host-spike && echo proof-line',
    [string]$BrowserUrl = 'data:text/html,<html><head><title>DG11 Shell Host High Contrast</title></head><body>shell-host-browser</body></html>',
    [string]$BrowserTitle = 'DG11 Shell Host High Contrast'
)

$ErrorActionPreference = 'Stop'

$user32 = @"
using System;
using System.Runtime.InteropServices;
public static class CmuxHighContrastUser32 {
    [DllImport("user32.dll")] public static extern int GetSysColor(int nIndex);
}
"@
Add-Type -TypeDefinition $user32 | Out-Null

$artifactPath = New-Item -ItemType Directory -Force -Path $ArtifactDirectory
$ghosttyRootPath = (Resolve-Path $GhosttyRoot).Path
$ghosttyLibrary = Join-Path $ghosttyRootPath 'zig-out\lib\libghostty.so'
$ghosttyResources = Join-Path $ghosttyRootPath 'zig-out\share\ghostty'
$fontconfigPath = Join-Path $artifactPath.FullName 'fonts.conf'
$fontconfigConfDir = Join-Path $artifactPath.FullName 'conf.d'

if (-not (Test-Path $ghosttyLibrary)) { throw "Ghostty shared library not found: $ghosttyLibrary" }
if (-not (Test-Path $ghosttyResources)) { throw "Ghostty resources directory not found: $ghosttyResources" }

$fontconfigPackage = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'zig\p') -Recurse -File -Filter 'fonts.conf.in' | Select-Object -First 1
if (-not $fontconfigPackage) { throw 'Could not locate cached fontconfig package source' }

$fontconfigPackageRoot = Split-Path -Parent $fontconfigPackage.FullName
New-Item -ItemType Directory -Force -Path $fontconfigConfDir | Out-Null
Copy-Item -Path (Join-Path $fontconfigPackageRoot 'conf.d\*') -Destination $fontconfigConfDir -Recurse -Force

$fontconfigContents = @"
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <description>cmux shell host high contrast spike</description>
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

$reportPath = Join-Path $artifactPath.FullName 'shell-host-high-contrast-report.json'
$shellReportPath = Join-Path $artifactPath.FullName 'shell-host-report.json'

$previousGhosttyLib = $env:CMUX_GHOSTTY_LIB
$previousGhosttyResources = $env:GHOSTTY_RESOURCES_DIR
$previousFontconfigFile = $env:FONTCONFIG_FILE
$previousFontconfigPath = $env:FONTCONFIG_PATH

$env:CMUX_GHOSTTY_LIB = $ghosttyLibrary
$env:GHOSTTY_RESOURCES_DIR = $ghosttyResources
$env:FONTCONFIG_FILE = $fontconfigPath
$env:FONTCONFIG_PATH = $artifactPath.FullName

function Quote-Argument([string]$Value) {
    '"' + ($Value -replace '"', '\"') + '"'
}

try {
    $arguments = @(
        '--report', (Quote-Argument $shellReportPath),
        '--command', (Quote-Argument $Command),
        '--browser-url', (Quote-Argument $BrowserUrl),
        '--browser-title', (Quote-Argument $BrowserTitle),
        '--browser-helper', (Quote-Argument $BrowserHelperPath),
        '--force-high-contrast'
    ) -join ' '

    $process = Start-Process -FilePath $OutputPath -ArgumentList $arguments -PassThru -Wait
}
finally {
    $env:CMUX_GHOSTTY_LIB = $previousGhosttyLib
    $env:GHOSTTY_RESOURCES_DIR = $previousGhosttyResources
    $env:FONTCONFIG_FILE = $previousFontconfigFile
    $env:FONTCONFIG_PATH = $previousFontconfigPath
}

if (-not (Test-Path $shellReportPath)) {
    throw "Expected shell host report at $shellReportPath"
}

$shellReport = Get-Content $shellReportPath -Raw | ConvertFrom-Json
$expectedWindow = [CmuxHighContrastUser32]::GetSysColor(5) # COLOR_WINDOW
$expectedText = [CmuxHighContrastUser32]::GetSysColor(8)   # COLOR_WINDOWTEXT
$expectedHighlight = [CmuxHighContrastUser32]::GetSysColor(13) # COLOR_HIGHLIGHT

$report = [ordered]@{
    highContrastActive = [bool]$shellReport.highContrastActive
    highContrastForced = [bool]$shellReport.highContrastForced
    highContrastSettingObserved = [bool]$shellReport.highContrastSettingObserved
    highContrastFlags = [int]$shellReport.highContrastFlags
    shellBackgroundColor = [int]$shellReport.shellBackgroundColor
    paneBackgroundColor = [int]$shellReport.paneBackgroundColor
    splitterColor = [int]$shellReport.splitterColor
    textColor = [int]$shellReport.textColor
    expectedWindow = $expectedWindow
    expectedText = $expectedText
    expectedHighlight = $expectedHighlight
    browserControllerReady = [bool]$shellReport.browserControllerReady
    transcriptContainsExpectedMarker = [bool]$shellReport.transcriptContainsExpectedMarker
    exitCode = $process.ExitCode
    shellReportPath = $shellReportPath
}
$report | ConvertTo-Json -Depth 5 | Set-Content -Path $reportPath -Encoding utf8

if (-not $shellReport.highContrastForced) {
    throw 'Expected forced high contrast flag in shell host report'
}
if (-not $shellReport.highContrastActive) {
    throw 'Expected shell host to report high contrast active'
}
if (-not $shellReport.highContrastSettingObserved) {
    throw 'Expected shell host to observe the Windows high-contrast setting'
}
if ($shellReport.shellBackgroundColor -ne $expectedWindow) {
    throw "Expected shell background color $expectedWindow but found $($shellReport.shellBackgroundColor)"
}
if ($shellReport.paneBackgroundColor -ne $expectedWindow) {
    throw "Expected pane background color $expectedWindow but found $($shellReport.paneBackgroundColor)"
}
if ($shellReport.splitterColor -ne $expectedHighlight) {
    throw "Expected splitter color $expectedHighlight but found $($shellReport.splitterColor)"
}
if ($shellReport.textColor -ne $expectedText) {
    throw "Expected text color $expectedText but found $($shellReport.textColor)"
}
if (-not $shellReport.browserControllerReady) {
    throw 'Expected browser controller ready under forced high contrast'
}
if (-not $shellReport.transcriptContainsExpectedMarker) {
    throw 'Expected terminal transcript to survive forced high contrast run'
}
if ($process.ExitCode -ne 0) {
    throw "Expected shell host spike to exit 0 but found $($process.ExitCode)"
}

Write-Host "Shell host high contrast spike passed"
Write-Host $reportPath
