param(
    [string]$ArtifactDirectory = $(Join-Path $env:TEMP ("cmux-shell-host-terminal-summary-durability-" + [guid]::NewGuid().Guid)),
    [string]$OutputPath = $(Join-Path $ArtifactDirectory 'cmux_windows_shell_host_spike.exe'),
    [string]$BrowserHelperPath = $(Join-Path $ArtifactDirectory 'cmux_windows_webview2_child_host.exe'),
    [string]$GhosttyRoot = $(Join-Path $PSScriptRoot '..\..\ghostty'),
    [string]$Command = 'echo terminal-durability-alpha && ping -n 3 127.0.0.1 >nul && echo terminal-durability-beta && ping -n 3 127.0.0.1 >nul && echo terminal-durability-gamma && ping -n 3 127.0.0.1 >nul && echo shell-host-spike && echo proof-line',
    [string]$BrowserUrl = 'data:text/html,<html><head><title>DG22 Terminal Summary Durability</title></head><body>shell-host-browser</body></html>',
    [string]$BrowserTitle = 'DG22 Terminal Summary Durability'
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
  <description>cmux shell host terminal summary durability</description>
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

$reportPath = Join-Path $artifactPath.FullName 'shell-host-terminal-summary-durability-report.json'
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

function Get-ElementName {
    param([System.Windows.Automation.AutomationElement]$Element)

    if ($null -eq $Element) { return $null }
    return [string]$Element.Current.Name
}

try {
    $arguments = @(
        '--report', (Quote-Argument $shellReportPath),
        '--command', (Quote-Argument $Command),
        '--browser-url', (Quote-Argument $BrowserUrl),
        '--browser-title', (Quote-Argument $BrowserTitle),
        '--browser-helper', (Quote-Argument $BrowserHelperPath),
        '--hold-open-ms', '1200'
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
        throw 'Expected shell host window before terminal summary durability probe'
    }

    $summaryNames = New-Object System.Collections.Generic.List[string]
    $pollDeadline = (Get-Date).AddSeconds(12)
    while ((Get-Date) -lt $pollDeadline -and -not $process.HasExited) {
        $terminalElement = Find-AutomationIdDescendant -Root $hostElement -AutomationId '2001'
        $summaryElement = if ($null -ne $terminalElement) {
            Find-AutomationIdDescendant -Root $terminalElement -AutomationId '2101'
        } else { $null }

        $summaryName = Get-ElementName $summaryElement
        if (-not [string]::IsNullOrWhiteSpace($summaryName)) {
            $summaryNames.Add($summaryName)
        }

        Start-Sleep -Milliseconds 180
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
$summaryArray = @($summaryNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$distinctSummaryNames = @($summaryArray | Select-Object -Unique)

$sawAlphaWithoutGamma = ($summaryArray | Where-Object { $_.Contains('terminal-durability-alpha') -and -not $_.Contains('terminal-durability-gamma') }).Count -gt 0
$sawGamma = ($summaryArray | Where-Object { $_.Contains('terminal-durability-gamma') -or $_.Contains('terminal-durability-g') }).Count -gt 0
$sawMultipleSummaryStates = $distinctSummaryNames.Count -ge 2
$terminalContentSummary = [string]$shellReport.terminalContentSummary
$transcriptPreview = [string]$shellReport.transcriptPreview
$report = [ordered]@{
    sawAlphaWithoutGamma = $sawAlphaWithoutGamma
    sawGamma = $sawGamma
    sawMultipleSummaryStates = $sawMultipleSummaryStates
    sampleCount = $summaryArray.Count
    distinctSummaryCount = $distinctSummaryNames.Count
    distinctSummaryNames = $distinctSummaryNames
    terminalContentSummary = $terminalContentSummary
    transcriptPreview = $transcriptPreview
    exitCode = $process.ExitCode
    shellReportPath = $shellReportPath
}
$report | ConvertTo-Json -Depth 6 | Set-Content -Path $reportPath -Encoding utf8

if (-not $sawAlphaWithoutGamma) {
    throw 'Expected terminal summary to expose an earlier alpha-only state before the later transcript content arrived'
}
if (-not $sawGamma) {
    throw 'Expected terminal summary to expose the later gamma state during the running session'
}
if (-not $sawMultipleSummaryStates) {
    throw 'Expected terminal summary to change across the running session'
}
if (-not ($terminalContentSummary.Contains('terminal-durability-gamma') -or $terminalContentSummary.Contains('terminal-durability-g'))) {
    throw "Expected shell host report terminalContentSummary to include terminal-durability-gamma but found '$terminalContentSummary'"
}
if (-not $transcriptPreview.Contains('proof-line')) {
    throw "Expected shell host report transcriptPreview to include proof-line but found '$transcriptPreview'"
}
if ($process.ExitCode -ne 0) {
    throw "Expected shell host spike to exit 0 but found $($process.ExitCode)"
}

Write-Host 'Shell host terminal summary durability spike passed'
Write-Host $reportPath
