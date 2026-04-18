param(
    [string]$ArtifactDirectory = $(Join-Path $env:TEMP ("cmux-shell-host-session-restore-" + [guid]::NewGuid().Guid)),
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'

$artifactPath = New-Item -ItemType Directory -Force -Path $ArtifactDirectory
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$initialSequencePath = Join-Path $artifactPath.FullName 'initial-sequence.json'
$restoreSequencePath = Join-Path $artifactPath.FullName 'restore-sequence.json'
$initialReportPath = Join-Path $artifactPath.FullName 'initial-smoke-report.json'
$restoreReportPath = Join-Path $artifactPath.FullName 'restore-smoke-report.json'
$initialArtifactDir = Join-Path $artifactPath.FullName 'initial-run'
$restoreArtifactDir = Join-Path $artifactPath.FullName 'restore-run'
$initialSnapshotPath = Join-Path $artifactPath.FullName 'session-snapshot-initial.json'
$restoredSnapshotPath = Join-Path $artifactPath.FullName 'session-snapshot-restored.json'
$reportPath = Join-Path $artifactPath.FullName 'shell-host-session-restore-report.json'
$sliceOutputPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    Join-Path $artifactPath.FullName 'cmux_windows_slice_restore.exe'
} else {
    $OutputPath
}

$initialSequence = @(
    @{ command = 'set-workspace-title'; value = 'North Star Workspace' }
    @{ command = 'set-workspace-directory'; value = $repoRoot }
    @{ command = 'set-workspace-pinned'; value = 'true' }
    @{ command = 'add-terminal-panel'; title = 'Primary Terminal' }
    @{ command = 'split-browser-horizontal'; title = 'Docs Browser'; value = 'data:text/html,<html><head><title>Docs Browser</title></head><body>docs-browser</body></html>' }
    @{ command = 'open-shell-host' }
) | ConvertTo-Json -Depth 4

$restoreSequence = @(
    @{ command = 'open-shell-host' }
    @{ command = 'focus-panel'; title = 'Docs Browser' }
) | ConvertTo-Json -Depth 4

Set-Content -Path $initialSequencePath -Value $initialSequence -Encoding utf8
Set-Content -Path $restoreSequencePath -Value $restoreSequence -Encoding utf8

& (Join-Path $PSScriptRoot 'build-windows-slice.ps1') -OutputPath $sliceOutputPath | Out-Null

$helperDirectory = Split-Path -Parent $sliceOutputPath
$browserHelperPath = Join-Path $helperDirectory 'cmux_windows_webview2_spike.exe'
$browserChildHelperPath = Join-Path $helperDirectory 'cmux_windows_webview2_child_host.exe'
$shellHostHelperPath = Join-Path $helperDirectory 'cmux_windows_shell_host_spike.exe'

$previousCommandSequencePath = $env:CMUX_WINDOWS_COMMAND_SEQUENCE_PATH
$previousSmokeOutputPath = $env:CMUX_SMOKE_OUTPUT_PATH
$previousSmokeArtifactDir = $env:CMUX_SMOKE_ARTIFACT_DIR
$previousSnapshotOutputPath = $env:CMUX_WINDOWS_SESSION_SNAPSHOT_OUTPUT_PATH
$previousRestoreSnapshotPath = $env:CMUX_WINDOWS_RESTORE_SESSION_SNAPSHOT_PATH
$previousBrowserHelper = $env:CMUX_WINDOWS_BROWSER_HELPER_EXE
$previousBrowserChildHelper = $env:CMUX_WINDOWS_BROWSER_CHILD_HELPER_EXE
$previousShellHostHelper = $env:CMUX_WINDOWS_SHELL_HOST_HELPER_EXE

function Test-JsonEquivalent {
    param(
        $Left,
        $Right
    )

    if ($null -eq $Left -and $null -eq $Right) { return $true }
    if ($null -eq $Left -or $null -eq $Right) { return $false }

    if ($Left -is [System.Collections.IDictionary] -or $Left -is [pscustomobject]) {
        $leftProperties = @($Left.PSObject.Properties.Name | Sort-Object)
        $rightProperties = @($Right.PSObject.Properties.Name | Sort-Object)
        if ($leftProperties.Count -ne $rightProperties.Count) { return $false }
        for ($index = 0; $index -lt $leftProperties.Count; $index++) {
            if ($leftProperties[$index] -ne $rightProperties[$index]) { return $false }
            if (-not (Test-JsonEquivalent $Left.($leftProperties[$index]) $Right.($rightProperties[$index]))) {
                return $false
            }
        }
        return $true
    }

    if (($Left -is [System.Collections.IEnumerable] -and -not ($Left -is [string])) -or
        ($Right -is [System.Collections.IEnumerable] -and -not ($Right -is [string]))) {
        $leftArray = @($Left)
        $rightArray = @($Right)
        if ($leftArray.Count -ne $rightArray.Count) { return $false }
        for ($index = 0; $index -lt $leftArray.Count; $index++) {
            if (-not (Test-JsonEquivalent $leftArray[$index] $rightArray[$index])) {
                return $false
            }
        }
        return $true
    }

    return [string]$Left -eq [string]$Right
}

