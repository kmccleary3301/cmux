param(
    [string]$ArtifactDirectory = $(Join-Path $env:TEMP ("cmux-shell-host-crash-recovery-" + [guid]::NewGuid().Guid)),
    [string]$OutputPath = '',
    [string]$SliceExecutablePath = ''
)

$ErrorActionPreference = 'Stop'

$artifactPath = New-Item -ItemType Directory -Force -Path $ArtifactDirectory
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$initialSequencePath = Join-Path $artifactPath.FullName 'crash-sequence.json'
$restoreSequencePath = Join-Path $artifactPath.FullName 'restore-sequence.json'
$restoreReportPath = Join-Path $artifactPath.FullName 'restore-smoke-report.json'
$crashArtifactDir = Join-Path $artifactPath.FullName 'crash-run'
$restoreArtifactDir = Join-Path $artifactPath.FullName 'restore-run'
$autosaveSnapshotPath = Join-Path $artifactPath.FullName 'session-snapshot-autosave.json'
$restoredSnapshotPath = Join-Path $artifactPath.FullName 'session-snapshot-restored.json'
$reportPath = Join-Path $artifactPath.FullName 'shell-host-crash-recovery-report.json'
$sliceOutputPath = $null
if (-not [string]::IsNullOrWhiteSpace($SliceExecutablePath)) {
    $resolvedSliceExecutable = Resolve-Path $SliceExecutablePath -ErrorAction Stop
    $sliceOutputPath = $resolvedSliceExecutable.Path
} elseif ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $sliceOutputPath = Join-Path $artifactPath.FullName 'cmux_windows_slice_crash.exe'
} else {
    $sliceOutputPath = $OutputPath
}

foreach ($path in @(
    $initialSequencePath,
    $restoreSequencePath,
    $restoreReportPath,
    $autosaveSnapshotPath,
    $restoredSnapshotPath,
    $reportPath
)) {
    Remove-Item -Force $path -ErrorAction SilentlyContinue
}
Remove-Item -Recurse -Force $crashArtifactDir -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $restoreArtifactDir -ErrorAction SilentlyContinue

$initialSequence = @(
    @{ command = 'set-workspace-title'; value = 'Crash Recovery Workspace' }
    @{ command = 'set-workspace-directory'; value = $repoRoot }
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

if ([string]::IsNullOrWhiteSpace($SliceExecutablePath)) {
    & (Join-Path $PSScriptRoot 'build-windows-slice.ps1') -OutputPath $sliceOutputPath | Out-Null
}

$helperDirectory = Split-Path -Parent $sliceOutputPath
$browserHelperPath = Join-Path $helperDirectory 'cmux_windows_webview2_spike.exe'
$browserChildHelperPath = Join-Path $helperDirectory 'cmux_windows_webview2_child_host.exe'
$shellHostHelperPath = Join-Path $helperDirectory 'cmux_windows_shell_host_spike.exe'

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

function Stop-ProcessesByPath {
    param(
        [string]$ExecutablePath,
        [datetime]$NotBefore
    )

    if ([string]::IsNullOrWhiteSpace($ExecutablePath) -or -not (Test-Path $ExecutablePath)) {
        return
    }

    foreach ($process in Get-Process -ErrorAction SilentlyContinue) {
        try {
            if ($process.Path -eq $ExecutablePath -and $process.StartTime -ge $NotBefore) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            }
        } catch {
        }
    }
}

function Get-FileTailSummary {
    param(
        [string]$Path,
        [int]$MaxLines = 12
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return @()
    }

    return @(Get-Content $Path -Tail $MaxLines | ForEach-Object { [string]$_ })
}

$processStart = Get-Date
$processInfo = New-Object System.Diagnostics.ProcessStartInfo
$processInfo.FileName = $sliceOutputPath
$processInfo.UseShellExecute = $false
$processInfo.CreateNoWindow = $true
$processInfo.WorkingDirectory = $repoRoot
$processInfo.Environment['CMUX_WINDOWS_COMMAND_SEQUENCE_PATH'] = $initialSequencePath
$processInfo.Environment['CMUX_SMOKE_ARTIFACT_DIR'] = $crashArtifactDir
$processInfo.Environment['CMUX_WINDOWS_SESSION_SNAPSHOT_OUTPUT_PATH'] = $autosaveSnapshotPath
$processInfo.Environment['CMUX_WINDOWS_SHELL_HOST_HOLD_OPEN_MS'] = '20000'
$processInfo.Environment['CMUX_WINDOWS_BROWSER_HELPER_EXE'] = $browserHelperPath
$processInfo.Environment['CMUX_WINDOWS_BROWSER_CHILD_HELPER_EXE'] = $browserChildHelperPath
$processInfo.Environment['CMUX_WINDOWS_SHELL_HOST_HELPER_EXE'] = $shellHostHelperPath
$processInfo.Environment['CMUX_REPO_ROOT'] = $repoRoot

