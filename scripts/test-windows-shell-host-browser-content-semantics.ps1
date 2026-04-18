param(
    [string]$ArtifactDirectory = $(Join-Path $env:TEMP ("cmux-shell-host-browser-content-semantics-" + [guid]::NewGuid().Guid)),
    [string]$OutputPath = $(Join-Path $ArtifactDirectory 'cmux_windows_shell_host_spike.exe'),
    [string]$BrowserHelperPath = $(Join-Path $ArtifactDirectory 'cmux_windows_webview2_child_host.exe'),
    [string]$GhosttyRoot = $(Join-Path $PSScriptRoot '..\..\ghostty'),
    [string]$Command = 'echo shell-host-spike && echo proof-line',
    [string]$BrowserUrl = "data:text/html,<html><head><title>DG18 Browser Content</title></head><body><main><h1>DG18 Browser Content</h1><button aria-label='Browser Action'>Browser Action</button><a href='https://example.invalid/'>Browser Link</a></main></body></html>",
    [string]$BrowserTitle = 'DG18 Browser Content'
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class CmuxBrowserContentUser32 {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool PostMessage(IntPtr hWnd, uint Msg, UIntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
}
"@

$artifactPath = New-Item -ItemType Directory -Force -Path $ArtifactDirectory
$ghosttyRootPath = (Resolve-Path $GhosttyRoot).Path
$ghosttyLibrary = Join-Path $ghosttyRootPath 'zig-out\lib\libghostty.so'
$ghosttyResources = Join-Path $ghosttyRootPath 'zig-out\share\ghostty'
$fontconfigPath = Join-Path $artifactPath.FullName 'fonts.conf'
$fontconfigConfDir = Join-Path $artifactPath.FullName 'conf.d'

if (-not (Test-Path $ghosttyLibrary)) { throw "Ghostty shared library not found: $ghosttyLibrary" }
if (-not (Test-Path $ghosttyResources)) { throw "Ghostty resources directory not found: $ghosttyResources" }

$fontconfigPackage = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'zig\p') -Recurse -File -Filter 'fonts.conf.in' |
    Select-Object -First 1
if (-not $fontconfigPackage) { throw 'Could not locate cached fontconfig package source' }

$fontconfigPackageRoot = Split-Path -Parent $fontconfigPackage.FullName
New-Item -ItemType Directory -Force -Path $fontconfigConfDir | Out-Null
Copy-Item -Path (Join-Path $fontconfigPackageRoot 'conf.d\*') -Destination $fontconfigConfDir -Recurse -Force

$fontconfigContents = @"
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <description>cmux shell host browser content semantics spike</description>
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

$reportPath = Join-Path $artifactPath.FullName 'shell-host-browser-content-semantics-report.json'
$shellReportPath = Join-Path $artifactPath.FullName 'shell-host-report.json'
$browserHelperReportPath = Join-Path $artifactPath.FullName 'shell-host-browser-report.json'

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

function Find-NamedDescendantByPrefix {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string]$NamePrefix
    )

    try {
        $all = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    } catch {
        return $null
    }
    for ($index = 0; $index -lt $all.Count; $index++) {
        $candidate = $all.Item($index)
        if (-not [string]::IsNullOrWhiteSpace($candidate.Current.Name) -and
            $candidate.Current.Name.StartsWith($NamePrefix, [System.StringComparison]::Ordinal)) {
            return $candidate
        }
    }
    return $null
}

function Get-DescendantSnapshots {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [int]$Limit = 32
    )

    $results = @()
    if ($null -eq $Root) { return $results }
    try {
        $all = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    } catch {
        return $results
    }
    for ($index = 0; $index -lt $all.Count -and $index -lt $Limit; $index++) {
        $candidate = $all.Item($index)
        $results += [pscustomobject]@{
            name = $candidate.Current.Name
            controlType = $candidate.Current.ControlType.ProgrammaticName
            automationId = $candidate.Current.AutomationId
            className = $candidate.Current.ClassName
        }
    }
    return $results
}

