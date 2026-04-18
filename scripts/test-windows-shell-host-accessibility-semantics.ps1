param(
    [string]$ArtifactDirectory = $(Join-Path $env:TEMP ("cmux-shell-host-accessibility-semantics-" + [guid]::NewGuid().Guid)),
    [string]$OutputPath = $(Join-Path $ArtifactDirectory 'cmux_windows_shell_host_spike.exe'),
    [string]$BrowserHelperPath = $(Join-Path $ArtifactDirectory 'cmux_windows_webview2_child_host.exe'),
    [string]$GhosttyRoot = $(Join-Path $PSScriptRoot '..\..\ghostty'),
    [string]$Command = 'echo shell-host-spike && echo proof-line',
    [string]$BrowserUrl = 'data:text/html,<html><head><title>DG7 Shell Host Semantics</title></head><body>shell-host-browser</body></html>',
    [string]$BrowserTitle = 'DG7 Shell Host Semantics'
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class CmuxAccessibilitySemanticsUser32 {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool IsChild(IntPtr hWndParent, IntPtr hWnd);
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
  <description>cmux shell host accessibility semantics spike</description>
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

$reportPath = Join-Path $artifactPath.FullName 'shell-host-accessibility-semantics-report.json'
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

function Find-NamedDescendant {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string]$Name
    )

    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty,
        $Name
    )
    return $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Find-NamedDescendantByPrefix {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string]$NamePrefix
    )

    $all = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    for ($index = 0; $index -lt $all.Count; $index++) {
        $candidate = $all.Item($index)
        if (-not [string]::IsNullOrWhiteSpace($candidate.Current.Name) -and
            $candidate.Current.Name.StartsWith($NamePrefix, [System.StringComparison]::Ordinal)) {
            return $candidate
        }
    }
    return $null
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