$sliceProcess = New-Object System.Diagnostics.Process
$sliceProcess.StartInfo = $processInfo

if (-not $sliceProcess.Start()) {
    throw 'Failed to start slice process for crash recovery proof'
}

$autosaveSeenBeforeKill = $false
$processAliveDuringKill = $false
$autosaveSnapshot = $null
$shellHostStartedBeforeKill = $false
$autosaveWaitDeadline = (Get-Date).AddSeconds(25)
$crashActionLogPath = Join-Path $crashArtifactDir 'shell-host-actions.log'
$crashFocusLogPath = Join-Path $crashArtifactDir 'shell-host-focus.log'
$crashBrowserReadyPath = Join-Path $crashArtifactDir 'shell-host-browser-ready.txt'
$crashBrowserReportPath = Join-Path $crashArtifactDir 'shell-host-browser-report.json'

try {
    while ((Get-Date) -lt $autosaveWaitDeadline) {
        if (Test-Path $autosaveSnapshotPath) {
            try {
                $autosaveSnapshot = Get-Content $autosaveSnapshotPath -Raw | ConvertFrom-Json
                if (@($autosaveSnapshot.panels).Count -ge 2 -and
                    [string]$autosaveSnapshot.focusedPanelId) {
                    $autosaveSeenBeforeKill = $true
                    break
                }
            } catch {
            }
        }
        if ($sliceProcess.HasExited) {
            throw "Slice process exited before autosave checkpoint was ready. ExitCode=$($sliceProcess.ExitCode)"
        }
        Start-Sleep -Milliseconds 200
    }

    if (-not $autosaveSeenBeforeKill) {
        throw "Autosave snapshot was not materialized before timeout at $autosaveSnapshotPath"
    }

    $shellHostWaitDeadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $shellHostWaitDeadline) {
        if ((Test-Path $crashActionLogPath) -and ((Test-Path $crashBrowserReadyPath) -or (Test-Path $crashBrowserReportPath))) {
            $shellHostStartedBeforeKill = $true
            break
        }
        if ($sliceProcess.HasExited) {
            throw "Slice process exited before shell-host evidence was materialized. ExitCode=$($sliceProcess.ExitCode)"
        }
        Start-Sleep -Milliseconds 200
    }

    if (-not $shellHostStartedBeforeKill) {
        throw "Shell-host evidence was not materialized before timeout under $crashArtifactDir"
    }

    Start-Sleep -Milliseconds 800
    $processAliveDuringKill = -not $sliceProcess.HasExited
    if (-not $processAliveDuringKill) {
        throw 'Slice process exited before forced termination could be applied'
    }

    Stop-Process -Id $sliceProcess.Id -Force
    $sliceProcess.WaitForExit()
}
finally {
    Stop-ProcessesByPath -ExecutablePath $shellHostHelperPath -NotBefore $processStart
    Stop-ProcessesByPath -ExecutablePath $browserChildHelperPath -NotBefore $processStart
}

if (-not (Test-Path $autosaveSnapshotPath)) {
    throw "Expected autosave snapshot at $autosaveSnapshotPath"
}

