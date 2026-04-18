param(
    [string]$ArtifactDirectory = $(Join-Path $env:TEMP ("cmux-shell-host-content-semantics-" + [guid]::NewGuid().Guid)),
    [string]$OutputPath = $(Join-Path $ArtifactDirectory 'cmux_windows_shell_host_spike.exe'),
    [string]$BrowserHelperPath = $(Join-Path $ArtifactDirectory 'cmux_windows_webview2_child_host.exe'),
    [string]$GhosttyRoot = $(Join-Path $PSScriptRoot '..\..\ghostty'),
    [string]$Command = 'echo shell-host-spike && echo proof-line',
    [string]$BrowserUrl = 'data:text/html,<html><head><title>DG17 Content Semantics</title></head><body><main><h1>DG17 Content Semantics</h1><button>Browser Action</button></main></body></html>',
    [string]$BrowserTitle = 'DG17 Content Semantics'
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

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
  <description>cmux shell host content semantics spike</description>
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

$reportPath = Join-Path $artifactPath.FullName 'shell-host-content-semantics-report.json'
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

function Get-ElementSnapshot {
    param([System.Windows.Automation.AutomationElement]$Element)

    if ($null -eq $Element) { return $null }
    return [ordered]@{
        name = $Element.Current.Name
        className = $Element.Current.ClassName
        controlType = $Element.Current.ControlType.ProgrammaticName
        isKeyboardFocusable = [bool]$Element.Current.IsKeyboardFocusable
        automationId = $Element.Current.AutomationId
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

$hostSnapshot = $null
$terminalSnapshot = $null
$browserPaneSnapshot = $null
$browserChildSnapshot = $null

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
            $hostSnapshot = Get-ElementSnapshot $hostElement
            $terminalSnapshot = Get-ElementSnapshot (Find-AutomationIdDescendant -Root $hostElement -AutomationId '2001')
            $browserPaneSnapshot = Get-ElementSnapshot (Find-AutomationIdDescendant -Root $hostElement -AutomationId '2003')
            $browserChildSnapshot = Get-ElementSnapshot (Find-NamedDescendantByPrefix -Root $hostElement -NamePrefix 'cmux WebView2 Child Host')

            $terminalReady =
                $null -ne $terminalSnapshot -and
                $terminalSnapshot.name.StartsWith('cmux Terminal Pane - ', [System.StringComparison]::Ordinal) -and
                $terminalSnapshot.name.Contains('shell-host-spike')
            $browserPaneReady =
                $null -ne $browserPaneSnapshot -and
                $browserPaneSnapshot.name.StartsWith('cmux Browser Host Pane - ', [System.StringComparison]::Ordinal) -and
                $browserPaneSnapshot.name.Contains($BrowserTitle)
            $browserChildReady =
                $null -ne $browserChildSnapshot -and
                $browserChildSnapshot.name.StartsWith('cmux WebView2 Child Host - ', [System.StringComparison]::Ordinal) -and
                $browserChildSnapshot.name.Contains($BrowserTitle)

            if ($terminalReady -and $browserPaneReady -and $browserChildReady) {
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

$shellReport = Get-Content $shellReportPath -Raw | ConvertFrom-Json
$report = [ordered]@{
    host = $hostSnapshot
    terminalPane = $terminalSnapshot
    browserPane = $browserPaneSnapshot
    browserChild = $browserChildSnapshot
    shellReportPath = $shellReportPath
    transcriptPreview = [string]$shellReport.transcriptPreview
    browserFinalTitle = [string]$shellReport.browserFinalTitle
    browserContentSummary = [string]$shellReport.browserContentSummary
    exitCode = $process.ExitCode
}
$report | ConvertTo-Json -Depth 6 | Set-Content -Path $reportPath -Encoding utf8

if ($null -eq $terminalSnapshot) {
    throw 'Expected content semantics probe to find the terminal pane'
}
if ($null -eq $browserPaneSnapshot) {
    throw 'Expected content semantics probe to find the browser pane'
}
if ($null -eq $browserChildSnapshot) {
    throw 'Expected content semantics probe to find the browser child host'
}
if (-not $terminalSnapshot.name.StartsWith('cmux Terminal Pane - ', [System.StringComparison]::Ordinal)) {
    throw "Expected terminal pane host to expose a content label but found '$($terminalSnapshot.name)'"
}
if (-not $terminalSnapshot.name.Contains('shell-host-spike')) {
    throw "Expected terminal pane host content label to include shell-host-spike but found '$($terminalSnapshot.name)'"
}
if (-not $browserPaneSnapshot.name.StartsWith('cmux Browser Host Pane - ', [System.StringComparison]::Ordinal)) {
    throw "Expected browser pane host to expose a content label but found '$($browserPaneSnapshot.name)'"
}
if (-not $browserPaneSnapshot.name.Contains($BrowserTitle)) {
    throw "Expected browser pane host content label to include '$BrowserTitle' but found '$($browserPaneSnapshot.name)'"
}
if (-not $browserChildSnapshot.name.StartsWith('cmux WebView2 Child Host - ', [System.StringComparison]::Ordinal)) {
    throw "Expected browser child host to expose a content label but found '$($browserChildSnapshot.name)'"
}
if (-not $browserChildSnapshot.name.Contains($BrowserTitle)) {
    throw "Expected browser child host content label to include '$BrowserTitle' but found '$($browserChildSnapshot.name)'"
}
if (-not ([string]$shellReport.browserContentSummary).Contains('Browser Action')) {
    throw "Expected browser content summary to include Browser Action but found '$([string]$shellReport.browserContentSummary)'"
}
if ($process.ExitCode -ne 0) {
    throw "Expected shell host spike to exit 0 but found $($process.ExitCode)"
}

Write-Host "Shell host content semantics spike passed"
Write-Host $reportPath
