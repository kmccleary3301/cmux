param(
    [string]$ArtifactDirectory = $(Join-Path $env:TEMP ("cmux-shell-host-scale-change-" + [guid]::NewGuid().Guid)),
    [string]$OutputPath = $(Join-Path $ArtifactDirectory 'cmux_windows_shell_host_spike.exe'),
    [string]$BrowserHelperPath = $(Join-Path $ArtifactDirectory 'cmux_windows_webview2_child_host.exe'),
    [string]$GhosttyRoot = $(Join-Path $PSScriptRoot '..\..\ghostty'),
    [string]$Command = 'echo shell-host-spike && echo proof-line',
    [string]$BrowserUrl = 'data:text/html,<html><head><title>DG8 Shell Host Scale Change</title></head><body>shell-host-browser</body></html>',
    [string]$BrowserTitle = 'DG8 Shell Host Scale Change'
)

$ErrorActionPreference = 'Stop'

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class ShellHostScaleChangeNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SendMessageW(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
}
"@

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

$fontconfigPackage = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'zig\\p') -Recurse -File -Filter 'fonts.conf.in' |
    Select-Object -First 1
if (-not $fontconfigPackage) {
    throw 'Could not locate cached fontconfig package source'
}

$fontconfigPackageRoot = Split-Path -Parent $fontconfigPackage.FullName
New-Item -ItemType Directory -Force -Path $fontconfigConfDir | Out-Null
Copy-Item -Path (Join-Path $fontconfigPackageRoot 'conf.d\\*') -Destination $fontconfigConfDir -Recurse -Force

$fontconfigContents = @"
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <description>cmux shell host scale change spike</description>
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
$reportPath = Join-Path $artifactPath.FullName 'shell-host-scale-change-report.json'

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

function Send-DpiChange {
    param(
        [IntPtr]$Handle,
        [int]$Dpi,
        [int]$Width,
        [int]$Height
    )

    $rect = New-Object ShellHostScaleChangeNative+RECT
    $rect.Left = 120
    $rect.Top = 120
    $rect.Right = 120 + $Width
    $rect.Bottom = 120 + $Height
    $rectPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal([System.Runtime.InteropServices.Marshal]::SizeOf($rect))
    try {
        [System.Runtime.InteropServices.Marshal]::StructureToPtr($rect, $rectPtr, $false)
        $wParamValue = (($Dpi -band 0xFFFF) -shl 16) -bor ($Dpi -band 0xFFFF)
        [void][ShellHostScaleChangeNative]::SendMessageW($Handle, 0x02E0, [IntPtr]$wParamValue, $rectPtr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($rectPtr)
    }
}

$arguments = @(
    '--report', (Quote-Argument $shellReportPath),
    '--command', (Quote-Argument $Command),
    '--browser-url', (Quote-Argument $BrowserUrl),
    '--browser-title', (Quote-Argument $BrowserTitle),
    '--browser-helper', (Quote-Argument $BrowserHelperPath)
) -join ' '

$process = Start-Process -FilePath $OutputPath -ArgumentList $arguments -PassThru
$scaleSequence = @()

try {
    $deadline = (Get-Date).AddSeconds(6)
    $mainHandle = [IntPtr]::Zero
    while ((Get-Date) -lt $deadline -and -not $process.HasExited) {
        $process.Refresh()
        if ($process.MainWindowHandle -ne 0) {
            $mainHandle = [IntPtr]$process.MainWindowHandle
            break
        }
        Start-Sleep -Milliseconds 100
    }

    if ($mainHandle -eq [IntPtr]::Zero) {
        throw 'Expected shell host spike to create a main window handle'
    }

    Start-Sleep -Milliseconds 600
    Send-DpiChange -Handle $mainHandle -Dpi 144 -Width 1380 -Height 820
    $scaleSequence += ,144
    Start-Sleep -Milliseconds 220
    Send-DpiChange -Handle $mainHandle -Dpi 192 -Width 1480 -Height 900
    $scaleSequence += ,192
    Start-Sleep -Milliseconds 220
    Send-DpiChange -Handle $mainHandle -Dpi 96 -Width 1280 -Height 760
    $scaleSequence += ,96

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
$dpiChangeCount = [int]$shellReport.dpiChangeCount
$lastDpi = [int]$shellReport.lastDpi
$layoutPassCount = [int]$shellReport.layoutPassCount
$pmv2Enabled = [bool]$shellReport.pmv2Enabled
$transcriptContainsExpectedMarker = [bool]$shellReport.transcriptContainsExpectedMarker
$browserControllerReady = [bool]$shellReport.browserControllerReady

$report = [ordered]@{
    scaleSequence = $scaleSequence
    dpiChangeCount = $dpiChangeCount
    lastDpi = $lastDpi
    layoutPassCount = $layoutPassCount
    pmv2Enabled = $pmv2Enabled
    transcriptContainsExpectedMarker = $transcriptContainsExpectedMarker
    browserControllerReady = $browserControllerReady
    shellReportPath = $shellReportPath
    exitCode = $process.ExitCode
}
$report | ConvertTo-Json -Depth 6 | Set-Content -Path $reportPath -Encoding utf8

if (-not $pmv2Enabled) {
    throw 'Expected shell host to run with PMv2 enabled during scale-change probe'
}
if ($dpiChangeCount -lt 3) {
    throw "Expected at least 3 DPI changes but found $dpiChangeCount"
}
if ($lastDpi -ne 96) {
    throw "Expected lastDpi to return to 96 but found $lastDpi"
}
if ($layoutPassCount -lt 6) {
    throw "Expected layoutPassCount >= 6 after scale-change probe but found $layoutPassCount"
}
if (-not $transcriptContainsExpectedMarker) {
    throw 'Expected terminal transcript marker to survive scale-change probe'
}
if (-not $browserControllerReady) {
    throw 'Expected browser controller to remain ready during scale-change probe'
}
if ($process.ExitCode -ne 0) {
    throw "Expected shell host spike to exit 0 but found $($process.ExitCode)"
}

Write-Host "Shell host scale-change spike passed"
Write-Host $reportPath