$restoreProcessInfo = New-Object System.Diagnostics.ProcessStartInfo
$restoreProcessInfo.FileName = $sliceOutputPath
$restoreProcessInfo.UseShellExecute = $false
$restoreProcessInfo.CreateNoWindow = $true
$restoreProcessInfo.WorkingDirectory = $repoRoot
$restoreProcessInfo.Environment['CMUX_WINDOWS_COMMAND_SEQUENCE_PATH'] = $restoreSequencePath
$restoreProcessInfo.Environment['CMUX_WINDOWS_RESTORE_SESSION_SNAPSHOT_PATH'] = $autosaveSnapshotPath
$restoreProcessInfo.Environment['CMUX_WINDOWS_SESSION_SNAPSHOT_OUTPUT_PATH'] = $restoredSnapshotPath
$restoreProcessInfo.Environment['CMUX_SMOKE_OUTPUT_PATH'] = $restoreReportPath
$restoreProcessInfo.Environment['CMUX_SMOKE_ARTIFACT_DIR'] = $restoreArtifactDir
$restoreProcessInfo.Environment['CMUX_WINDOWS_SHELL_HOST_HOLD_OPEN_MS'] = '0'
$restoreProcessInfo.Environment['CMUX_WINDOWS_BROWSER_HELPER_EXE'] = $browserHelperPath
$restoreProcessInfo.Environment['CMUX_WINDOWS_BROWSER_CHILD_HELPER_EXE'] = $browserChildHelperPath
$restoreProcessInfo.Environment['CMUX_WINDOWS_SHELL_HOST_HELPER_EXE'] = $shellHostHelperPath
$restoreProcessInfo.Environment['CMUX_REPO_ROOT'] = $repoRoot

$restoreProcess = New-Object System.Diagnostics.Process
$restoreProcess.StartInfo = $restoreProcessInfo
if (-not $restoreProcess.Start()) {
    throw 'Failed to start restore process for crash recovery proof'
}
$restoreProcess.WaitForExit()
if ($restoreProcess.ExitCode -ne 0) {
    throw "Restore process exited with code $($restoreProcess.ExitCode)"
}

foreach ($path in @($restoreReportPath, $autosaveSnapshotPath, $restoredSnapshotPath)) {
    if (-not (Test-Path $path)) {
        throw "Expected artifact at $path"
    }
}

$restoreArtifactManifestPath = Join-Path $restoreArtifactDir 'captured-artifacts.json'

foreach ($path in @(
    $crashFocusLogPath,
    $crashActionLogPath,
    $crashBrowserReportPath,
    $restoreArtifactManifestPath
)) {
    if (-not (Test-Path $path)) {
        throw "Expected retained artifact at $path"
    }
}

$restoreReport = Get-Content $restoreReportPath -Raw | ConvertFrom-Json
$autosaveSnapshotRaw = Get-Content $autosaveSnapshotPath -Raw
$restoredSnapshotRaw = Get-Content $restoredSnapshotPath -Raw
$autosaveSnapshot = $autosaveSnapshotRaw | ConvertFrom-Json
$restoredSnapshot = $restoredSnapshotRaw | ConvertFrom-Json
$restoreArtifactManifest = Get-Content $restoreArtifactManifestPath -Raw | ConvertFrom-Json
$snapshotSemanticMatch = Test-JsonEquivalent $autosaveSnapshot $restoredSnapshot
$capturedArtifactCount = @($restoreArtifactManifest.records).Count
$copiedArtifactCount = @($restoreArtifactManifest.records | Where-Object { $_.copied }).Count
$copiedArtifactRecords = @($restoreArtifactManifest.records | Where-Object { $_.copied })
$missingArtifactRecords = @($restoreArtifactManifest.records | Where-Object { -not $_.exists })
$restoreTranscriptRecord = @($copiedArtifactRecords | Where-Object { $_.category -eq 'shell-host-transcript' } | Select-Object -First 1)[0]
$restoreActionLogRecord = @($copiedArtifactRecords | Where-Object { $_.category -eq 'shell-host-action-log' } | Select-Object -First 1)[0]
$restoreFocusLogRecord = @($copiedArtifactRecords | Where-Object { $_.category -eq 'shell-host-focus-log' } | Select-Object -First 1)[0]
$restoreTranscriptPath = if ($null -ne $restoreTranscriptRecord) { Join-Path $restoreArtifactDir $restoreTranscriptRecord.relativePath } else { $null }
$restoreActionLogPath = if ($null -ne $restoreActionLogRecord) { Join-Path $restoreArtifactDir $restoreActionLogRecord.relativePath } else { $null }
$restoreFocusLogPath = if ($null -ne $restoreFocusLogRecord) { Join-Path $restoreArtifactDir $restoreFocusLogRecord.relativePath } else { $null }
$restoreShellHostReport = @($restoreReport.shellHostReports | Select-Object -First 1)[0]