try {
    $env:CMUX_WINDOWS_BROWSER_HELPER_EXE = $browserHelperPath
    $env:CMUX_WINDOWS_BROWSER_CHILD_HELPER_EXE = $browserChildHelperPath
    $env:CMUX_WINDOWS_SHELL_HOST_HELPER_EXE = $shellHostHelperPath

    $env:CMUX_WINDOWS_COMMAND_SEQUENCE_PATH = $initialSequencePath
    $env:CMUX_SMOKE_OUTPUT_PATH = $initialReportPath
    $env:CMUX_SMOKE_ARTIFACT_DIR = $initialArtifactDir
    $env:CMUX_WINDOWS_SESSION_SNAPSHOT_OUTPUT_PATH = $initialSnapshotPath
    Remove-Item Env:CMUX_WINDOWS_RESTORE_SESSION_SNAPSHOT_PATH -ErrorAction SilentlyContinue
    & $sliceOutputPath | Out-Null

    $env:CMUX_WINDOWS_COMMAND_SEQUENCE_PATH = $restoreSequencePath
    $env:CMUX_SMOKE_OUTPUT_PATH = $restoreReportPath
    $env:CMUX_SMOKE_ARTIFACT_DIR = $restoreArtifactDir
    $env:CMUX_WINDOWS_SESSION_SNAPSHOT_OUTPUT_PATH = $restoredSnapshotPath
    $env:CMUX_WINDOWS_RESTORE_SESSION_SNAPSHOT_PATH = $initialSnapshotPath
    & $sliceOutputPath | Out-Null
}
finally {
    $env:CMUX_WINDOWS_COMMAND_SEQUENCE_PATH = $previousCommandSequencePath
    $env:CMUX_SMOKE_OUTPUT_PATH = $previousSmokeOutputPath
    $env:CMUX_SMOKE_ARTIFACT_DIR = $previousSmokeArtifactDir
    $env:CMUX_WINDOWS_SESSION_SNAPSHOT_OUTPUT_PATH = $previousSnapshotOutputPath
    $env:CMUX_WINDOWS_RESTORE_SESSION_SNAPSHOT_PATH = $previousRestoreSnapshotPath
    $env:CMUX_WINDOWS_BROWSER_HELPER_EXE = $previousBrowserHelper
    $env:CMUX_WINDOWS_BROWSER_CHILD_HELPER_EXE = $previousBrowserChildHelper
    $env:CMUX_WINDOWS_SHELL_HOST_HELPER_EXE = $previousShellHostHelper
}

foreach ($path in @($initialReportPath, $restoreReportPath, $initialSnapshotPath, $restoredSnapshotPath)) {
    if (-not (Test-Path $path)) {
        throw "Expected artifact at $path"
    }
}

$initialReport = Get-Content $initialReportPath -Raw | ConvertFrom-Json
$restoreReport = Get-Content $restoreReportPath -Raw | ConvertFrom-Json
$initialSnapshotRaw = Get-Content $initialSnapshotPath -Raw
$restoredSnapshotRaw = Get-Content $restoredSnapshotPath -Raw
$initialSnapshot = $initialSnapshotRaw | ConvertFrom-Json
$restoredSnapshot = $restoredSnapshotRaw | ConvertFrom-Json
$snapshotSemanticMatch = Test-JsonEquivalent $initialSnapshot $restoredSnapshot

$report = [ordered]@{
    initialSelectedWorkspaceTitle = [string]$initialReport.selectedWorkspaceTitle
    restoreSelectedWorkspaceTitle = [string]$restoreReport.selectedWorkspaceTitle
    initialLayoutSummary = [string]$initialReport.selectedWorkspaceLayoutSummary
    restoreLayoutSummary = [string]$restoreReport.selectedWorkspaceLayoutSummary
    initialPanelCount = [int]$initialReport.selectedWorkspacePanelCount
    restorePanelCount = [int]$restoreReport.selectedWorkspacePanelCount
    initialFocusedPanelTitle = [string]$initialReport.selectedWorkspaceFocusedPanelTitle
    restoreFocusedPanelTitle = [string]$restoreReport.selectedWorkspaceFocusedPanelTitle
    initialRoundTrip = [bool]$initialReport.sessionRoundTripMatches
    restoreRoundTrip = [bool]$restoreReport.sessionRoundTripMatches
    initialShellHostSuccess = [bool]($initialReport.shellHostReports[0].success)
    restoreShellHostSuccess = [bool]($restoreReport.shellHostReports[0].success)
    snapshotRoundTripMatches = $snapshotSemanticMatch
    initialSnapshotPath = $initialSnapshotPath
    restoredSnapshotPath = $restoredSnapshotPath
    initialReportPath = $initialReportPath
    restoreReportPath = $restoreReportPath
}
$report | ConvertTo-Json -Depth 6 | Set-Content -Path $reportPath -Encoding utf8

if (-not $initialReport.sessionRoundTripMatches) {
    throw 'Expected initial mixed-host run to preserve sessionRoundTripMatches=true'
}
if (-not $restoreReport.sessionRoundTripMatches) {
    throw 'Expected restored mixed-host run to preserve sessionRoundTripMatches=true'
}
if (-not $initialReport.shellHostReports[0].success) {
    throw 'Expected initial mixed-host shell host report success=true'
}
if (-not $restoreReport.shellHostReports[0].success) {
    throw 'Expected restored mixed-host shell host report success=true'
}
if ($initialReport.selectedWorkspaceTitle -ne $restoreReport.selectedWorkspaceTitle) {
    throw "Expected restored workspace title '$($initialReport.selectedWorkspaceTitle)' but found '$($restoreReport.selectedWorkspaceTitle)'"
}
if ($initialReport.selectedWorkspaceLayoutSummary -ne $restoreReport.selectedWorkspaceLayoutSummary) {
    throw 'Expected restored layout summary to match initial layout summary'
}
if ([int]$initialReport.selectedWorkspacePanelCount -ne [int]$restoreReport.selectedWorkspacePanelCount) {
    throw 'Expected restored panel count to match initial panel count'
}
if (-not $snapshotSemanticMatch) {
    throw 'Expected restored workspace snapshot to match the initial snapshot semantically'
}

Write-Host 'Shell host session restore spike passed'
Write-Host $reportPath
