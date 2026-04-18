param(
    [string]$ArtifactDirectory = $(Join-Path $env:TEMP ("cmux-shell-host-multimonitor-" + [guid]::NewGuid().Guid)),
    [string]$OutputPath = $(Join-Path $ArtifactDirectory 'cmux_windows_shell_host_spike.exe'),
    [string]$BrowserHelperPath = $(Join-Path $ArtifactDirectory 'cmux_windows_webview2_child_host.exe'),
    [string]$GhosttyRoot = $(Join-Path $PSScriptRoot '..\..\ghostty'),
    [string]$Command = 'ping -n 4 127.0.0.1 >nul && echo shell-host-spike && echo proof-line',
    [string]$BrowserUrl = 'data:text/html,<html><head><title>DG13 Multi-Monitor</title></head><body>shell-host-browser</body></html>',
    [string]$BrowserTitle = 'DG13 Multi-Monitor'
)

$ErrorActionPreference = 'Stop'

$interop = @"
using System;
using System.Runtime.InteropServices;
public static class CmuxMonitorUser32 {
    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, ref RECT lprcMonitor, IntPtr dwData);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct MONITORINFOEX {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
    }
    [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumProc lpfnEnum, IntPtr dwData);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX lpmi);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint dwFlags);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
public static class CmuxMonitorShcore {
    [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr hmonitor, int dpiType, out uint dpiX, out uint dpiY);
}
"@
Add-Type -TypeDefinition $interop | Out-Null

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
  <description>cmux shell host multimonitor spike</description>
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

$reportPath = Join-Path $artifactPath.FullName 'shell-host-multimonitor-report.json'
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

function Get-MonitorSnapshots {
    $items = New-Object System.Collections.ArrayList
    $callback = [CmuxMonitorUser32+MonitorEnumProc]{
        param([IntPtr]$hMonitor, [IntPtr]$hdc, [ref][CmuxMonitorUser32+RECT]$rect, [IntPtr]$data)
        $info = New-Object CmuxMonitorUser32+MONITORINFOEX
        $info.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type][CmuxMonitorUser32+MONITORINFOEX])
        if ([CmuxMonitorUser32]::GetMonitorInfo($hMonitor, [ref]$info)) {
            [uint32]$dx = 0
            [uint32]$dy = 0
            $dpiHr = [CmuxMonitorShcore]::GetDpiForMonitor($hMonitor, 0, [ref]$dx, [ref]$dy)
            [void]$items.Add([pscustomobject]@{
                handle = ('0x{0:x}' -f $hMonitor.ToInt64())
                device = $info.szDevice
                left = $info.rcMonitor.Left
                top = $info.rcMonitor.Top
                right = $info.rcMonitor.Right
                bottom = $info.rcMonitor.Bottom
                centerX = [int](($info.rcMonitor.Left + $info.rcMonitor.Right) / 2)
                centerY = [int](($info.rcMonitor.Top + $info.rcMonitor.Bottom) / 2)
                dpiX = [int]$dx
                dpiY = [int]$dy
                dpiQueryHr = $dpiHr
            })
        }
        return $true
    }
    [CmuxMonitorUser32]::EnumDisplayMonitors([IntPtr]::Zero, [IntPtr]::Zero, $callback, [IntPtr]::Zero) | Out-Null
    return @($items.ToArray())
}

