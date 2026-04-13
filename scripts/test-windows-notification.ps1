param(
    [string]$SmokeOutputPath = $(Join-Path $env:TEMP 'cmux-windows-notification-report.json'),
    [string]$ArtifactDirectory = $(Join-Path $env:TEMP 'cmux-windows-notification-artifacts'),
    [string]$SliceExecutablePath = ''
)

$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Force -Path $ArtifactDirectory | Out-Null

$sliceExecutable = if ([string]::IsNullOrWhiteSpace($SliceExecutablePath)) {
    $builtPath = Join-Path $env:TEMP 'cmux_windows_notification.exe'
    & (Join-Path $PSScriptRoot 'build-windows-slice.ps1') -OutputPath $builtPath | Out-Null
    $builtPath
} else {
    $resolvedPath = Resolve-Path $SliceExecutablePath -ErrorAction Stop
    $resolvedPath.Path
}

$previousCommand = $env:CMUX_WINDOWS_COMMAND
$previousValue = $env:CMUX_WINDOWS_COMMAND_VALUE
$previousTitle = $env:CMUX_WINDOWS_COMMAND_TITLE
$previousCommandSequencePath = $env:CMUX_WINDOWS_COMMAND_SEQUENCE_PATH
$previousSmokeOutput = $env:CMUX_SMOKE_OUTPUT_PATH
$previousArtifactDirectory = $env:CMUX_SMOKE_ARTIFACT_DIR
$previousNotificationUiSuppressed = $env:CMUX_WINDOWS_NOTIFICATION_SUPPRESS_UI

try {
    $env:CMUX_WINDOWS_COMMAND = 'show-notification'
    $env:CMUX_WINDOWS_COMMAND_VALUE = 'Notification body'
    $env:CMUX_WINDOWS_COMMAND_TITLE = 'Smoke Notification'
    Remove-Item Env:CMUX_WINDOWS_COMMAND_SEQUENCE_PATH -ErrorAction SilentlyContinue
    $env:CMUX_SMOKE_OUTPUT_PATH = $SmokeOutputPath
    $env:CMUX_SMOKE_ARTIFACT_DIR = $ArtifactDirectory
    $env:CMUX_WINDOWS_NOTIFICATION_SUPPRESS_UI = '1'

    & $sliceExecutable | Out-Null
}
finally {
    if ($null -ne $previousCommand) { $env:CMUX_WINDOWS_COMMAND = $previousCommand } else { Remove-Item Env:CMUX_WINDOWS_COMMAND -ErrorAction SilentlyContinue }
    if ($null -ne $previousValue) { $env:CMUX_WINDOWS_COMMAND_VALUE = $previousValue } else { Remove-Item Env:CMUX_WINDOWS_COMMAND_VALUE -ErrorAction SilentlyContinue }
    if ($null -ne $previousTitle) { $env:CMUX_WINDOWS_COMMAND_TITLE = $previousTitle } else { Remove-Item Env:CMUX_WINDOWS_COMMAND_TITLE -ErrorAction SilentlyContinue }
    if ($null -ne $previousCommandSequencePath) { $env:CMUX_WINDOWS_COMMAND_SEQUENCE_PATH = $previousCommandSequencePath } else { Remove-Item Env:CMUX_WINDOWS_COMMAND_SEQUENCE_PATH -ErrorAction SilentlyContinue }
    if ($null -ne $previousSmokeOutput) { $env:CMUX_SMOKE_OUTPUT_PATH = $previousSmokeOutput } else { Remove-Item Env:CMUX_SMOKE_OUTPUT_PATH -ErrorAction SilentlyContinue }
    if ($null -ne $previousArtifactDirectory) { $env:CMUX_SMOKE_ARTIFACT_DIR = $previousArtifactDirectory } else { Remove-Item Env:CMUX_SMOKE_ARTIFACT_DIR -ErrorAction SilentlyContinue }
    if ($null -ne $previousNotificationUiSuppressed) { $env:CMUX_WINDOWS_NOTIFICATION_SUPPRESS_UI = $previousNotificationUiSuppressed } else { Remove-Item Env:CMUX_WINDOWS_NOTIFICATION_SUPPRESS_UI -ErrorAction SilentlyContinue }
}

if (-not (Test-Path $SmokeOutputPath)) {
    throw "Smoke report was not written to $SmokeOutputPath"
}

$report = Get-Content $SmokeOutputPath -Raw | ConvertFrom-Json

if ($report.sessionRoundTripMatches -ne $true) {
    throw "Expected sessionRoundTripMatches=true but found '$($report.sessionRoundTripMatches)'"
}

if ($report.commandCount -ne 1) {
    throw "Expected commandCount=1 but found '$($report.commandCount)'"
}

if (-not $report.notificationPreviewLines) {
    throw "Expected notificationPreviewLines to be populated"
}

if (-not (Test-Path (Join-Path $ArtifactDirectory 'notification-preview.txt'))) {
    throw "Expected notification-preview.txt in $ArtifactDirectory"
}

$summary = [pscustomobject]@{
    suite = 'windows-notification'
    caseCount = 1
    cases = @(
        [pscustomobject]@{
            name = 'notification'
            reportPath = $SmokeOutputPath
            artifactDirectory = $ArtifactDirectory
            workspaceCount = [int]$report.workspaceCount
            workspaceTitle = $report.selectedWorkspaceTitle
            workspacePanelCount = [int]$report.selectedWorkspacePanelCount
            commandTrace = @($report.commandTrace)
            commandTraceLength = @($report.commandTrace).Count
            eventTrace = @($report.eventTrace)
            eventTraceLength = @($report.eventTrace).Count
            notificationPreview = [bool]$report.notificationPreviewLines
            sessionRoundTripMatches = [bool]$report.sessionRoundTripMatches
        }
    )
}

$verdict = [pscustomobject]@{
    suite = 'windows-notification'
    caseCount = 1
    passedCount = 1
    failedCount = 0
    passed = $true
    cases = @(
        [pscustomobject]@{
            name = 'notification'
            passed = $true
            failureReason = $null
            failureCategory = $null
            reportPath = $SmokeOutputPath
        }
    )
}

$summary | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $ArtifactDirectory 'smoke-summary.json') -Encoding UTF8
$verdict | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $ArtifactDirectory 'smoke-verdict.json') -Encoding UTF8

Write-Host "Windows notification smoke passed"
Write-Host $SmokeOutputPath
Write-Host $ArtifactDirectory
