param(
    [string]$ArtifactDirectory = $(Join-Path $env:TEMP ("cmux-shell-host-crash-retention-" + [guid]::NewGuid().Guid)),
    [int]$CycleCount = 3,
    [string]$OutputPath = '',
    [string]$SliceExecutablePath = ''
)

$ErrorActionPreference = 'Stop'

if ($CycleCount -lt 2) {
    throw "Expected CycleCount >= 2 but found $CycleCount"
}

$artifactPath = New-Item -ItemType Directory -Force -Path $ArtifactDirectory
$reportPath = Join-Path $artifactPath.FullName 'shell-host-crash-retention-report.json'
Remove-Item -Force $reportPath -ErrorAction SilentlyContinue

$cycles = @()
for ($index = 1; $index -le $CycleCount; $index++) {
    $cycleDirectory = Join-Path $artifactPath.FullName ("cycle-" + $index)
    Remove-Item -Recurse -Force $cycleDirectory -ErrorAction SilentlyContinue

    & (Join-Path $PSScriptRoot 'test-windows-shell-host-crash-recovery.ps1') `
        -ArtifactDirectory $cycleDirectory `
        -OutputPath $OutputPath `
        -SliceExecutablePath $SliceExecutablePath | Out-Null

    $cycleReportPath = Join-Path $cycleDirectory 'shell-host-crash-recovery-report.json'
    $restoreReportPath = Join-Path $cycleDirectory 'restore-smoke-report.json'
    $restoreRunDir = Join-Path $cycleDirectory 'restore-run'
    $crashRunDir = Join-Path $cycleDirectory 'crash-run'
    $restoreArtifactManifestPath = Join-Path $restoreRunDir 'captured-artifacts.json'
    $crashActionLogPath = Join-Path $crashRunDir 'shell-host-actions.log'
    $crashFocusLogPath = Join-Path $crashRunDir 'shell-host-focus.log'
    $crashBrowserReadyPath = Join-Path $crashRunDir 'shell-host-browser-ready.txt'

    foreach ($path in @(
        $cycleReportPath,
        $restoreReportPath,
        $restoreArtifactManifestPath,
        $crashActionLogPath,
        $crashFocusLogPath,
        $crashBrowserReadyPath
    )) {
        if (-not (Test-Path $path)) {
            throw "Expected retained cycle artifact at $path"
        }
    }

    $cycleReport = Get-Content $cycleReportPath -Raw | ConvertFrom-Json
    $restoreReport = Get-Content $restoreReportPath -Raw | ConvertFrom-Json
    $restoreArtifactManifest = Get-Content $restoreArtifactManifestPath -Raw | ConvertFrom-Json

    $copiedRuntimeRecords = @($restoreArtifactManifest.records | Where-Object { $_.copied })
    if (-not $cycleReport.processAliveDuringKill) {
        throw "Expected cycle $index to kill the slice while alive"
    }
    if (-not $cycleReport.snapshotRoundTripMatches) {
        throw "Expected cycle $index snapshotRoundTripMatches=true"
    }
    if (-not $restoreReport.shellHostReports[0].success) {
        throw "Expected cycle $index restored shell host success=true"
    }
    if ($copiedRuntimeRecords.Count -lt 4) {
        throw "Expected cycle $index to retain at least 4 copied runtime artifacts but found $($copiedRuntimeRecords.Count)"
    }

    $cycles += [pscustomobject]@{
        cycle = $index
        cycleDirectory = $cycleDirectory
        processAliveDuringKill = [bool]$cycleReport.processAliveDuringKill
        snapshotRoundTripMatches = [bool]$cycleReport.snapshotRoundTripMatches
        restoreShellHostSuccess = [bool]($restoreReport.shellHostReports[0].success)
        restoreCapturedArtifactCount = @($restoreArtifactManifest.records).Count
        restoreCopiedArtifactCount = $copiedRuntimeRecords.Count
        crashActionLogPath = $crashActionLogPath
        crashFocusLogPath = $crashFocusLogPath
        crashBrowserReadyPath = $crashBrowserReadyPath
    }
}

$workspaceTitles = @($cycles | ForEach-Object { 'Crash Recovery Workspace' } | Select-Object -Unique)
$copiedArtifactCounts = @($cycles | ForEach-Object { [int]$_.restoreCopiedArtifactCount })

$report = [ordered]@{
    cycleCount = $CycleCount
    minCopiedArtifactCount = ($copiedArtifactCounts | Measure-Object -Minimum).Minimum
    maxCopiedArtifactCount = ($copiedArtifactCounts | Measure-Object -Maximum).Maximum
    allWorkspaceTitlesConsistent = ($workspaceTitles.Count -eq 1)
    cycles = $cycles
}

$report | ConvertTo-Json -Depth 8 | Set-Content -Path $reportPath -Encoding utf8

Write-Host 'Shell host crash retention spike passed'
Write-Host $reportPath
