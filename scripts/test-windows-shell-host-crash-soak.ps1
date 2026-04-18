param(
    [string]$ArtifactDirectory = $(Join-Path $env:TEMP ("cmux-shell-host-crash-soak-" + [guid]::NewGuid().Guid)),
    [int]$CycleCount = 5,
    [string]$OutputPath = '',
    [string]$SliceExecutablePath = ''
)

$ErrorActionPreference = 'Stop'

if ($CycleCount -lt 3) {
    throw "Expected CycleCount >= 3 but found $CycleCount"
}

$artifactPath = New-Item -ItemType Directory -Force -Path $ArtifactDirectory
$reportPath = Join-Path $artifactPath.FullName 'shell-host-crash-soak-report.json'
Remove-Item -Force $reportPath -ErrorAction SilentlyContinue

$resolvedSliceExecutablePath = $null
if (-not [string]::IsNullOrWhiteSpace($SliceExecutablePath)) {
    $resolvedSliceExecutablePath = (Resolve-Path $SliceExecutablePath -ErrorAction Stop).Path
} else {
    $sharedSliceOutputPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        Join-Path $artifactPath.FullName 'cmux_windows_slice_crash_soak.exe'
    } else {
        $OutputPath
    }
    & (Join-Path $PSScriptRoot 'build-windows-slice.ps1') -OutputPath $sharedSliceOutputPath | Out-Null
    $resolvedSliceExecutablePath = (Resolve-Path $sharedSliceOutputPath -ErrorAction Stop).Path
}

$requiredRetainedCategories = @(
    'shell-host-transcript',
    'shell-host-action-log',
    'shell-host-focus-log',
    'shell-host-helper-report'
)

$cycles = @()
for ($index = 1; $index -le $CycleCount; $index++) {
    $cycleDirectory = Join-Path $artifactPath.FullName ("cycle-" + $index)
    Remove-Item -Recurse -Force $cycleDirectory -ErrorAction SilentlyContinue

    & (Join-Path $PSScriptRoot 'test-windows-shell-host-crash-recovery.ps1') `
        -ArtifactDirectory $cycleDirectory `
        -SliceExecutablePath $resolvedSliceExecutablePath | Out-Null

    $cycleReportPath = Join-Path $cycleDirectory 'shell-host-crash-recovery-report.json'
    if (-not (Test-Path $cycleReportPath)) {
        throw "Expected cycle report at $cycleReportPath"
    }

    $cycleReport = Get-Content $cycleReportPath -Raw | ConvertFrom-Json
    $retainedCategories = @($cycleReport.retainedArtifactCategories | ForEach-Object { [string]$_ })
    $missingRequiredCategories = @($requiredRetainedCategories | Where-Object { $_ -notin $retainedCategories })

    if (-not $cycleReport.processAliveDuringKill) {
        throw "Expected cycle $index processAliveDuringKill=true"
    }
    if (-not $cycleReport.snapshotRoundTripMatches) {
        throw "Expected cycle $index snapshotRoundTripMatches=true"
    }
    if (-not $cycleReport.restoreShellHostSuccess) {
        throw "Expected cycle $index restoreShellHostSuccess=true"
    }
    if ($missingRequiredCategories.Count -gt 0) {
        throw "Expected cycle $index to retain required artifact categories. Missing: $($missingRequiredCategories -join ', ')"
    }

    $cycles += [pscustomobject]@{
        cycle = $index
        cycleDirectory = $cycleDirectory
        processAliveDuringKill = [bool]$cycleReport.processAliveDuringKill
        snapshotRoundTripMatches = [bool]$cycleReport.snapshotRoundTripMatches
        restoreShellHostSuccess = [bool]$cycleReport.restoreShellHostSuccess
        restoreShellHostDurationMs = [int]$cycleReport.restoreShellHostDurationMs
        restoreCopiedArtifactCount = [int]$cycleReport.restoreCopiedArtifactCount
        autosaveWorkspaceTitle = [string]$cycleReport.autosaveWorkspaceTitle
        restoreFocusedPanelTitle = [string]$cycleReport.restoreFocusedPanelTitle
        retainedArtifactCategories = $retainedCategories
        missingRequiredRetainedCategories = $missingRequiredCategories
        crashActionTail = @($cycleReport.crashActionTail)
        crashFocusTail = @($cycleReport.crashFocusTail)
        restoreActionTail = @($cycleReport.restoreActionTail)
        restoreFocusTail = @($cycleReport.restoreFocusTail)
        restoreTranscriptTail = @($cycleReport.restoreTranscriptTail)
    }
}

$durationValues = @($cycles | ForEach-Object { [int]$_.restoreShellHostDurationMs })
$copiedArtifactCounts = @($cycles | ForEach-Object { [int]$_.restoreCopiedArtifactCount })
$workspaceTitles = @($cycles | ForEach-Object { [string]$_.autosaveWorkspaceTitle } | Select-Object -Unique)
$focusedTitles = @($cycles | ForEach-Object { [string]$_.restoreFocusedPanelTitle } | Select-Object -Unique)
$allRetainedCategories = @($cycles | ForEach-Object { @($_.retainedArtifactCategories) } | ForEach-Object { $_ } | Select-Object -Unique)
$allMissingRequiredCategories = @($cycles | ForEach-Object { @($_.missingRequiredRetainedCategories) } | ForEach-Object { $_ } | Select-Object -Unique)

$report = [ordered]@{
    cycleCount = $CycleCount
    allWorkspaceTitlesConsistent = ($workspaceTitles.Count -eq 1)
    allFocusedPanelTitlesConsistent = ($focusedTitles.Count -eq 1)
    minRestoreShellHostDurationMs = ($durationValues | Measure-Object -Minimum).Minimum
    maxRestoreShellHostDurationMs = ($durationValues | Measure-Object -Maximum).Maximum
    minCopiedArtifactCount = ($copiedArtifactCounts | Measure-Object -Minimum).Minimum
    maxCopiedArtifactCount = ($copiedArtifactCounts | Measure-Object -Maximum).Maximum
    allRequiredRetainedCategoriesPresent = ($allMissingRequiredCategories.Count -eq 0)
    retainedArtifactCategories = $allRetainedCategories
    missingRequiredRetainedCategories = $allMissingRequiredCategories
    cycles = $cycles
}

$report | ConvertTo-Json -Depth 10 | Set-Content -Path $reportPath -Encoding utf8

Write-Host 'Shell host crash soak spike passed'
Write-Host $reportPath