try {
    $arguments = @(
        '--report', (Quote-Argument $shellReportPath),
        '--command', (Quote-Argument $Command),
        '--browser-url', (Quote-Argument $BrowserUrl),
        '--browser-title', (Quote-Argument $BrowserTitle),
        '--browser-helper', (Quote-Argument $BrowserHelperPath),
        '--hold-open-ms', '2500'
    ) -join ' '

    $process = Start-Process -FilePath $OutputPath -ArgumentList $arguments -PassThru

    $hostTitle = 'cmux Shell Host Spike'
    $hostHandle = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds(12)
    while ((Get-Date) -lt $deadline -and -not $process.HasExited) {
        $candidate = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
        if ($candidate) {
            $candidate.Refresh()
            if ($candidate.MainWindowHandle -ne 0 -and $candidate.MainWindowTitle -eq $hostTitle) {
                $hostHandle = [IntPtr]::new([long]$candidate.MainWindowHandle)
                break
            }
        }
        Start-Sleep -Milliseconds 150
    }

    if ($hostHandle -eq [IntPtr]::Zero) {
        throw 'Expected shell host main window handle for multi-monitor probe'
    }

    $monitors = @(Get-MonitorSnapshots)
    if ($monitors.Count -lt 1) {
        throw "Expected at least one monitor but found $($monitors.Count)"
    }

    [CmuxMonitorUser32]::ShowWindow($hostHandle, 9) | Out-Null
    [CmuxMonitorUser32]::BringWindowToTop($hostHandle) | Out-Null
    [CmuxMonitorUser32]::SetForegroundWindow($hostHandle) | Out-Null
    Start-Sleep -Milliseconds 300

    $visited = New-Object System.Collections.Generic.List[string]
    if ($monitors.Count -ge 2) {
        foreach ($monitor in $monitors | Select-Object -First 3) {
            $width = 1320
            $height = 820
            $x = [Math]::Max($monitor.left, $monitor.centerX - [int]($width / 2))
            $y = [Math]::Max($monitor.top, $monitor.centerY - [int]($height / 2))
            [CmuxMonitorUser32]::SetWindowPos($hostHandle, [IntPtr]::Zero, $x, $y, $width, $height, 0x0014) | Out-Null
            Start-Sleep -Milliseconds 650
            $currentMonitor = [CmuxMonitorUser32]::MonitorFromWindow($hostHandle, 2)
            $visited.Add(('0x{0:x}' -f $currentMonitor.ToInt64())) | Out-Null
        }
    } else {
        Start-Sleep -Milliseconds 1000
        $currentMonitor = [CmuxMonitorUser32]::MonitorFromWindow($hostHandle, 2)
        $visited.Add(('0x{0:x}' -f $currentMonitor.ToInt64())) | Out-Null
    }

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
$visitedDistinct = @($visited | Select-Object -Unique)
$monitorDpis = @($monitors | ForEach-Object { $_.dpiX } | Select-Object -Unique)
$dpiVariesAcrossMonitors = $monitorDpis.Count -gt 1
$physicalMultiMonitorAvailable = $monitors.Count -ge 2

$report = [ordered]@{
    observedMonitorCount = $monitors.Count
    shellReportMonitorCount = [int]$shellReport.monitorCount
    physicalMultiMonitorAvailable = $physicalMultiMonitorAvailable
    visitedDistinctMonitorCount = $visitedDistinct.Count
    visitedDistinctMonitors = $visitedDistinct
    monitors = $monitors
    dpiVariesAcrossMonitors = $dpiVariesAcrossMonitors
    shellReportDpiChangeCount = [int]$shellReport.dpiChangeCount
    shellReportLastDpi = [int]$shellReport.lastDpi
    shellReportLayoutPassCount = [int]$shellReport.layoutPassCount
    pmv2Enabled = [bool]$shellReport.pmv2Enabled
    transcriptContainsExpectedMarker = [bool]$shellReport.transcriptContainsExpectedMarker
    browserControllerReady = [bool]$shellReport.browserControllerReady
    shellReportPath = $shellReportPath
    exitCode = $process.ExitCode
}
$report | ConvertTo-Json -Depth 8 | Set-Content -Path $reportPath -Encoding utf8

if ($physicalMultiMonitorAvailable) {
    if ($shellReport.monitorCount -lt 2) {
        throw "Expected shell host to observe at least two monitors but found $($shellReport.monitorCount)"
    }
    if ($visitedDistinct.Count -lt 2) {
        throw "Expected shell host to move across at least two distinct monitors but visited $($visitedDistinct.Count)"
    }
}
if (-not $shellReport.pmv2Enabled) {
    throw 'Expected PMv2 enabled during multi-monitor probe'
}
if ($physicalMultiMonitorAvailable) {
    if ($shellReport.layoutPassCount -lt 6) {
        throw "Expected layoutPassCount >= 6 but found $($shellReport.layoutPassCount)"
    }
} elseif ($shellReport.layoutPassCount -lt 4) {
    throw "Expected single-monitor fallback layoutPassCount >= 4 but found $($shellReport.layoutPassCount)"
}
if (-not $shellReport.browserControllerReady) {
    throw 'Expected browser controller ready during multi-monitor probe'
}
if (-not $shellReport.transcriptContainsExpectedMarker) {
    throw 'Expected terminal transcript to survive multi-monitor probe'
}
if ($physicalMultiMonitorAvailable -and $dpiVariesAcrossMonitors -and $shellReport.dpiChangeCount -lt 1) {
    throw "Expected at least one DPI change across physical monitors but found $($shellReport.dpiChangeCount)"
}
if ($process.ExitCode -ne 0) {
    throw "Expected shell host spike to exit 0 but found $($process.ExitCode)"
}

Write-Host "Shell host multimonitor spike passed"
Write-Host $reportPath
