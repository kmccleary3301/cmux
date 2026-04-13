param(
    [string]$WorkspaceTitle = 'Smoke Workspace',
    [string]$SmokeOutputPath = $(Join-Path $env:TEMP 'cmux-windows-slice-report.json'),
    [string]$ArtifactDirectory = $(Join-Path $env:TEMP 'cmux-windows-slice-artifacts'),
    [string]$SliceExecutablePath = ''
)

$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Force -Path $ArtifactDirectory | Out-Null

$script:sliceExecutable = if ([string]::IsNullOrWhiteSpace($SliceExecutablePath)) {
    $builtPath = Join-Path $env:TEMP 'cmux_windows_slice.exe'
    & (Join-Path $PSScriptRoot 'build-windows-slice.ps1') -OutputPath $builtPath | Out-Null
    $builtPath
} else {
    $resolvedPath = Resolve-Path $SliceExecutablePath -ErrorAction Stop
    $resolvedPath.Path
}

$matrixResults = @()
$verdictResults = @()

function Get-FailureCategory {
    param([string]$Message)

    if ($Message -match 'ghosttyBridgePreviewLines|Ghostty|bridge') { return 'ghostty_bridge' }
    if ($Message -match 'notification') { return 'notification' }
    if ($Message -match 'browserPreviewLines|browser') { return 'browser' }
    if ($Message -match 'Layout|layout') { return 'layout' }
    if ($Message -match 'workspace') { return 'workspace' }
    if ($Message -match 'sessionRoundTripMatches|runtimeSession') { return 'state_roundtrip' }
    if ($Message -match 'commandTrace|eventTrace') { return 'trace_contract' }
    return 'general'
}

function Get-ReportFailureCategory {
    param($Report)

    if ($null -eq $Report) { return $null }

    if ($Report.ghosttyBridgeReports) {
        foreach ($bridgeReport in @($Report.ghosttyBridgeReports)) {
            if ($bridgeReport.failureCategory) {
                return [string]$bridgeReport.failureCategory
            }
        }
    }

    if ($Report.notificationPreviewLines) { return 'notification' }
    if ($Report.browserHostPreviewLines -or $Report.browserPreviewLines) { return 'browser' }
    if ($Report.selectedWorkspaceLayoutSummary) { return 'layout' }
    return $null
}

