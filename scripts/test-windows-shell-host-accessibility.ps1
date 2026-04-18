param(
    [string]$ArtifactDirectory = $(Join-Path $env:TEMP ("cmux-shell-host-accessibility-" + [guid]::NewGuid().Guid)),
    [string]$OutputPath = $(Join-Path $ArtifactDirectory 'cmux_windows_shell_host_spike.exe'),
    [string]$BrowserHelperPath = $(Join-Path $ArtifactDirectory 'cmux_windows_webview2_child_host.exe'),
    [string]$GhosttyRoot = $(Join-Path $PSScriptRoot '..\..\ghostty'),
    [string]$Command = 'echo shell-host-spike && echo proof-line',
    [string]$BrowserUrl = 'data:text/html,<html><head><title>DG3 Shell Host Spike</title></head><body>shell-host-browser</body></html>',
    [string]$BrowserTitle = 'DG3 Shell Host Spike'
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
  <description>cmux shell host accessibility spike</description>
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

$reportPath = Join-Path $artifactPath.FullName 'shell-host-accessibility-report.json'
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
    '--browser-helper', (Quote-Argument $BrowserHelperPath)
) -join ' '

$process = Start-Process -FilePath $OutputPath -ArgumentList $arguments -PassThru

$hostFound = $false
$terminalFound = $false
$browserPaneFound = $false
$browserChildFound = $false
$descendantNames = New-Object System.Collections.Generic.List[string]
$deadline = (Get-Date).AddSeconds(12)
$hostName = 'cmux Shell Host Spike'
$terminalName = 'cmux Terminal Pane'
$browserPaneName = 'cmux Browser Host Pane'
$browserChildName = 'cmux WebView2 Child Host'

try {
    while ((Get-Date) -lt $deadline -and -not $process.HasExited) {
        $hostCondition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $hostName)
        $hostElement = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $hostCondition)
        if ($hostElement -ne $null) {
            $hostFound = $true
            $allDescendants = $hostElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
            $descendantNames.Clear()
            for ($index = 0; $index -lt $allDescendants.Count; $index += 1) {
                $name = $allDescendants.Item($index).Current.Name
                if (-not [string]::IsNullOrWhiteSpace($name)) {
                    [void]$descendantNames.Add($name)
                }
            }

            $terminalFound = ($descendantNames | Where-Object { Test-NameMatches -Name $_ -ExpectedPrefix $terminalName }).Count -gt 0
            $browserPaneFound = ($descendantNames | Where-Object { Test-NameMatches -Name $_ -ExpectedPrefix $browserPaneName }).Count -gt 0
            $browserChildFound = ($descendantNames | Where-Object { Test-NameMatches -Name $_ -ExpectedPrefix $browserChildName }).Count -gt 0

            if ($terminalFound -and $browserPaneFound -and $browserChildFound) {
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
    hostWindowFound = $hostFound
    terminalPaneFound = $terminalFound
    browserPaneFound = $browserPaneFound
    browserChildFound = $browserChildFound
    descendantNames = @($descendantNames)
    shellReportPath = $shellReportPath
    exitCode = $process.ExitCode
}

$report | ConvertTo-Json -Depth 4 | Set-Content -Path $reportPath -Encoding utf8

if (-not $hostFound) {
    throw 'Expected UI Automation host window to be discoverable'
}
if (-not $terminalFound) {
    throw 'Expected UI Automation to expose the terminal pane'
}
if (-not $browserPaneFound) {
    throw 'Expected UI Automation to expose the browser pane host'
}
if (-not $browserChildFound) {
    throw 'Expected UI Automation to expose the WebView2 child host'
}
if ($process.ExitCode -ne 0) {
    throw "Expected shell host spike to exit 0 but found $($process.ExitCode)"
}

Write-Host "Shell host accessibility spike passed"
Write-Host $reportPath
