param(
    [string]$ArtifactDirectory = $(Join-Path $env:TEMP ("cmux-shell-host-terminal-narrator-baseline-" + [guid]::NewGuid().Guid)),
    [string]$OutputPath = $(Join-Path $ArtifactDirectory 'cmux_windows_shell_host_spike.exe'),
    [string]$BrowserHelperPath = $(Join-Path $ArtifactDirectory 'cmux_windows_webview2_child_host.exe'),
    [string]$GhosttyRoot = $(Join-Path $PSScriptRoot '..\..\ghostty'),
    [string]$Command = 'ping -n 3 127.0.0.1 >nul && echo terminal-narrator-alpha && echo shell-host-spike && echo proof-line',
    [string]$BrowserUrl = 'data:text/html,<html><head><title>DG21 Terminal Narrator Baseline</title></head><body>shell-host-browser</body></html>',
    [string]$BrowserTitle = 'DG21 Terminal Narrator Baseline'
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$user32 = @"
using System;
using System.Runtime.InteropServices;
public static class CmuxTerminalNarratorUser32 {
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
  <description>cmux shell host terminal narrator baseline</description>
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

$reportPath = Join-Path $artifactPath.FullName 'shell-host-terminal-narrator-baseline-report.json'
$shellReportPath = Join-Path $artifactPath.FullName 'shell-host-report.json'
$actionLogPath = Join-Path $artifactPath.FullName 'shell-host-actions.log'
$focusLogPath = Join-Path $artifactPath.FullName 'shell-host-focus.log'

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

function Wait-ForLogPattern([string]$Path, [string]$Pattern, [int]$TimeoutMs) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $Path) -and ((Get-Content -Raw $Path) -match $Pattern)) {
            return $true
        }
        Start-Sleep -Milliseconds 120
    }
    return $false
}

function Find-AutomationIdDescendant {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string]$AutomationId
    )

    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
        $AutomationId
    )
    return $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Get-ElementSnapshot {
    param([System.Windows.Automation.AutomationElement]$Element)

    if ($null -eq $Element) { return $null }
    return [ordered]@{
        name = $Element.Current.Name
        automationId = $Element.Current.AutomationId
        controlType = $Element.Current.ControlType.ProgrammaticName
        className = $Element.Current.ClassName
        isKeyboardFocusable = [bool]$Element.Current.IsKeyboardFocusable
    }
}

function Get-FocusSnapshot {
    $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
    if ($null -eq $focused) { return $null }

    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $lineage = @()
    $current = $focused
    for ($depth = 0; $depth -lt 8 -and $null -ne $current; $depth += 1) {
        $lineage += [pscustomobject]@{
            name = $current.Current.Name
            automationId = $current.Current.AutomationId
            controlType = $current.Current.ControlType.ProgrammaticName
            className = $current.Current.ClassName
        }
        $current = $walker.GetParent($current)
    }

    return [pscustomobject]@{
        name = $focused.Current.Name
        automationId = $focused.Current.AutomationId
        controlType = $focused.Current.ControlType.ProgrammaticName
        className = $focused.Current.ClassName
        lineage = $lineage
    }
}

function Invoke-F6Traversal {
    param(
        [IntPtr]$HostHandle,
        [System.UIntPtr]$KeyCode,
        [System.Collections.Generic.List[object]]$Snapshots
    )

    [CmuxTerminalNarratorUser32]::PostMessage($HostHandle, 0x0100, $KeyCode, [IntPtr]::Zero) | Out-Null
    [CmuxTerminalNarratorUser32]::PostMessage($HostHandle, 0x0101, $KeyCode, [IntPtr]::Zero) | Out-Null
    Start-Sleep -Milliseconds 450
    $Snapshots.Add((Get-FocusSnapshot))
}

$terminalSummarySnapshot = $null
$terminalSummaryAfterTraversalSnapshot = $null