function Invoke-SmokeCase {
    param(
        [string]$Name,
        [string]$BootstrapCommand,
        [string]$BootstrapValue,
        [string]$BootstrapTitle,
        [object[]]$CommandSequence = $null,
        [string]$ExpectedTitle,
        [string]$ExpectedArtifactName,
        [string]$ExpectedDirectory,
        [bool]$ExpectedPinned = $false,
        [int]$ExpectedPanelCount = 0,
        [string]$ExpectedFocusedPanelTitle = $null,
        [int]$ExpectedWorkspaceCount = 1,
        [string]$ExpectedLayoutPattern = $null,
        [string[]]$ExpectedCommandTracePrefixes = @(),
        [string[]]$ExpectedEventTracePrefixes = @(),
        [string]$ExpectedGhosttyBridgePattern = $null,
        [int]$ExpectedRuntimeSessionCount = 0,
        [string]$ExpectedBrowserHostPattern = $null,
        [int]$ExpectedBrowserSessionCount = 0
    )

    $caseArtifactDirectory = Join-Path $ArtifactDirectory $Name
    $caseSmokeOutputPath = Join-Path $ArtifactDirectory "$Name-report.json"
    Remove-Item -Recurse -Force $caseArtifactDirectory -ErrorAction SilentlyContinue
    Remove-Item -Force $caseSmokeOutputPath -ErrorAction SilentlyContinue

    $previousCommand = $env:CMUX_WINDOWS_COMMAND
    $previousValue = $env:CMUX_WINDOWS_COMMAND_VALUE
    $previousTitle = $env:CMUX_WINDOWS_COMMAND_TITLE
    $previousCommandSequencePath = $env:CMUX_WINDOWS_COMMAND_SEQUENCE_PATH
    $previousSmokeOutput = $env:CMUX_SMOKE_OUTPUT_PATH
    $previousArtifactDirectory = $env:CMUX_SMOKE_ARTIFACT_DIR
    $previousNotificationUiSuppressed = $env:CMUX_WINDOWS_NOTIFICATION_SUPPRESS_UI
    $commandSequencePath = $null

    try {
        try {
            if ($CommandSequence) {
                $commandSequencePath = Join-Path $ArtifactDirectory "$Name-command-sequence.json"
                ($CommandSequence | ConvertTo-Json -Depth 4) | Set-Content -Path $commandSequencePath -Encoding UTF8
                $env:CMUX_WINDOWS_COMMAND_SEQUENCE_PATH = $commandSequencePath
                Remove-Item Env:CMUX_WINDOWS_COMMAND -ErrorAction SilentlyContinue
                Remove-Item Env:CMUX_WINDOWS_COMMAND_VALUE -ErrorAction SilentlyContinue
                Remove-Item Env:CMUX_WINDOWS_COMMAND_TITLE -ErrorAction SilentlyContinue
            } elseif (-not [string]::IsNullOrWhiteSpace($BootstrapCommand)) {
                $env:CMUX_WINDOWS_COMMAND = $BootstrapCommand
                Remove-Item Env:CMUX_WINDOWS_COMMAND_SEQUENCE_PATH -ErrorAction SilentlyContinue
            } else {
                Remove-Item Env:CMUX_WINDOWS_COMMAND -ErrorAction SilentlyContinue
                Remove-Item Env:CMUX_WINDOWS_COMMAND_SEQUENCE_PATH -ErrorAction SilentlyContinue
            }
            if ($null -eq $CommandSequence -and -not [string]::IsNullOrWhiteSpace($BootstrapValue)) {
                $env:CMUX_WINDOWS_COMMAND_VALUE = $BootstrapValue
            } else {
                Remove-Item Env:CMUX_WINDOWS_COMMAND_VALUE -ErrorAction SilentlyContinue
            }
            if ($null -eq $CommandSequence -and -not [string]::IsNullOrWhiteSpace($BootstrapTitle)) {
                $env:CMUX_WINDOWS_COMMAND_TITLE = $BootstrapTitle
            } else {
                Remove-Item Env:CMUX_WINDOWS_COMMAND_TITLE -ErrorAction SilentlyContinue
            }
            $env:CMUX_SMOKE_OUTPUT_PATH = $caseSmokeOutputPath
            $env:CMUX_SMOKE_ARTIFACT_DIR = $caseArtifactDirectory
            $env:CMUX_WINDOWS_NOTIFICATION_SUPPRESS_UI = '1'

            & $script:sliceExecutable | Out-Null

            if (-not (Test-Path $caseSmokeOutputPath)) {
                throw "[$Name] Smoke report was not written to $caseSmokeOutputPath"
            }

            $report = Get-Content $caseSmokeOutputPath -Raw | ConvertFrom-Json

            if ($report.workspaceCount -ne $ExpectedWorkspaceCount) {
                throw "[$Name] Expected workspaceCount=$ExpectedWorkspaceCount but found $($report.workspaceCount)"
            }

            if ($report.sessionRoundTripMatches -ne $true) {
                throw "[$Name] Expected sessionRoundTripMatches=true but found '$($report.sessionRoundTripMatches)'"
            }

            if ($BootstrapCommand -eq 'set-workspace-title' -and $report.selectedWorkspaceTitle -ne $ExpectedTitle) {
                throw "[$Name] Expected selectedWorkspaceTitle='$ExpectedTitle' but found '$($report.selectedWorkspaceTitle)'"
            }

            if ($ExpectedDirectory -and $report.selectedWorkspaceDirectory -ne $ExpectedDirectory) {
                throw "[$Name] Expected selectedWorkspaceDirectory='$ExpectedDirectory' but found '$($report.selectedWorkspaceDirectory)'"
            }

            if ($report.selectedWorkspacePanelCount -ne $ExpectedPanelCount) {
                throw "[$Name] Expected selectedWorkspacePanelCount=$ExpectedPanelCount but found $($report.selectedWorkspacePanelCount)"
            }

            if ($ExpectedFocusedPanelTitle -and $report.selectedWorkspaceFocusedPanelTitle -ne $ExpectedFocusedPanelTitle) {
                throw "[$Name] Expected selectedWorkspaceFocusedPanelTitle='$ExpectedFocusedPanelTitle' but found '$($report.selectedWorkspaceFocusedPanelTitle)'"
            }

            if ($ExpectedLayoutPattern -and $report.selectedWorkspaceLayoutSummary -notmatch $ExpectedLayoutPattern) {
                throw "[$Name] Expected selectedWorkspaceLayoutSummary to match '$ExpectedLayoutPattern' but found '$($report.selectedWorkspaceLayoutSummary)'"
            }

            if ($ExpectedCommandTracePrefixes.Count -gt 0) {
                if (-not $report.commandTrace) {
                    throw "[$Name] Expected commandTrace to be populated"
                }
                for ($index = 0; $index -lt $ExpectedCommandTracePrefixes.Count; $index++) {
                    if ($report.commandTrace.Count -le $index) {
                        throw "[$Name] Expected commandTrace item at index $index"
                    }
                    if (-not $report.commandTrace[$index].StartsWith($ExpectedCommandTracePrefixes[$index])) {
                        throw "[$Name] Expected commandTrace[$index] to start with '$($ExpectedCommandTracePrefixes[$index])' but found '$($report.commandTrace[$index])'"
                    }
                }
            }

            if ($ExpectedEventTracePrefixes.Count -gt 0) {
                if (-not $report.eventTrace) {
                    throw "[$Name] Expected eventTrace to be populated"
                }
                for ($index = 0; $index -lt $ExpectedEventTracePrefixes.Count; $index++) {
                    if ($report.eventTrace.Count -le $index) {
                        throw "[$Name] Expected eventTrace item at index $index"
                    }
                    if (-not $report.eventTrace[$index].StartsWith($ExpectedEventTracePrefixes[$index])) {
                        throw "[$Name] Expected eventTrace[$index] to start with '$($ExpectedEventTracePrefixes[$index])' but found '$($report.eventTrace[$index])'"
                    }
                }
            }

            if ($BootstrapCommand -eq 'set-workspace-pinned') {
                $previewText = ($report.shellPreviewLines -join "`n")
                if ($ExpectedPinned -and $previewText -notmatch '\[pinned\]') {
                    throw "[$Name] Expected pinned marker in shell preview"
                }
                if (-not $ExpectedPinned -and $previewText -match '\[pinned\]') {
                    throw "[$Name] Did not expect pinned marker in shell preview"
                }
            }

            if ($BootstrapCommand -eq 'open-browser-portal') {
                if (-not $report.browserPreviewLines) {
                    throw "[$Name] Expected browserPreviewLines to be populated"
                }
            }

            if ($ExpectedBrowserHostPattern) {
                if (-not $report.browserHostPreviewLines) {
                    throw "[$Name] Expected browserHostPreviewLines to be populated"
                }
                $browserHostPreviewText = ($report.browserHostPreviewLines -join "`n")
                if ($browserHostPreviewText -notmatch $ExpectedBrowserHostPattern) {
                    throw "[$Name] Expected browserHostPreviewLines to match '$ExpectedBrowserHostPattern'"
                }
            }

            if ($ExpectedGhosttyBridgePattern) {
                if (-not $report.ghosttyBridgePreviewLines) {
                    throw "[$Name] Expected ghosttyBridgePreviewLines to be populated"
                }
                $ghosttyPreviewText = ($report.ghosttyBridgePreviewLines -join "`n")
                if ($ghosttyPreviewText -notmatch $ExpectedGhosttyBridgePattern) {
                    throw "[$Name] Expected ghosttyBridgePreviewLines to match '$ExpectedGhosttyBridgePattern'"
                }
                if (-not $report.ghosttyBridgeReports) {
                    throw "[$Name] Expected ghosttyBridgeReports to be populated"
                }
            }

            $runtimeSessionCount = @($report.bridgedPanelRuntimeSessionIDs).Count
            if ($runtimeSessionCount -ne $ExpectedRuntimeSessionCount) {
                throw "[$Name] Expected bridgedPanelRuntimeSessionIDs count=$ExpectedRuntimeSessionCount but found $runtimeSessionCount"
            }

            $browserSessionCount = @($report.bridgedBrowserSessionIDs).Count
            if ($browserSessionCount -ne $ExpectedBrowserSessionCount) {
                throw "[$Name] Expected bridgedBrowserSessionIDs count=$ExpectedBrowserSessionCount but found $browserSessionCount"
            }

            if (-not (Test-Path (Join-Path $caseArtifactDirectory $ExpectedArtifactName))) {
                throw "[$Name] Expected $ExpectedArtifactName in $caseArtifactDirectory"
            }

            $summary = [pscustomobject]@{
                name = $Name
                reportPath = $caseSmokeOutputPath
                artifactDirectory = $caseArtifactDirectory
                bootstrapCommand = $report.bootstrapCommand
                workspaceCount = [int]$report.workspaceCount
                workspaceTitle = $report.selectedWorkspaceTitle
                workspaceDirectory = $report.selectedWorkspaceDirectory
                workspacePanelCount = [int]$report.selectedWorkspacePanelCount
                focusedPanelTitle = $report.selectedWorkspaceFocusedPanelTitle
                layoutSummary = $report.selectedWorkspaceLayoutSummary
                sessionRoundTripMatches = [bool]$report.sessionRoundTripMatches
                commandTrace = @($report.commandTrace)
                commandTraceLength = @($report.commandTrace).Count
                eventTrace = @($report.eventTrace)
                eventTraceLength = @($report.eventTrace).Count
                pinned = $ExpectedPinned
                browserPreview = [bool]$report.browserPreviewLines
                browserHostPreview = [bool]$report.browserHostPreviewLines
                notificationPreview = [bool]$report.notificationPreviewLines
                ghosttyBridgePreview = [bool]$report.ghosttyBridgePreviewLines
                ghosttyBridgeFailureCategories = @($report.ghosttyBridgeReports | ForEach-Object { $_.failureCategory } | Where-Object { $_ })
                runtimeSessionCount = $runtimeSessionCount
                browserSessionCount = $browserSessionCount
            }
            $script:matrixResults += $summary
            $script:verdictResults += [pscustomobject]@{
                name = $Name
                passed = $true
                failureReason = $null
                failureCategory = $null
                reportPath = $caseSmokeOutputPath
            }

            Write-Host "[$Name] passed"
        } catch {
            $reportFailureCategory = $null
            if (Test-Path $caseSmokeOutputPath) {
                try {
                    $report = Get-Content $caseSmokeOutputPath -Raw | ConvertFrom-Json
                    $reportFailureCategory = Get-ReportFailureCategory -Report $report
                } catch {
                }
            }
            $script:verdictResults += [pscustomobject]@{
                name = $Name
                passed = $false
                failureReason = $_.Exception.Message
                failureCategory = if ($reportFailureCategory) { $reportFailureCategory } else { Get-FailureCategory -Message $_.Exception.Message }
                reportPath = $caseSmokeOutputPath
            }
            Write-Host "[$Name] failed"
        }
    }
    finally {
        if ($null -ne $previousCommand) { $env:CMUX_WINDOWS_COMMAND = $previousCommand } else { Remove-Item Env:CMUX_WINDOWS_COMMAND -ErrorAction SilentlyContinue }
        if ($null -ne $previousValue) { $env:CMUX_WINDOWS_COMMAND_VALUE = $previousValue } else { Remove-Item Env:CMUX_WINDOWS_COMMAND_VALUE -ErrorAction SilentlyContinue }
        if ($null -ne $previousTitle) { $env:CMUX_WINDOWS_COMMAND_TITLE = $previousTitle } else { Remove-Item Env:CMUX_WINDOWS_COMMAND_TITLE -ErrorAction SilentlyContinue }
        if ($null -ne $previousCommandSequencePath) { $env:CMUX_WINDOWS_COMMAND_SEQUENCE_PATH = $previousCommandSequencePath } else { Remove-Item Env:CMUX_WINDOWS_COMMAND_SEQUENCE_PATH -ErrorAction SilentlyContinue }
        if ($null -ne $previousSmokeOutput) { $env:CMUX_SMOKE_OUTPUT_PATH = $previousSmokeOutput } else { Remove-Item Env:CMUX_SMOKE_OUTPUT_PATH -ErrorAction SilentlyContinue }
        if ($null -ne $previousArtifactDirectory) { $env:CMUX_SMOKE_ARTIFACT_DIR = $previousArtifactDirectory } else { Remove-Item Env:CMUX_SMOKE_ARTIFACT_DIR -ErrorAction SilentlyContinue }
        if ($null -ne $previousNotificationUiSuppressed) { $env:CMUX_WINDOWS_NOTIFICATION_SUPPRESS_UI = $previousNotificationUiSuppressed } else { Remove-Item Env:CMUX_WINDOWS_NOTIFICATION_SUPPRESS_UI -ErrorAction SilentlyContinue }
        if ($commandSequencePath) { Remove-Item -Force $commandSequencePath -ErrorAction SilentlyContinue }
    }
}

