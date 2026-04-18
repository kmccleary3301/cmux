param(
    [string]$HelperPath = '',
    [string]$ArtifactDirectory = $(Join-Path $env:TEMP ("cmux-windows-webview2-spike-" + [guid]::NewGuid().Guid))
)

$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Force -Path $ArtifactDirectory | Out-Null

$resolvedHelperPath = if ([string]::IsNullOrWhiteSpace($HelperPath)) {
    $builtPath = Join-Path $ArtifactDirectory 'cmux_windows_webview2_spike.exe'
    & (Join-Path $PSScriptRoot 'build-windows-webview2-spike.ps1') -OutputPath $builtPath | Out-Null
    $builtPath
} else {
    (Resolve-Path $HelperPath -ErrorAction Stop).Path
}

$reportPath = Join-Path $ArtifactDirectory 'webview2-report.json'
$url = 'data:text/html,<html><head><title>DG2 Browser Spike</title></head><body>proof-line</body></html>'

& $resolvedHelperPath --operation open-panel --url $url --title 'DG2 Browser Spike' --report $reportPath | Out-Null

if (-not (Test-Path $reportPath)) {
    throw "WebView2 spike report was not written to $reportPath"
}

$report = Get-Content $reportPath -Raw | ConvertFrom-Json

if ($report.hostKind -ne 'webview2') {
    throw "Expected hostKind=webview2 but found '$($report.hostKind)'"
}
if (-not $report.controllerReady) {
    throw 'Expected controllerReady=true'
}
if (-not $report.navigationCompleted) {
    throw 'Expected navigationCompleted=true'
}
if (-not $report.success) {
    throw "Expected success=true but found false (failureCategory=$($report.failureCategory))"
}
if ($report.finalTitle -ne 'DG2 Browser Spike') {
    throw "Expected finalTitle='DG2 Browser Spike' but found '$($report.finalTitle)'"
}
if ($report.finalURL -notmatch '^data:text/html,') {
    throw "Expected finalURL to use the data: scheme but found '$($report.finalURL)'"
}

Write-Host "WebView2 spike passed"
Write-Host $reportPath