$report = [ordered]@{
    autosaveSeenBeforeKill = $autosaveSeenBeforeKill
    shellHostStartedBeforeKill = $shellHostStartedBeforeKill
    processAliveDuringKill = $processAliveDuringKill
    killExitCode = [int]$sliceProcess.ExitCode
    autosaveWorkspaceTitle = [string]$autosaveSnapshot.customTitle
    autosavePanelCount = @($autosaveSnapshot.panels).Count
    autosaveFocusedPanelId = [string]$autosaveSnapshot.focusedPanelId
    restoreSelectedWorkspaceTitle = [string]$restoreReport.selectedWorkspaceTitle
    restorePanelCount = [int]$restoreReport.selectedWorkspacePanelCount
    restoreFocusedPanelTitle = [string]$restoreReport.selectedWorkspaceFocusedPanelTitle
    restoreRoundTrip = [bool]$restoreReport.sessionRoundTripMatches
    restoreShellHostSuccess = ($null -ne $restoreShellHostReport) -and [bool]$restoreShellHostReport.success
    restoreShellHostBrowserStatus = if ($null -ne $restoreShellHostReport) { [string]$restoreShellHostReport.browserStatus } else { '' }
    restoreShellHostDurationMs = if ($null -ne $restoreShellHostReport) { [int]$restoreShellHostReport.durationMs } else { 0 }
    restoreTranscriptPreview = if ($null -ne $restoreShellHostReport) { [string]$restoreShellHostReport.transcriptPreview } else { '' }
    snapshotRoundTripMatches = $snapshotSemanticMatch
    crashFocusLogRetained = (Test-Path $crashFocusLogPath)
    crashActionLogRetained = (Test-Path $crashActionLogPath)
    crashBrowserReadyRetained = (Test-Path $crashBrowserReadyPath)
    crashBrowserReportRetained = (Test-Path $crashBrowserReportPath)
    restoreCapturedArtifactCount = $capturedArtifactCount
    restoreCopiedArtifactCount = $copiedArtifactCount
    retainedArtifactCategories = @($copiedArtifactRecords | ForEach-Object { [string]$_.category })
    retainedArtifactRelativePaths = @($copiedArtifactRecords | ForEach-Object { [string]$_.relativePath })
    missingArtifactCategories = @($missingArtifactRecords | ForEach-Object { [string]$_.category })
    crashActionTail = Get-FileTailSummary -Path $crashActionLogPath
    crashFocusTail = Get-FileTailSummary -Path $crashFocusLogPath
    restoreActionTail = Get-FileTailSummary -Path $restoreActionLogPath
    restoreFocusTail = Get-FileTailSummary -Path $restoreFocusLogPath
    restoreTranscriptTail = Get-FileTailSummary -Path $restoreTranscriptPath
    autosaveSnapshotPath = $autosaveSnapshotPath
    restoredSnapshotPath = $restoredSnapshotPath
    restoreReportPath = $restoreReportPath
    restoreArtifactManifestPath = $restoreArtifactManifestPath
}
$report | ConvertTo-Json -Depth 6 | Set-Content -Path $reportPath -Encoding utf8

if (-not $autosaveSeenBeforeKill) {
    throw 'Expected autosave checkpoint before forced termination'
}
if (-not $processAliveDuringKill) {
    throw 'Expected slice process to still be alive when forced termination was applied'
}
if (-not $shellHostStartedBeforeKill) {
    throw 'Expected shell-host evidence to exist before forced termination'
}
if (@($autosaveSnapshot.panels).Count -lt 2) {
    throw 'Expected autosave snapshot to preserve the mixed terminal/browser workspace before kill'
}
if (-not $restoreReport.sessionRoundTripMatches) {
    throw 'Expected restored mixed-host run to preserve sessionRoundTripMatches=true'
}
if ($null -eq $restoreShellHostReport -or -not [bool]$restoreShellHostReport.success) {
    throw 'Expected restored mixed-host shell host report success=true'
}
if ($restoreReport.selectedWorkspaceTitle -ne 'Crash Recovery Workspace') {
    throw "Expected restored workspace title 'Crash Recovery Workspace' but found '$($restoreReport.selectedWorkspaceTitle)'"
}
if ([int]$restoreReport.selectedWorkspacePanelCount -ne 2) {
    throw "Expected restored panel count 2 but found $($restoreReport.selectedWorkspacePanelCount)"
}
if (-not $snapshotSemanticMatch) {
    throw 'Expected restored workspace snapshot to match the crash autosave snapshot semantically'
}
if ($copiedArtifactCount -lt 4) {
    throw "Expected restore artifact manifest to retain at least 4 copied runtime artifacts but found $copiedArtifactCount"
}

Write-Host 'Shell host crash recovery spike passed'
Write-Host $reportPath