Invoke-SmokeCase `
    -Name 'title' `
    -BootstrapCommand 'set-workspace-title' `
    -BootstrapValue $WorkspaceTitle `
    -BootstrapTitle $null `
    -ExpectedTitle $WorkspaceTitle `
    -ExpectedArtifactName 'shell-preview.txt'

Invoke-SmokeCase `
    -Name 'browser' `
    -BootstrapCommand 'open-browser-portal' `
    -BootstrapValue 'https://example.com' `
    -BootstrapTitle 'Example Browser' `
    -ExpectedTitle 'Workspace' `
    -ExpectedArtifactName 'browser-preview.txt'

Invoke-SmokeCase `
    -Name 'directory' `
    -BootstrapCommand 'set-workspace-directory' `
    -BootstrapValue 'C:\Projects\cmux' `
    -BootstrapTitle $null `
    -ExpectedTitle 'Workspace' `
    -ExpectedArtifactName 'shell-preview.txt' `
    -ExpectedDirectory 'C:\Projects\cmux'

Invoke-SmokeCase `
    -Name 'pinned' `
    -BootstrapCommand 'set-workspace-pinned' `
    -BootstrapValue 'true' `
    -BootstrapTitle $null `
    -ExpectedTitle 'Workspace' `
    -ExpectedArtifactName 'shell-preview.txt' `
    -ExpectedPinned $true `
    -ExpectedLayoutPattern 'pane'

Invoke-SmokeCase `
    -Name 'terminal-panel' `
    -BootstrapCommand 'add-terminal-panel' `
    -BootstrapValue 'C:\Projects\cmux' `
    -BootstrapTitle 'Smoke Terminal' `
    -ExpectedTitle 'Workspace' `
    -ExpectedArtifactName 'shell-preview.txt' `
    -ExpectedPanelCount 1 `
    -ExpectedFocusedPanelTitle 'Smoke Terminal' `
    -ExpectedLayoutPattern 'pane\(selected=Smoke Terminal' `
    -ExpectedCommandTracePrefixes @('select-workspace','upsert-panel terminal Smoke Terminal','set-workspace-layout','set-workspace-focused-panel')

Invoke-SmokeCase `
    -Name 'browser-panel' `
    -BootstrapCommand 'add-browser-panel' `
    -BootstrapValue 'https://example.com/docs' `
    -BootstrapTitle 'Docs Browser' `
    -ExpectedTitle 'Workspace' `
    -ExpectedArtifactName 'shell-preview.txt' `
    -ExpectedPanelCount 1 `
    -ExpectedFocusedPanelTitle 'Docs Browser' `
    -ExpectedLayoutPattern 'pane\(selected=Docs Browser' `
    -ExpectedCommandTracePrefixes @('select-workspace','upsert-panel browser Docs Browser','set-workspace-layout','set-workspace-focused-panel') `
    -ExpectedEventTracePrefixes @('surface-focused','surface-title-changed','browser-location-changed') `
    -ExpectedBrowserHostPattern 'Operation: open-panel' `
    -ExpectedBrowserSessionCount 1

