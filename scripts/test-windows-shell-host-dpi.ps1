param(
    [string]$ArtifactDirectory = $(Join-Path $env:TEMP ("cmux-shell-host-dpi-" + [guid]::NewGuid().Guid)),
    [string]$OutputPath = $(Join-Path $ArtifactDirectory 'cmux_windows_shell_host_spike.exe'),
    [string]$BrowserHelperPath = $(Join-Path $ArtifactDirectory 'cmux_windows_webview2_child_host.exe'),
    [string]$GhosttyRoot = $(Join-Path $PSScriptRoot '..\..\ghostty'),
    [string]$Command = 'echo shell-host-spike && echo proof-line',
    [string]$BrowserUrl = 'data:text/html,<html><head><title>DG5 Shell Host DPI</title></head><body>shell-host-browser</body></html>',
    [string]$BrowserTitle = 'DG5 Shell Host DPI'
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
  <description>cmux shell host dpi spike</description>
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

$shellReportPath = Join-Path $artifactPath.FullName 'shell-host-report.json'
$reportPath = Join-Path $artifactPath.FullName 'shell-host-dpi-report.json'

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

$arguments = @(
    '--report', (Quote-Argument $shellReportPath),
    '--command', (Quote-Argument $Command),
    '--browser-url', (Quote-Argument $BrowserUrl),
    '--browser-title', (Quote-Argument $BrowserTitle),
    '--browser-helper', (Quote-Argument $BrowserHelperPath)
) -join ' '

$process = Start-Process -FilePath $OutputPath -ArgumentList $arguments -PassThru

try {
    $process.WaitForExit()
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

$pmv2Enabled = [bool]$shellReport.pmv2Enabled
$maximizeRoundTripSeen = [bool]$shellReport.maximizeRoundTripSeen
$splitterHostCreated = [bool]$shellReport.splitterHostCreated
$layoutPassCount = [int]$shellReport.layoutPassCount
$initialDpi = [int]$shellReport.initialDpi
$lastDpi = [int]$shellReport.lastDpi
$dpiChangeCount = [int]$shellReport.dpiChangeCount

$report = [ordered]@{
    pmv2Enabled = $pmv2Enabled
    maximizeRoundTripSeen = $maximizeRoundTripSeen
    splitterHostCreated = $splitterHostCreated
    layoutPassCount = $layoutPassCount
    initialDpi = $initialDpi
    lastDpi = $lastDpi
    dpiChangeCount = $dpiChangeCount
    shellReportPath = $shellReportPath
    exitCode = $process.ExitCode
}
$report | ConvertTo-Json -Depth 4 | Set-Content -Path $reportPath -Encoding utf8

if (-not $pmv2Enabled) {
    throw 'Expected shell host to run with PMv2 enabled'
}
if (-not $maximizeRoundTripSeen) {
    throw 'Expected shell host to prove maximize/restore round trip'
}
if (-not $splitterHostCreated) {
    throw 'Expected shell host to create a semantic splitter host'
}
if ($layoutPassCount -lt 4) {
    throw "Expected layoutPassCount >= 4 but found $layoutPassCount"
}
if ($initialDpi -le 0 -or $lastDpi -le 0) {
    throw "Expected positive DPI values but found initial=$initialDpi last=$lastDpi"
}
if ($process.ExitCode -ne 0) {
    throw "Expected shell host spike to exit 0 but found $($process.ExitCode)"
}

Write-Host "Shell host DPI spike passed"
Write-Host $reportPath