function Test-NameMatches {
    param(
        [string]$Name,
        [string]$ExpectedPrefix
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    return $Name.StartsWith($ExpectedPrefix, [System.StringComparison]::Ordinal)
}

function Get-DirectChildSnapshots {
    param([System.Windows.Automation.AutomationElement]$Root)

    $children = $Root.FindAll(
        [System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.Condition]::TrueCondition
    )

    $snapshots = @()
    for ($index = 0; $index -lt $children.Count; $index++) {
        $snapshots += ,(Get-ElementSnapshot $children.Item($index))
    }
    return $snapshots
}

function Get-ElementSnapshot {
    param([System.Windows.Automation.AutomationElement]$Element)

    if ($null -eq $Element) { return $null }
    return [ordered]@{
        name = $Element.Current.Name
        className = $Element.Current.ClassName
        controlType = $Element.Current.ControlType.ProgrammaticName
        isKeyboardFocusable = [bool]$Element.Current.IsKeyboardFocusable
        automationId = $Element.Current.AutomationId
        nativeWindowHandle = [int64]$Element.Current.NativeWindowHandle
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

$hostName = 'cmux Shell Host Spike'
$terminalName = 'cmux Terminal Pane'
$browserPaneName = 'cmux Browser Host Pane'
$splitterName = 'cmux Splitter'
$browserChildName = 'cmux WebView2 Child Host'

$hostSnapshot = $null
$terminalSnapshot = $null
$browserPaneSnapshot = $null
$splitterSnapshot = $null
$browserChildSnapshot = $null
$browserChildWithinBrowserPane = $false
$browserChildNativeWithinBrowserPane = $false
$hostChildren = @()

try {
    $deadline = (Get-Date).AddSeconds(12)
    while ((Get-Date) -lt $deadline -and -not $process.HasExited) {
        $hostCondition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::NameProperty,
            $hostName
        )
        $hostElement = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst(
            [System.Windows.Automation.TreeScope]::Children,
            $hostCondition
        )
        if ($null -ne $hostElement) {
            $hostSnapshot = Get-ElementSnapshot $hostElement
            $hostChildren = Get-DirectChildSnapshots $hostElement
            $terminalElement = Find-AutomationIdDescendant -Root $hostElement -AutomationId '2001'
            $browserPaneElement = Find-AutomationIdDescendant -Root $hostElement -AutomationId '2003'
            $splitterElement = Find-AutomationIdDescendant -Root $hostElement -AutomationId '2002'
            $browserChildElement = Find-NamedDescendantByPrefix -Root $hostElement -NamePrefix $browserChildName
            $terminalSnapshot = Get-ElementSnapshot $terminalElement
            $browserPaneSnapshot = Get-ElementSnapshot $browserPaneElement
            $splitterSnapshot = Get-ElementSnapshot $splitterElement
            $browserChildSnapshot = Get-ElementSnapshot $browserChildElement
            if ($null -ne $browserPaneElement -and $null -ne $browserChildElement) {
                $browserChildWithinBrowserPane = $null -ne (Find-NamedDescendant -Root $browserPaneElement -Name $browserChildName)
                if ($browserPaneElement.Current.NativeWindowHandle -ne 0 -and $browserChildElement.Current.NativeWindowHandle -ne 0) {
                    $browserChildNativeWithinBrowserPane = [CmuxAccessibilitySemanticsUser32]::IsChild(
                        [IntPtr]::new([long]$browserPaneElement.Current.NativeWindowHandle),
                        [IntPtr]::new([long]$browserChildElement.Current.NativeWindowHandle)
                    )
                }
            }

            if ($null -ne $terminalSnapshot -and
                $null -ne $browserPaneSnapshot -and
                $null -ne $splitterSnapshot -and
                $null -ne $browserChildSnapshot) {
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

$report = [ordered]@{
    host = $hostSnapshot
    terminalPane = $terminalSnapshot
    browserPane = $browserPaneSnapshot
    splitter = $splitterSnapshot
    browserChild = $browserChildSnapshot
    hostChildren = $hostChildren
    browserChildWithinBrowserPane = $browserChildWithinBrowserPane
    browserChildNativeWithinBrowserPane = $browserChildNativeWithinBrowserPane
    shellReportPath = $shellReportPath
    exitCode = $process.ExitCode
}
$report | ConvertTo-Json -Depth 6 | Set-Content -Path $reportPath -Encoding utf8

if ($null -eq $hostSnapshot) {
    throw 'Expected UIA semantics probe to find the shell host'
}
if ($null -eq $terminalSnapshot) {
    throw 'Expected UIA semantics probe to find the terminal pane host'
}
if ($null -eq $browserPaneSnapshot) {
    throw 'Expected UIA semantics probe to find the browser pane host'
}
if ($null -eq $splitterSnapshot) {
    throw 'Expected UIA semantics probe to find the splitter host'
}
if ($null -eq $browserChildSnapshot) {
    throw 'Expected UIA semantics probe to find the browser child host'
}
if (-not (Test-NameMatches -Name $terminalSnapshot.name -ExpectedPrefix $terminalName)) {
    throw "Expected terminal pane host name to start with '$terminalName' but found '$($terminalSnapshot.name)'"
}
if (-not (Test-NameMatches -Name $browserPaneSnapshot.name -ExpectedPrefix $browserPaneName)) {
    throw "Expected browser pane host name to start with '$browserPaneName' but found '$($browserPaneSnapshot.name)'"
}
if (-not (Test-NameMatches -Name $browserChildSnapshot.name -ExpectedPrefix $browserChildName)) {
    throw "Expected browser child host name to start with '$browserChildName' but found '$($browserChildSnapshot.name)'"
}
if ($terminalSnapshot.automationId -ne '2001') {
    throw "Expected terminal pane host automationId 2001 but found '$($terminalSnapshot.automationId)'"
}
if ($splitterSnapshot.automationId -ne '2002') {
    throw "Expected splitter host automationId 2002 but found '$($splitterSnapshot.automationId)'"
}
if ($browserPaneSnapshot.automationId -ne '2003') {
    throw "Expected browser pane host automationId 2003 but found '$($browserPaneSnapshot.automationId)'"
}
if ([string]::IsNullOrWhiteSpace($terminalSnapshot.controlType)) {
    throw 'Expected terminal pane host to expose a control type'
}
if ([string]::IsNullOrWhiteSpace($browserPaneSnapshot.controlType)) {
    throw 'Expected browser pane host to expose a control type'
}
if ([string]::IsNullOrWhiteSpace($splitterSnapshot.controlType)) {
    throw 'Expected splitter host to expose a control type'
}
if ([string]::IsNullOrWhiteSpace($browserChildSnapshot.controlType)) {
    throw 'Expected browser child host to expose a control type'
}
if (-not ($browserChildWithinBrowserPane -or $browserChildNativeWithinBrowserPane)) {
    throw 'Expected browser child host to remain associated with the browser pane host through UIA or native child ownership'
}
$directChildNames = @($hostChildren | Where-Object { $null -ne $_ } | ForEach-Object { $_.name })
if ($directChildNames.Count -lt 3) {
    throw 'Expected shell host to expose at least three direct semantic children'
}
$expectedChildPrefixes = @($terminalName, $splitterName, $browserPaneName)
for ($index = 0; $index -lt $expectedChildPrefixes.Count; $index++) {
    if (-not (Test-NameMatches -Name $directChildNames[$index] -ExpectedPrefix $expectedChildPrefixes[$index])) {
        throw "Expected shell host child index $index to start with '$($expectedChildPrefixes[$index])' but found '$($directChildNames[$index])'"
    }
}
if ($process.ExitCode -ne 0) {
    throw "Expected shell host spike to exit 0 but found $($process.ExitCode)"
}

Write-Host "Shell host accessibility semantics spike passed"
Write-Host $reportPath