Invoke-SmokeCase `
    -Name 'browser-split-horizontal' `
    -CommandSequence @(
        @{ command = 'add-terminal-panel'; title = 'Primary Terminal' },
        @{ command = 'split-browser-horizontal'; value = 'https://example.com/docs'; title = 'Docs Browser' }
    ) `
    -ExpectedTitle 'Workspace' `
    -ExpectedArtifactName 'browser-host-preview.txt' `
    -ExpectedPanelCount 2 `
    -ExpectedFocusedPanelTitle 'Docs Browser' `
    -ExpectedLayoutPattern 'split\(horizontal; first=pane\(selected=Primary Terminal; panels=\[Primary Terminal\]\); second=pane\(selected=Docs Browser; panels=\[Docs Browser\]\)\)' `
    -ExpectedCommandTracePrefixes @('select-workspace','upsert-panel terminal Primary Terminal','set-workspace-layout','set-workspace-focused-panel','upsert-panel browser Docs Browser','set-workspace-layout','set-workspace-focused-panel') `
    -ExpectedEventTracePrefixes @('surface-focused','surface-title-changed','browser-location-changed') `
    -ExpectedBrowserHostPattern 'Operation: open-panel' `
    -ExpectedBrowserSessionCount 1

Invoke-SmokeCase `
    -Name 'split-horizontal' `
    -CommandSequence @(
        @{ command = 'add-terminal-panel'; value = 'C:\Projects\cmux'; title = 'Primary Terminal' },
        @{ command = 'split-workspace-horizontal'; title = 'Secondary Terminal' }
    ) `
    -ExpectedTitle 'Workspace' `
    -ExpectedArtifactName 'shell-preview.txt' `
    -ExpectedPanelCount 2 `
    -ExpectedFocusedPanelTitle 'Secondary Terminal' `
    -ExpectedLayoutPattern 'split\(horizontal' `
    -ExpectedCommandTracePrefixes @('select-workspace','upsert-panel terminal Primary Terminal','set-workspace-layout','set-workspace-focused-panel','upsert-panel terminal Secondary Terminal','set-workspace-layout','set-workspace-focused-panel')

Invoke-SmokeCase `
    -Name 'split-vertical' `
    -CommandSequence @(
        @{ command = 'add-terminal-panel'; title = 'Upper Terminal' },
        @{ command = 'split-workspace-vertical'; title = 'Lower Terminal' }
    ) `
    -ExpectedTitle 'Workspace' `
    -ExpectedArtifactName 'shell-preview.txt' `
    -ExpectedPanelCount 2 `
    -ExpectedFocusedPanelTitle 'Lower Terminal' `
    -ExpectedLayoutPattern 'split\(vertical' `
    -ExpectedCommandTracePrefixes @('select-workspace','upsert-panel terminal Upper Terminal','set-workspace-layout','set-workspace-focused-panel','upsert-panel terminal Lower Terminal','set-workspace-layout','set-workspace-focused-panel')

Invoke-SmokeCase `
    -Name 'focus-panel' `
    -CommandSequence @(
        @{ command = 'add-terminal-panel'; title = 'Primary Terminal' },
        @{ command = 'split-workspace-horizontal'; title = 'Secondary Terminal' },
        @{ command = 'focus-panel'; title = 'Primary Terminal' }
    ) `
    -ExpectedTitle 'Workspace' `
    -ExpectedArtifactName 'shell-preview.txt' `
    -ExpectedPanelCount 2 `
    -ExpectedFocusedPanelTitle 'Primary Terminal' `
    -ExpectedLayoutPattern 'split\(horizontal' `
    -ExpectedCommandTracePrefixes @('select-workspace','upsert-panel terminal Primary Terminal','set-workspace-layout','set-workspace-focused-panel','upsert-panel terminal Secondary Terminal','set-workspace-layout','set-workspace-focused-panel','set-workspace-focused-panel')

Invoke-SmokeCase `
    -Name 'close-panel-focus' `
    -CommandSequence @(
        @{ command = 'add-terminal-panel'; title = 'Primary Terminal' },
        @{ command = 'split-workspace-horizontal'; title = 'Secondary Terminal' },
        @{ command = 'close-focused-panel' }
    ) `
    -ExpectedTitle 'Workspace' `
    -ExpectedArtifactName 'shell-preview.txt' `
    -ExpectedPanelCount 1 `
    -ExpectedFocusedPanelTitle 'Primary Terminal' `
    -ExpectedLayoutPattern 'pane\(selected=Primary Terminal' `
    -ExpectedCommandTracePrefixes @('select-workspace','upsert-panel terminal Primary Terminal','set-workspace-layout','set-workspace-focused-panel','upsert-panel terminal Secondary Terminal','set-workspace-layout','set-workspace-focused-panel','remove-panel')

Invoke-SmokeCase `
    -Name 'browser-panel-lifecycle' `
    -CommandSequence @(
        @{ command = 'add-browser-panel'; value = 'https://example.com/docs'; title = 'Docs Browser' },
        @{ command = 'close-focused-panel' }
    ) `
    -ExpectedTitle 'Workspace' `
    -ExpectedArtifactName 'browser-host-preview.txt' `
    -ExpectedPanelCount 0 `
    -ExpectedLayoutPattern 'pane\(panels=\[empty\]\)' `
    -ExpectedCommandTracePrefixes @('select-workspace','upsert-panel browser Docs Browser','set-workspace-layout','set-workspace-focused-panel','remove-panel') `
    -ExpectedEventTracePrefixes @('surface-focused','surface-title-changed','browser-location-changed','surface-closed') `
    -ExpectedBrowserHostPattern 'Operation: close' `
    -ExpectedBrowserSessionCount 0

Invoke-SmokeCase `
    -Name 'workspace-lifecycle' `
    -CommandSequence @(
        @{ command = 'add-workspace'; title = 'Workspace Two' },
        @{ command = 'add-workspace'; title = 'Workspace Three' },
        @{ command = 'select-workspace-index'; value = '1' },
        @{ command = 'close-selected-workspace' }
    ) `
    -ExpectedTitle 'Workspace Three' `
    -ExpectedArtifactName 'shell-preview.txt' `
    -ExpectedWorkspaceCount 2 `
    -ExpectedPanelCount 0 `
    -ExpectedLayoutPattern 'pane' `
    -ExpectedCommandTracePrefixes @('select-workspace','insert-workspace Workspace Two','select-workspace','insert-workspace Workspace Three','select-workspace','select-workspace','close-workspace')

Invoke-SmokeCase `
    -Name 'nested-split' `
    -CommandSequence @(
        @{ command = 'add-terminal-panel'; title = 'Primary Terminal' },
        @{ command = 'split-workspace-horizontal'; title = 'Secondary Terminal' },
        @{ command = 'nest-focused-panel-vertical'; title = 'Tertiary Terminal' }
    ) `
    -ExpectedTitle 'Workspace' `
    -ExpectedArtifactName 'shell-preview.txt' `
    -ExpectedPanelCount 3 `
    -ExpectedFocusedPanelTitle 'Tertiary Terminal' `
    -ExpectedLayoutPattern 'split\(horizontal; first=pane\(selected=Primary Terminal; panels=\[Primary Terminal\]\); second=split\(vertical; first=pane\(selected=Secondary Terminal; panels=\[Secondary Terminal\]\); second=pane\(selected=Tertiary Terminal; panels=\[Tertiary Terminal\]\)\)\)' `
    -ExpectedCommandTracePrefixes @('select-workspace','upsert-panel terminal Primary Terminal','set-workspace-layout','set-workspace-focused-panel','upsert-panel terminal Secondary Terminal','set-workspace-layout','set-workspace-focused-panel','upsert-panel terminal Tertiary Terminal','set-workspace-layout','set-workspace-focused-panel')

Invoke-SmokeCase `
    -Name 'ghostty-terminal' `
    -BootstrapCommand 'launch-ghostty-terminal' `
    -BootstrapValue 'C:\Projects\cmux' `
    -BootstrapTitle 'Ghostty Terminal' `
    -ExpectedTitle 'Workspace' `
    -ExpectedArtifactName 'ghostty-bridge-preview.txt' `
    -ExpectedPanelCount 1 `
    -ExpectedFocusedPanelTitle 'Ghostty Terminal' `
    -ExpectedLayoutPattern 'pane\(selected=Ghostty Terminal' `
    -ExpectedCommandTracePrefixes @('select-workspace','upsert-panel terminal Ghostty Terminal','set-workspace-layout','set-workspace-focused-panel') `
    -ExpectedEventTracePrefixes @('surface-focused','surface-title-changed') `
    -ExpectedGhosttyBridgePattern 'Operation: launch[\s\S]*ProbeMatchedSession: true' `
    -ExpectedRuntimeSessionCount 1