try {
    $arguments = @(
        '--report', (Quote-Argument $shellReportPath),
        '--command', (Quote-Argument $Command),
        '--browser-url', (Quote-Argument $BrowserUrl),
        '--browser-title', (Quote-Argument $BrowserTitle),
        '--browser-helper', (Quote-Argument $BrowserHelperPath),
        '--manual-focus',
        '--hold-open-ms', '1500'
    ) -join ' '

    $process = Start-Process -FilePath $OutputPath -ArgumentList $arguments -PassThru

    $hostName = 'cmux Shell Host Spike'
    $hostElement = $null
    $deadline = (Get-Date).AddSeconds(12)
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
        $hostElement = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst(
            [System.Windows.Automation.TreeScope]::Children,
            $hostCondition
        )
        if ($null -ne $hostElement) { break }
        Start-Sleep -Milliseconds 150
    }

    if ($null -eq $hostElement) {
        throw 'Expected shell host window before terminal narrator baseline probe'
    }

    $null = Wait-ForLogPattern -Path $actionLogPath -Pattern 'stage:browser-helper-ready' -TimeoutMs 8000
    $null = Wait-ForLogPattern -Path $focusLogPath -Pattern 'reason=manual-initial' -TimeoutMs 8000

    $hostHandle = [IntPtr]::new($hostElement.Current.NativeWindowHandle)
    try { $hostElement.SetFocus() } catch {}
    [CmuxTerminalNarratorUser32]::ShowWindow($hostHandle, 9) | Out-Null
    [CmuxTerminalNarratorUser32]::BringWindowToTop($hostHandle) | Out-Null
    [CmuxTerminalNarratorUser32]::SetForegroundWindow($hostHandle) | Out-Null
    Start-Sleep -Milliseconds 250

    $terminalElement = Find-AutomationIdDescendant -Root $hostElement -AutomationId '2001'
    $terminalSummaryElement = if ($null -ne $terminalElement) {
        Find-AutomationIdDescendant -Root $terminalElement -AutomationId '2101'
    } else { $null }

    $f6Key = [System.UIntPtr]::new(0x75)
    $snapshots = New-Object System.Collections.Generic.List[object]
    $snapshots.Add((Get-FocusSnapshot))
    Invoke-F6Traversal -HostHandle $hostHandle -KeyCode $f6Key -Snapshots $snapshots
    Invoke-F6Traversal -HostHandle $hostHandle -KeyCode $f6Key -Snapshots $snapshots
    Invoke-F6Traversal -HostHandle $hostHandle -KeyCode $f6Key -Snapshots $snapshots
    Invoke-F6Traversal -HostHandle $hostHandle -KeyCode $f6Key -Snapshots $snapshots

    $terminalSummaryAfterTraversal = if ($null -ne $terminalElement) {
        Find-AutomationIdDescendant -Root $terminalElement -AutomationId '2101'
    } else { $null }

    $terminalSummarySnapshot = Get-ElementSnapshot $terminalSummaryElement
    $terminalSummaryAfterTraversalSnapshot = Get-ElementSnapshot $terminalSummaryAfterTraversal

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
$focusLog = if (Test-Path $focusLogPath) { Get-Content -Raw $focusLogPath } else { '' }

$snapshotsArray = @($snapshots | Where-Object { $null -ne $_ })
$snapshotNames = @($snapshotsArray | ForEach-Object { $_.name })

$browserNarratable =
    ($snapshotNames | Where-Object { (Test-NameMatches -Name $_ -ExpectedPrefix 'cmux Browser Host Pane') -or (Test-NameMatches -Name $_ -ExpectedPrefix 'cmux WebView2 Child Host') }).Count -gt 0 -or
    ($focusLog -match 'focus=browser reason=keyboard-cycle actual=true')

$terminalNarratable =
    ($snapshotNames | Where-Object { Test-NameMatches -Name $_ -ExpectedPrefix 'cmux Terminal Pane' }).Count -gt 0 -or
    ($focusLog -match 'focus=terminal reason=keyboard-cycle actual=true')

$terminalSummaryNarratable =
    $null -ne $terminalSummarySnapshot -and
    $null -ne $terminalSummaryAfterTraversalSnapshot -and
    $terminalSummarySnapshot.name.StartsWith('cmux Terminal Content Summary - ', [System.StringComparison]::Ordinal) -and
    $terminalSummarySnapshot.name.Contains('terminal-narrator-alpha') -and
    $terminalSummaryAfterTraversalSnapshot.name.Contains('terminal-narrator-alpha')

$controlTypesPresent = ($snapshotsArray | Where-Object { -not [string]::IsNullOrWhiteSpace($_.controlType) }).Count -eq $snapshotsArray.Count
$terminalContentSummary = [string]$shellReport.terminalContentSummary
$terminalContentSummaryContainsMarker = $terminalContentSummary.Contains('terminal-narrator-alpha') -and $terminalContentSummary.Contains('proof-line')

$report = [ordered]@{
    browserNarratable = $browserNarratable
    terminalNarratable = $terminalNarratable
    terminalSummaryNarratable = $terminalSummaryNarratable
    terminalSummary = $terminalSummarySnapshot
    terminalSummaryAfterTraversal = $terminalSummaryAfterTraversalSnapshot
    terminalContentSummary = $terminalContentSummary
    terminalContentSummaryContainsMarker = $terminalContentSummaryContainsMarker
    controlTypesPresent = $controlTypesPresent
    snapshots = $snapshotsArray
    keyboardTraversalCount = [int]$shellReport.keyboardTraversalCount
    focusTransferCount = [int]$shellReport.focusTransferCount
    shellReportPath = $shellReportPath
    focusLogPath = $shellReport.focusLogPath
    exitCode = $process.ExitCode
}
$report | ConvertTo-Json -Depth 8 | Set-Content -Path $reportPath -Encoding utf8

if (-not $browserNarratable) {
    throw 'Expected terminal narrator baseline to still reach browser semantics'
}
if (-not $terminalNarratable) {
    throw 'Expected terminal narrator baseline to reach terminal pane semantics'
}
if (-not $terminalSummaryNarratable) {
    throw 'Expected terminal narrator baseline to keep the terminal summary child discoverable with transcript-derived semantics'
}
if (-not $terminalContentSummaryContainsMarker) {
    throw "Expected terminalContentSummary to include terminal-narrator-alpha and proof-line but found '$terminalContentSummary'"
}
if (-not $controlTypesPresent) {
    throw 'Expected focused accessibility snapshots to expose control types'
}
if ($shellReport.keyboardTraversalCount -lt 2) {
    throw "Expected keyboardTraversalCount >= 2 but found $($shellReport.keyboardTraversalCount)"
}
if ($process.ExitCode -ne 0) {
    throw "Expected shell host spike to exit 0 but found $($process.ExitCode)"
}

Write-Host "Shell host terminal narrator baseline spike passed"
Write-Host $reportPath
