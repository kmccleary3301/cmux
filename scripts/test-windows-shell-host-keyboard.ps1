param(
    [string]$ArtifactDirectory = $(Join-Path $env:TEMP ("cmux-shell-host-keyboard-" + [guid]::NewGuid().Guid)),
    [string]$OutputPath = $(Join-Path $ArtifactDirectory 'cmux_windows_shell_host_spike.exe'),
    [string]$BrowserHelperPath = $(Join-Path $ArtifactDirectory 'cmux_windows_webview2_child_host.exe'),
    [string]$GhosttyRoot = $(Join-Path $PSScriptRoot '..\..\ghostty'),
    [string]$Command = 'ping -n 3 127.0.0.1 >nul && echo shell-host-spike && echo proof-line',
    [string]$BrowserUrl = 'data:text/html,<html><head><title>DG3 Shell Host Spike</title></head><body>shell-host-browser</body></html>',
    [string]$BrowserTitle = 'DG3 Shell Host Spike'
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$user32 = @"
using System;
using System.Runtime.InteropServices;
public static class CmuxKeyboardUser32 {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool PostMessage(IntPtr hWnd, uint Msg, UIntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@
Add-Type -TypeDefinition $user32 | Out-Null

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
  <description>cmux shell host keyboard spike</description>
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

$reportPath = Join-Path $artifactPath.FullName 'shell-host-keyboard-report.json'
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

function Test-NameMatches {
    param(
        [string]$Name,
        [string]$ExpectedPrefix
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    return $Name.StartsWith($ExpectedPrefix, [System.StringComparison]::Ordinal)
}

$arguments = @(
    '--report', (Quote-Argument $shellReportPath),
    '--command', (Quote-Argument $Command),
    '--browser-url', (Quote-Argument $BrowserUrl),
    '--browser-title', (Quote-Argument $BrowserTitle),
    '--browser-helper', (Quote-Argument $BrowserHelperPath),
    '--manual-focus'
) -join ' '

$process = Start-Process -FilePath $OutputPath -ArgumentList $arguments -PassThru
$hostName = 'cmux Shell Host Spike'
$browserChildName = 'cmux WebView2 Child Host'
$browserPaneName = 'cmux Browser Host Pane'
$terminalName = 'cmux Terminal Pane'
$splitterName = 'cmux Splitter'
$f6Key = [System.UIntPtr]::new(0x75)
$focusedNames = New-Object System.Collections.Generic.List[string]
$descendantNames = New-Object System.Collections.Generic.List[string]
$actionLogPath = Join-Path $artifactPath.FullName 'shell-host-actions.log'
$focusLogProbePath = Join-Path $artifactPath.FullName 'shell-host-focus.log'

try {
    $deadline = (Get-Date).AddSeconds(12)
    $hostElement = $null
    while ((Get-Date) -lt $deadline -and -not $process.HasExited) {
        $hostCondition = New-Object System.Windows.Automation.AndCondition(
            (New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::NameProperty,
                $hostName
            )),
            (New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ProcessIdProperty,
                $process.Id
            ))
        )
        $hostElement = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $hostCondition)
        if ($hostElement -ne $null) { break }
        Start-Sleep -Milliseconds 150
    }

    if ($hostElement -eq $null) {
        throw 'Expected shell host window to be discoverable before keyboard traversal'
    }

    $readyDeadline = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $readyDeadline -and -not $process.HasExited) {
        $actionReady = (Test-Path $actionLogPath) -and ((Get-Content -Raw $actionLogPath) -match 'stage:browser-helper-ready')
        $manualFocusReady = (Test-Path $focusLogProbePath) -and ((Get-Content -Raw $focusLogProbePath) -match 'reason=manual-initial')
        if ($actionReady -and $manualFocusReady) {
            break
        }
        Start-Sleep -Milliseconds 150
    }

    $hostHandle = [IntPtr]::new($hostElement.Current.NativeWindowHandle)
    try {
        $hostElement.SetFocus()
    } catch {
    }
    [CmuxKeyboardUser32]::ShowWindow($hostHandle, 9) | Out-Null
    [CmuxKeyboardUser32]::BringWindowToTop($hostHandle) | Out-Null
    [CmuxKeyboardUser32]::SetForegroundWindow($hostHandle) | Out-Null
    Start-Sleep -Milliseconds 300

    $terminalHandle = [IntPtr]::Zero
    $browserPaneHandle = [IntPtr]::Zero
    $handleDeadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $handleDeadline -and -not $process.HasExited) {
        $descendantNames.Clear()
        try {
            $allDescendants = $hostElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
        } catch {
            Start-Sleep -Milliseconds 150
            continue
        }
        $terminalHandle = [IntPtr]::Zero
        $browserPaneHandle = [IntPtr]::Zero
        for ($index = 0; $index -lt $allDescendants.Count; $index += 1) {
            $element = $allDescendants.Item($index)
            $name = $element.Current.Name
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                [void]$descendantNames.Add($name)
            }
            if ((Test-NameMatches -Name $name -ExpectedPrefix $terminalName) -and $element.Current.NativeWindowHandle -ne 0) {
                $terminalHandle = [IntPtr]::new($element.Current.NativeWindowHandle)
            } elseif ((Test-NameMatches -Name $name -ExpectedPrefix $browserPaneName) -and $element.Current.NativeWindowHandle -ne 0) {
                $browserPaneHandle = [IntPtr]::new($element.Current.NativeWindowHandle)
            }
        }
        if ($terminalHandle -ne [IntPtr]::Zero -and $browserPaneHandle -ne [IntPtr]::Zero) {
            break
        }
        Start-Sleep -Milliseconds 150
    }

    if ($terminalHandle -eq [IntPtr]::Zero) {
        throw 'Expected terminal pane handle to be discoverable before keyboard traversal'
    }
    if ($browserPaneHandle -eq [IntPtr]::Zero) {
        throw 'Expected browser pane handle to be discoverable before keyboard traversal'
    }

    [CmuxKeyboardUser32]::PostMessage($terminalHandle, 0x0100, $f6Key, [IntPtr]::Zero) | Out-Null
    [CmuxKeyboardUser32]::PostMessage($terminalHandle, 0x0101, $f6Key, [IntPtr]::Zero) | Out-Null
    Start-Sleep -Milliseconds 450
    $focusedNames.Add(([System.Windows.Automation.AutomationElement]::FocusedElement.Current.Name))

    [CmuxKeyboardUser32]::PostMessage($browserPaneHandle, 0x0100, $f6Key, [IntPtr]::Zero) | Out-Null
    [CmuxKeyboardUser32]::PostMessage($browserPaneHandle, 0x0101, $f6Key, [IntPtr]::Zero) | Out-Null
    Start-Sleep -Milliseconds 450
    $focusedNames.Add(([System.Windows.Automation.AutomationElement]::FocusedElement.Current.Name))

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
$focusLogPath = $shellReport.focusLogPath
$focusLog = if (Test-Path $focusLogPath) { Get-Content -Raw $focusLogPath } else { '' }