Invoke-SmokeCase `
    -Name 'ghostty-version' `
    -BootstrapCommand 'probe-ghostty-version' `
    -BootstrapValue $null `
    -BootstrapTitle $null `
    -ExpectedTitle 'Workspace' `
    -ExpectedArtifactName 'ghostty-bridge-preview.txt' `
    -ExpectedPanelCount 1 `
    -ExpectedFocusedPanelTitle 'Ghostty Probe' `
    -ExpectedLayoutPattern 'pane\(selected=Ghostty Probe' `
    -ExpectedCommandTracePrefixes @('select-workspace','upsert-panel terminal Ghostty Probe','set-workspace-layout','set-workspace-focused-panel') `
    -ExpectedEventTracePrefixes @('surface-focused','surface-title-changed') `
    -ExpectedGhosttyBridgePattern 'Operation: launch[\s\S]*ProbeMatchedSession: true' `
    -ExpectedRuntimeSessionCount 1

Invoke-SmokeCase `
    -Name 'ghostty-terminal-lifecycle' `
    -CommandSequence @(
        @{ command = 'launch-ghostty-terminal'; value = 'C:\Projects\cmux'; title = 'Ghostty Terminal' },
        @{ command = 'close-focused-panel' }
    ) `
    -ExpectedTitle 'Workspace' `
    -ExpectedArtifactName 'ghostty-bridge-preview.txt' `
    -ExpectedPanelCount 0 `
    -ExpectedLayoutPattern 'pane\(panels=\[empty\]\)' `
    -ExpectedCommandTracePrefixes @('select-workspace','upsert-panel terminal Ghostty Terminal','set-workspace-layout','set-workspace-focused-panel','remove-panel') `
    -ExpectedEventTracePrefixes @('surface-focused','surface-title-changed','surface-closed') `
    -ExpectedGhosttyBridgePattern 'Operation: close[\s\S]*ProbeMatchedSession: true' `
    -ExpectedRuntimeSessionCount 0

$summary = [pscustomobject]@{
    suite = 'windows-slice'
    caseCount = $matrixResults.Count
    cases = $matrixResults
}

$failedCases = @($verdictResults | Where-Object { -not $_.passed })
$verdict = [pscustomobject]@{
    suite = 'windows-slice'
    caseCount = $verdictResults.Count
    passedCount = @($verdictResults | Where-Object { $_.passed }).Count
    failedCount = $failedCases.Count
    passed = ($failedCases.Count -eq 0)
    cases = $verdictResults
}

($summary | ConvertTo-Json -Depth 5) | Set-Content -Path (Join-Path $ArtifactDirectory 'smoke-summary.json') -Encoding UTF8
($verdict | ConvertTo-Json -Depth 5) | Set-Content -Path (Join-Path $ArtifactDirectory 'smoke-verdict.json') -Encoding UTF8

if ($failedCases.Count -gt 0) {
    throw "Windows slice smoke failed. See $(Join-Path $ArtifactDirectory 'smoke-verdict.json')"
}

Write-Host "Windows slice smoke passed"
Write-Host $SmokeOutputPath
Write-Host $ArtifactDirectory