function Get-FocusedSnapshot {
    $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
    if ($null -eq $focused) { return $null }

    return [pscustomobject]@{
        name = $focused.Current.Name
        controlType = $focused.Current.ControlType.ProgrammaticName
        automationId = $focused.Current.AutomationId
        className = $focused.Current.ClassName
    }
}

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

$browserChildSnapshot = $null
$browserDocumentSnapshot = $null
$browserContentDescendants = @()
$focusedAfterBrowserTab = $null
$focusSnapshots = New-Object System.Collections.Generic.List[object]

try {
    $deadline = (Get-Date).AddSeconds(12)
    while ((Get-Date) -lt $deadline -and -not $process.HasExited) {
        $hostCondition = New-Object System.Windows.Automation.AndCondition(
            (New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::NameProperty,
                'cmux Shell Host Spike'
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
        if ($null -ne $hostElement) {
            $browserChild = Find-NamedDescendantByPrefix -Root $hostElement -NamePrefix 'cmux WebView2 Child Host - '
            if ($null -ne $browserChild) {
                $browserDocument = $browserChild.FindFirst(
                    [System.Windows.Automation.TreeScope]::Descendants,
                    (New-Object System.Windows.Automation.PropertyCondition(
                        [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
                        'RootWebArea'
                    ))
                )
                $browserChildSnapshot = [pscustomobject]@{
                    name = $browserChild.Current.Name
                    controlType = $browserChild.Current.ControlType.ProgrammaticName
                    automationId = $browserChild.Current.AutomationId
                    className = $browserChild.Current.ClassName
                }
                if ($null -ne $browserDocument) {
                    $browserDocumentSnapshot = [pscustomobject]@{
                        name = $browserDocument.Current.Name
                        controlType = $browserDocument.Current.ControlType.ProgrammaticName
                        automationId = $browserDocument.Current.AutomationId
                        className = $browserDocument.Current.ClassName
                    }
                }
                $browserContentDescendants = Get-DescendantSnapshots -Root $browserChild
                $buttonSeen = ($browserContentDescendants | Where-Object { $_.name -eq 'Browser Action' -and $_.controlType -eq 'ControlType.Button' }).Count -gt 0
                $headerSeen = ($browserContentDescendants | Where-Object { $_.name -eq 'DG18 Browser Content' }).Count -gt 0
                if ($headerSeen -and $null -ne $browserDocument) {
                    break
                }
            }
        }
        Start-Sleep -Milliseconds 150
    }

    if ($null -ne $browserChildSnapshot) {
        $hostHandle = [IntPtr]::new($hostElement.Current.NativeWindowHandle)
        [CmuxBrowserContentUser32]::ShowWindow($hostHandle, 9) | Out-Null
        [CmuxBrowserContentUser32]::BringWindowToTop($hostHandle) | Out-Null
        [CmuxBrowserContentUser32]::SetForegroundWindow($hostHandle) | Out-Null

        $f6Key = [System.UIntPtr]::new(0x75)
        [CmuxBrowserContentUser32]::PostMessage($hostHandle, 0x0100, $f6Key, [IntPtr]::Zero) | Out-Null
        [CmuxBrowserContentUser32]::PostMessage($hostHandle, 0x0101, $f6Key, [IntPtr]::Zero) | Out-Null
        Start-Sleep -Milliseconds 450

        try { $browserChild.SetFocus() } catch {}
        if ($null -ne $browserDocument) {
            try { $browserDocument.SetFocus() } catch {}
        }
        Start-Sleep -Milliseconds 500

        for ($step = 0; $step -lt 3; $step++) {
            [CmuxBrowserContentUser32]::keybd_event(0x09, 0, 0, [System.UIntPtr]::Zero)
            Start-Sleep -Milliseconds 50
            [CmuxBrowserContentUser32]::keybd_event(0x09, 0, 2, [System.UIntPtr]::Zero)
            Start-Sleep -Milliseconds 350
            $snapshot = Get-FocusedSnapshot
            if ($null -ne $snapshot) {
                $focusSnapshots.Add($snapshot)
            }
        }

        $focusedAfterBrowserTab = if ($focusSnapshots.Count -gt 0) { $focusSnapshots[$focusSnapshots.Count - 1] } else { $null }
        $browserContentDescendants = Get-DescendantSnapshots -Root $browserChild
    }

    $process.WaitForExit()
}
finally {
    $env:CMUX_GHOSTTY_LIB = $previousGhosttyLib
    $env:GHOSTTY_RESOURCES_DIR = $previousGhosttyResources
    $env:FONTCONFIG_FILE = $previousFontconfigFile
    $env:FONTCONFIG_PATH = $previousFontconfigPath
}

$buttonSeen = ($browserContentDescendants | Where-Object { $_.name -eq 'Browser Action' -and $_.controlType -eq 'ControlType.Button' }).Count -gt 0
$headerSeen = ($browserContentDescendants | Where-Object { $_.name -eq 'DG18 Browser Content' }).Count -gt 0
$buttonFocused = $null -ne $focusedAfterBrowserTab -and
    $focusedAfterBrowserTab.name -eq 'Browser Action' -and
    $focusedAfterBrowserTab.controlType -eq 'ControlType.Button'
$focusSnapshotsArray = @($focusSnapshots.ToArray())
$buttonSeenInFocusSequence = ($focusSnapshotsArray | Where-Object {
        $null -ne $_ -and $_.name -eq 'Browser Action' -and $_.controlType -eq 'ControlType.Button'
    }).Count -gt 0
$browserHelperReport = if (Test-Path $browserHelperReportPath) {
    Get-Content $browserHelperReportPath -Raw | ConvertFrom-Json
} else {
    $null
}
$summaryContainsAction = $null -ne $browserHelperReport -and
    ([string]$browserHelperReport.contentSummary).Contains('Browser Action')
$shellReport = if (Test-Path $shellReportPath) {
    Get-Content $shellReportPath -Raw | ConvertFrom-Json
} else {
    $null
}
$shellSummaryContainsAction = $null -ne $shellReport -and
    ([string]$shellReport.browserContentSummary).Contains('Browser Action')

$report = [ordered]@{
    browserChild = $browserChildSnapshot
    browserDocument = $browserDocumentSnapshot
    browserContentDescendants = $browserContentDescendants
    browserContentHeaderSeen = $headerSeen
    browserContentButtonSeen = $buttonSeen
    browserContentButtonFocused = $buttonFocused
    browserContentButtonSeenInFocusSequence = $buttonSeenInFocusSequence
    browserContentSummary = if ($null -ne $browserHelperReport) { [string]$browserHelperReport.contentSummary } else { '' }
    browserContentSummaryContainsAction = $summaryContainsAction
    shellBrowserContentSummary = if ($null -ne $shellReport) { [string]$shellReport.browserContentSummary } else { '' }
    shellBrowserContentSummaryContainsAction = $shellSummaryContainsAction
    focusedAfterBrowserTab = $focusedAfterBrowserTab
    focusSnapshots = $focusSnapshotsArray
    shellReportPath = $shellReportPath
    browserHelperReportPath = $browserHelperReportPath
    exitCode = $process.ExitCode
}
$report | ConvertTo-Json -Depth 8 | Set-Content -Path $reportPath -Encoding utf8

if ($null -eq $browserChildSnapshot) {
    throw 'Expected browser content semantics probe to find the browser child host'
}
if (-not $headerSeen) {
    throw 'Expected browser content semantics probe to expose the DG18 Browser Content heading through UIA'
}
if (-not ($buttonSeen -or $buttonFocused -or $buttonSeenInFocusSequence -or $summaryContainsAction -or $shellSummaryContainsAction)) {
    throw 'Expected browser content semantics probe to expose the Browser Action button through UIA or the DOM-derived content summary contract'
}
if ($null -eq $shellReport) {
    throw "Expected shell host browser content semantics probe to produce $shellReportPath"
}
if (-not [bool]$shellReport.browserControllerReady) {
    throw 'Expected shell host browser content semantics probe to keep the browser controller ready'
}
if (-not [bool]$shellReport.transcriptContainsExpectedMarker) {
    throw 'Expected shell host browser content semantics probe to retain terminal transcript proof'
}

Write-Host "Shell host browser content semantics spike passed"
Write-Host $reportPath