$browserFocusSeen = ($focusedNames | Where-Object { (Test-NameMatches -Name $_ -ExpectedPrefix $browserChildName) -or (Test-NameMatches -Name $_ -ExpectedPrefix $browserPaneName) }).Count -gt 0 -or
    ($focusLog -match 'focus=browser reason=keyboard-cycle actual=true')
$terminalFocusSeen = ($focusedNames | Where-Object { Test-NameMatches -Name $_ -ExpectedPrefix $terminalName }).Count -gt 0 -or
    ($focusLog -match 'focus=terminal reason=keyboard-cycle actual=true')
$splitterFound = ($descendantNames | Where-Object { Test-NameMatches -Name $_ -ExpectedPrefix $splitterName }).Count -gt 0

$report = [ordered]@{
    keyboardTraversalCount = [int]$shellReport.keyboardTraversalCount
    splitterFound = $splitterFound
    browserFocusSeen = $browserFocusSeen
    terminalFocusSeen = $terminalFocusSeen
    focusedNames = @($focusedNames)
    descendantNames = @($descendantNames)
    focusLogPath = $focusLogPath
    shellReportPath = $shellReportPath
    exitCode = $process.ExitCode
}
$report | ConvertTo-Json -Depth 5 | Set-Content -Path $reportPath -Encoding utf8

if (-not $splitterFound) {
    throw 'Expected semantic splitter host to be discoverable'
}
if (-not $browserFocusSeen) {
    throw 'Expected keyboard traversal to reach the browser pane'
}
if (-not $terminalFocusSeen) {
    throw 'Expected keyboard traversal to reach the terminal pane'
}
if ($shellReport.keyboardTraversalCount -lt 2) {
    throw "Expected keyboardTraversalCount >= 2 but found $($shellReport.keyboardTraversalCount)"
}
if ($process.ExitCode -ne 0) {
    throw "Expected shell host spike to exit 0 but found $($process.ExitCode)"
}

Write-Host "Shell host keyboard spike passed"
Write-Host $reportPath
