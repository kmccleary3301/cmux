param(
    [string]$ArtifactDirectory = $(Join-Path $env:TEMP ("cmux-shell-host-window-ownership-" + [guid]::NewGuid().Guid)),
    [string]$OutputPath = $(Join-Path $ArtifactDirectory 'cmux_windows_shell_host_spike.exe'),
    [string]$BrowserHelperPath = $(Join-Path $ArtifactDirectory 'cmux_windows_webview2_child_host.exe'),
    [string]$GhosttyRoot = $(Join-Path $PSScriptRoot '..\..\ghostty'),
    [string]$Command = 'echo shell-host-spike && echo proof-line',
    [string]$BrowserUrl = 'data:text/html,<html><head><title>DG9 Window Ownership</title></head><body>shell-host-browser</body></html>',
    [string]$BrowserTitle = 'DG9 Window Ownership'
)

$ErrorActionPreference = 'Stop'

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class ShellHostWindowOwnershipNative {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    public struct WindowSnapshot {
        public uint ProcessId;
        public string ClassName;
        public string Title;
        public bool Visible;
    }

    public static List<WindowSnapshot> CollectVisibleTopLevelWindows() {
        var results = new List<WindowSnapshot>();
        EnumWindows((hWnd, lParam) => {
            uint processId;
            GetWindowThreadProcessId(hWnd, out processId);
            var classBuilder = new StringBuilder(256);
            var titleBuilder = new StringBuilder(256);
            GetClassNameW(hWnd, classBuilder, classBuilder.Capacity);
            GetWindowTextW(hWnd, titleBuilder, titleBuilder.Capacity);
            results.Add(new WindowSnapshot {
                ProcessId = processId,
                ClassName = classBuilder.ToString(),
                Title = titleBuilder.ToString(),
                Visible = IsWindowVisible(hWnd)
            });
            return true;
        }, IntPtr.Zero);
        return results;
    }
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
  <description>cmux shell host window ownership spike</description>
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
$reportPath = Join-Path $artifactPath.FullName 'shell-host-window-ownership-report.json'

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
$capturedWindows = @()

try {
    $deadline = (Get-Date).AddSeconds(6)
    while ((Get-Date) -lt $deadline -and -not $process.HasExited) {
        $helperProcesses = Get-Process -Name 'cmux_windows_webview2_child_host' -ErrorAction SilentlyContinue |
            Where-Object { $_.StartTime -ge $process.StartTime.AddSeconds(-1) }
        if ($helperProcesses) {
            $windows = [ShellHostWindowOwnershipNative]::CollectVisibleTopLevelWindows()
            $helperProcessIds = @($helperProcesses | ForEach-Object { [uint32]$_.Id })
            $capturedWindows = @(
                $windows | Where-Object {
                    $_.Visible -and (
                        $_.ProcessId -eq [uint32]$process.Id -or
                        $helperProcessIds -contains $_.ProcessId
                    )
                }
            )
            if ($capturedWindows.Count -gt 0) {
                break
            }
        }
        Start-Sleep -Milliseconds 150
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

$shellOwnedWindows = @($capturedWindows | Where-Object { $_.ProcessId -eq [uint32]$process.Id })
$browserOwnedWindows = @($capturedWindows | Where-Object { $_.ProcessId -ne [uint32]$process.Id })
$shellUserVisibleWindows = @(
    $shellOwnedWindows | Where-Object {
        $_.ClassName -eq 'CmuxShellHostSpikeWindow' -or
        -not [string]::IsNullOrWhiteSpace($_.Title)
    }
)
$shellAuxiliaryWindows = @(
    $shellOwnedWindows | Where-Object {
        $_.ClassName -ne 'CmuxShellHostSpikeWindow' -and
        [string]::IsNullOrWhiteSpace($_.Title)
    }
)

$report = [ordered]@{
    shellProcessId = $process.Id
    shellOwnedWindowCount = $shellOwnedWindows.Count
    shellUserVisibleWindowCount = $shellUserVisibleWindows.Count
    browserOwnedWindowCount = $browserOwnedWindows.Count
    shellOwnedWindows = $shellOwnedWindows
    shellAuxiliaryWindows = $shellAuxiliaryWindows
    browserOwnedWindows = $browserOwnedWindows
    shellReportPath = $shellReportPath
    exitCode = $process.ExitCode
}
$report | ConvertTo-Json -Depth 6 | Set-Content -Path $reportPath -Encoding utf8

if ($shellUserVisibleWindows.Count -ne 1) {
    throw "Expected exactly one user-visible top-level shell-host window but found $($shellUserVisibleWindows.Count)"
}
if ($shellUserVisibleWindows[0].ClassName -ne 'CmuxShellHostSpikeWindow') {
    throw "Expected visible shell-host top-level class 'CmuxShellHostSpikeWindow' but found '$($shellUserVisibleWindows[0].ClassName)'"
}
if ($browserOwnedWindows.Count -ne 0) {
    throw "Expected no visible top-level browser helper windows but found $($browserOwnedWindows.Count)"
}
if ($process.ExitCode -ne 0) {
    throw "Expected shell host spike to exit 0 but found $($process.ExitCode)"
}

Write-Host "Shell host window-ownership spike passed"
Write-Host $reportPath
