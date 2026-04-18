param(
    [string]$ArtifactDirectory = $(Join-Path $env:TEMP ("cmux-shell-host-terminal-summary-semantics-" + [guid]::NewGuid().Guid)),
    [string]$OutputPath = $(Join-Path $ArtifactDirectory 'cmux_windows_shell_host_spike.exe'),
    [string]$BrowserHelperPath = $(Join-Path $ArtifactDirectory 'cmux_windows_webview2_child_host.exe'),
    [string]$GhosttyRoot = $(Join-Path $PSScriptRoot '..\..\ghostty'),
    [string]$Command = 'echo terminal-summary-alpha && echo shell-host-spike && echo proof-line',
    [string]$BrowserUrl = 'data:text/html,<html><head><title>DG20 Terminal Summary Semantics</title></head><body><main><h1>DG20 Terminal Summary Semantics</h1></main></body></html>',
    [string]$BrowserTitle = 'DG20 Terminal Summary Semantics'
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
  <description>cmux shell host terminal summary semantics spike</description>
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

$reportPath = Join-Path $artifactPath.FullName 'shell-host-terminal-summary-semantics-report.json'
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
$terminalSummarySnapshot = $null

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
            $terminalElement = Find-AutomationIdDescendant -Root $hostElement -AutomationId '2001'
            $terminalSnapshot = Get-ElementSnapshot $terminalElement
            if ($null -ne $terminalElement) {
                $terminalSummarySnapshot = Get-ElementSnapshot (Find-AutomationIdDescendant -Root $terminalElement -AutomationId '2101')
            }

            $summaryReady =
                $null -ne $terminalSummarySnapshot -and
                $terminalSummarySnapshot.name.StartsWith('cmux Terminal Content Summary - ', [System.StringComparison]::Ordinal) -and
                $terminalSummarySnapshot.name.Contains('terminal-summary-alpha')

            if ($summaryReady) {
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
$terminalContentSummary = [string]$shellReport.terminalContentSummary
$report = [ordered]@{
    host = $hostSnapshot
    terminalPane = $terminalSnapshot
    terminalSummary = $terminalSummarySnapshot
    shellReportPath = $shellReportPath
    terminalContentSummary = $terminalContentSummary
    transcriptPreview = [string]$shellReport.transcriptPreview
    exitCode = $process.ExitCode
}
$report | ConvertTo-Json -Depth 6 | Set-Content -Path $reportPath -Encoding utf8

if ($null -eq $terminalSnapshot) {
    throw 'Expected terminal summary semantics probe to find the terminal pane'
}
if ($null -eq $terminalSummarySnapshot) {
    throw 'Expected terminal summary semantics probe to find the terminal summary accessibility child'
}
if ($terminalSummarySnapshot.automationId -ne '2101') {
    throw "Expected terminal summary automation id 2101 but found '$($terminalSummarySnapshot.automationId)'"
}
if (-not $terminalSummarySnapshot.name.StartsWith('cmux Terminal Content Summary - ', [System.StringComparison]::Ordinal)) {
    throw "Expected terminal summary control to expose a structured summary label but found '$($terminalSummarySnapshot.name)'"
}
if (-not $terminalSummarySnapshot.name.Contains('terminal-summary-alpha')) {
    throw "Expected terminal summary label to include terminal-summary-alpha but found '$($terminalSummarySnapshot.name)'"
}
if (-not $terminalContentSummary.Contains('terminal-summary-alpha')) {
    throw "Expected shell host report terminalContentSummary to include terminal-summary-alpha but found '$terminalContentSummary'"
}
if (-not $terminalContentSummary.Contains('proof-line')) {
    throw "Expected shell host report terminalContentSummary to include proof-line but found '$terminalContentSummary'"
}
if ($process.ExitCode -ne 0) {
    throw "Expected shell host spike to exit 0 but found $($process.ExitCode)"
}

Write-Host "Shell host terminal summary semantics spike passed"
Write-Host $reportPath
