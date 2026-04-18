param(
    [string]$InstallRoot = $(Resolve-Path (Join-Path $PSScriptRoot '..')),
    [string]$RootArtifactDirectory = $(Join-Path $InstallRoot ("artifacts\\r\\" + (Get-Date -Format 'yyyyMMddHHmmss') + "-" + [guid]::NewGuid().Guid.Substring(0, 8))),
    [string]$LogDirectory = $(Join-Path $InstallRoot 'logs')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows-slice-package-lock.ps1')

Invoke-CmuxWindowsSlicePackageLocked {
    New-Item -ItemType Directory -Force -Path $RootArtifactDirectory | Out-Null
    New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null
    $latestArtifactDirectory = Join-Path $InstallRoot 'artifacts\latest'
    New-Item -ItemType Directory -Force -Path $latestArtifactDirectory | Out-Null

    $sliceExecutablePath = Join-Path $InstallRoot 'bin\cmux-windows-slice.exe'
    $ghosttyExecutablePath = Join-Path $InstallRoot 'bin\ghostty.exe'
    $ghosttyLibraryPath = Join-Path $InstallRoot 'bin\libghostty.so'
    $ghosttyResourcesDirectory = Join-Path $InstallRoot 'resources\ghostty'
    $browserHelperExecutablePath = Join-Path $InstallRoot 'bin\cmux_windows_webview2_spike.exe'
    $browserChildHelperExecutablePath = Join-Path $InstallRoot 'bin\cmux_windows_webview2_child_host.exe'
    $shellHostHelperExecutablePath = Join-Path $InstallRoot 'bin\cmux_windows_shell_host_spike.exe'
    if (-not (Test-Path $sliceExecutablePath)) {
        $repoCandidate = Join-Path $env:TEMP 'cmux_windows_slice.exe'
        if (Test-Path $repoCandidate) {
            $sliceExecutablePath = $repoCandidate
        } else {
            throw "Slice executable not found at $sliceExecutablePath"
        }
    }
    if (-not (Test-Path $ghosttyExecutablePath)) {
        throw "Ghostty executable not found at $ghosttyExecutablePath"
    }
    if (-not (Test-Path $ghosttyLibraryPath)) {
        throw "Ghostty embedded library not found at $ghosttyLibraryPath"
    }
    if (-not (Test-Path $ghosttyResourcesDirectory)) {
        throw "Ghostty resources directory not found at $ghosttyResourcesDirectory"
    }
    if (-not (Test-Path $browserHelperExecutablePath)) {
        throw "Browser helper executable not found at $browserHelperExecutablePath"
    }
    if (-not (Test-Path $browserChildHelperExecutablePath)) {
        throw "Browser child helper executable not found at $browserChildHelperExecutablePath"
    }
    if (-not (Test-Path $shellHostHelperExecutablePath)) {
        throw "Shell host helper executable not found at $shellHostHelperExecutablePath"
    }

    $logPath = Join-Path $LogDirectory 'windows-lane-ci.log'
    Start-Transcript -Path $logPath -Force | Out-Null
    try {
        $previousGhosttyExecutablePath = $env:CMUX_GHOSTTY_EXE
        $previousGhosttyLibraryPath = $env:CMUX_GHOSTTY_LIB
        $previousGhosttyResourcesDirectory = $env:GHOSTTY_RESOURCES_DIR
        $previousBrowserHelperExecutablePath = $env:CMUX_WINDOWS_BROWSER_HELPER_EXE
        $previousBrowserChildHelperExecutablePath = $env:CMUX_WINDOWS_BROWSER_CHILD_HELPER_EXE
        $previousShellHostHelperExecutablePath = $env:CMUX_WINDOWS_SHELL_HOST_HELPER_EXE
        $env:CMUX_GHOSTTY_EXE = $ghosttyExecutablePath
        $env:CMUX_GHOSTTY_LIB = $ghosttyLibraryPath
        $env:GHOSTTY_RESOURCES_DIR = $ghosttyResourcesDirectory
        $env:CMUX_WINDOWS_BROWSER_HELPER_EXE = $browserHelperExecutablePath
        $env:CMUX_WINDOWS_BROWSER_CHILD_HELPER_EXE = $browserChildHelperExecutablePath
        $env:CMUX_WINDOWS_SHELL_HOST_HELPER_EXE = $shellHostHelperExecutablePath
        $smokeArtifactDirectory = $RootArtifactDirectory
        $crashRecoveryArtifactDirectory = Join-Path $RootArtifactDirectory 'packaged-crash-recovery'
        $crashRetentionArtifactDirectory = Join-Path $RootArtifactDirectory 'packaged-crash-retention'
        $crashSoakArtifactDirectory = Join-Path $RootArtifactDirectory 'packaged-crash-soak'
        & (Join-Path $PSScriptRoot 'test-windows-all.ps1') `
            -RootArtifactDirectory $smokeArtifactDirectory `
            -SliceExecutablePath $sliceExecutablePath
        & (Join-Path $PSScriptRoot 'test-windows-shell-host-crash-recovery.ps1') `
            -ArtifactDirectory $crashRecoveryArtifactDirectory `
            -SliceExecutablePath $sliceExecutablePath | Out-Null
        & (Join-Path $PSScriptRoot 'test-windows-shell-host-crash-retention.ps1') `
            -ArtifactDirectory $crashRetentionArtifactDirectory `
            -SliceExecutablePath $sliceExecutablePath
        & (Join-Path $PSScriptRoot 'test-windows-shell-host-crash-soak.ps1') `
            -ArtifactDirectory $crashSoakArtifactDirectory `
            -SliceExecutablePath $sliceExecutablePath | Out-Null

        $smokeSummary = Get-Content (Join-Path $smokeArtifactDirectory 'smoke-summary.json') -Raw | ConvertFrom-Json
        $smokeVerdict = Get-Content (Join-Path $smokeArtifactDirectory 'smoke-verdict.json') -Raw | ConvertFrom-Json
        $crashRecoveryReport = Get-Content (Join-Path $crashRecoveryArtifactDirectory 'shell-host-crash-recovery-report.json') -Raw | ConvertFrom-Json
        $crashRetentionReport = Get-Content (Join-Path $crashRetentionArtifactDirectory 'shell-host-crash-retention-report.json') -Raw | ConvertFrom-Json
        $crashSoakReport = Get-Content (Join-Path $crashSoakArtifactDirectory 'shell-host-crash-soak-report.json') -Raw | ConvertFrom-Json

        $packageSummary = [pscustomobject]@{
            suite = 'windows-lane-ci'
            installRoot = $InstallRoot
            rootArtifactDirectory = $RootArtifactDirectory
            latestArtifactDirectory = $latestArtifactDirectory
            generatedAt = (Get-Date).ToString('o')
            suites = @(
                [pscustomobject]@{
                    id = 'windows-all'
                    artifactDirectory = $smokeArtifactDirectory
                    summary = $smokeSummary
                },
                [pscustomobject]@{
                    id = 'packaged-crash-recovery'
                    artifactDirectory = $crashRecoveryArtifactDirectory
                    report = $crashRecoveryReport
                },
                [pscustomobject]@{
                    id = 'packaged-crash-retention'
                    artifactDirectory = $crashRetentionArtifactDirectory
                    report = $crashRetentionReport
                },
                [pscustomobject]@{
                    id = 'packaged-crash-soak'
                    artifactDirectory = $crashSoakArtifactDirectory
                    report = $crashSoakReport
                }
            )
        }
        $packageSummary | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $RootArtifactDirectory 'package-ci-summary.json') -Encoding UTF8
        $packageSummary | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $latestArtifactDirectory 'package-ci-summary.json') -Encoding UTF8

        $crashTriageSummary = [pscustomobject]@{
            suite = 'windows-lane-ci-crash-triage'
            installRoot = $InstallRoot
            rootArtifactDirectory = $RootArtifactDirectory
            latestArtifactDirectory = $latestArtifactDirectory
            generatedAt = (Get-Date).ToString('o')
            crashRecovery = [pscustomobject]@{
                artifactDirectory = $crashRecoveryArtifactDirectory
                autosaveWorkspaceTitle = [string]$crashRecoveryReport.autosaveWorkspaceTitle
                processAliveDuringKill = [bool]$crashRecoveryReport.processAliveDuringKill
                snapshotRoundTripMatches = [bool]$crashRecoveryReport.snapshotRoundTripMatches
                restoreShellHostSuccess = [bool]$crashRecoveryReport.restoreShellHostSuccess
                restoreShellHostBrowserStatus = [string]$crashRecoveryReport.restoreShellHostBrowserStatus
                restoreShellHostDurationMs = [int]$crashRecoveryReport.restoreShellHostDurationMs
                retainedArtifactCategories = @($crashRecoveryReport.retainedArtifactCategories | ForEach-Object { [string]$_ })
                missingArtifactCategories = @($crashRecoveryReport.missingArtifactCategories | ForEach-Object { [string]$_ })
                crashActionTail = @($crashRecoveryReport.crashActionTail | ForEach-Object { [string]$_ })
                crashFocusTail = @($crashRecoveryReport.crashFocusTail | ForEach-Object { [string]$_ })
                restoreActionTail = @($crashRecoveryReport.restoreActionTail | ForEach-Object { [string]$_ })
                restoreFocusTail = @($crashRecoveryReport.restoreFocusTail | ForEach-Object { [string]$_ })
                restoreTranscriptTail = @($crashRecoveryReport.restoreTranscriptTail | ForEach-Object { [string]$_ })
            }
            crashRetention = [pscustomobject]@{
                artifactDirectory = $crashRetentionArtifactDirectory
                cycleCount = [int]$crashRetentionReport.cycleCount
                allWorkspaceTitlesConsistent = [bool]$crashRetentionReport.allWorkspaceTitlesConsistent
                minCopiedArtifactCount = [int]$crashRetentionReport.minCopiedArtifactCount
                maxCopiedArtifactCount = [int]$crashRetentionReport.maxCopiedArtifactCount
                cycleDirectories = @($crashRetentionReport.cycles | ForEach-Object { [string]$_.cycleDirectory })
            }
            crashSoak = [pscustomobject]@{
                artifactDirectory = $crashSoakArtifactDirectory
                cycleCount = [int]$crashSoakReport.cycleCount
                allWorkspaceTitlesConsistent = [bool]$crashSoakReport.allWorkspaceTitlesConsistent
                allFocusedPanelTitlesConsistent = [bool]$crashSoakReport.allFocusedPanelTitlesConsistent
                allRequiredRetainedCategoriesPresent = [bool]$crashSoakReport.allRequiredRetainedCategoriesPresent
                minRestoreShellHostDurationMs = [int]$crashSoakReport.minRestoreShellHostDurationMs
                maxRestoreShellHostDurationMs = [int]$crashSoakReport.maxRestoreShellHostDurationMs
                minCopiedArtifactCount = [int]$crashSoakReport.minCopiedArtifactCount
                maxCopiedArtifactCount = [int]$crashSoakReport.maxCopiedArtifactCount
                retainedArtifactCategories = @($crashSoakReport.retainedArtifactCategories | ForEach-Object { [string]$_ })
                missingRequiredRetainedCategories = @($crashSoakReport.missingRequiredRetainedCategories | ForEach-Object { [string]$_ })
                cycleDirectories = @($crashSoakReport.cycles | ForEach-Object { [string]$_.cycleDirectory })
            }
        }
        $crashTriageSummary | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $RootArtifactDirectory 'crash-triage-summary.json') -Encoding UTF8
        $crashTriageSummary | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $latestArtifactDirectory 'crash-triage-summary.json') -Encoding UTF8

        $packageVerdict = [pscustomobject]@{
            suite = 'windows-lane-ci'
            installRoot = $InstallRoot
            rootArtifactDirectory = $RootArtifactDirectory
            latestArtifactDirectory = $latestArtifactDirectory
            passed = $true
            caseCount = 4
            passedCount = 4
            failedCount = 0
            cases = @(
                [pscustomobject]@{
                    id = 'windows-all'
                    passed = [bool]$smokeVerdict.passed
                    artifactDirectory = $smokeArtifactDirectory
                },
                [pscustomobject]@{
                    id = 'packaged-crash-recovery'
                    passed = [bool]($crashRecoveryReport.processAliveDuringKill -and $crashRecoveryReport.snapshotRoundTripMatches -and $crashRecoveryReport.restoreShellHostSuccess)
                    artifactDirectory = $crashRecoveryArtifactDirectory
                },
                [pscustomobject]@{
                    id = 'packaged-crash-retention'
                    passed = [bool]($crashRetentionReport.cycleCount -ge 2 -and $crashRetentionReport.allWorkspaceTitlesConsistent -and $crashRetentionReport.minCopiedArtifactCount -ge 4)
                    artifactDirectory = $crashRetentionArtifactDirectory
                },
                [pscustomobject]@{
                    id = 'packaged-crash-soak'
                    passed = [bool](
                        $crashSoakReport.cycleCount -ge 5 -and
                        $crashSoakReport.allWorkspaceTitlesConsistent -and
                        $crashSoakReport.allFocusedPanelTitlesConsistent -and
                        $crashSoakReport.allRequiredRetainedCategoriesPresent -and
                        $crashSoakReport.minCopiedArtifactCount -ge 4
                    )
                    artifactDirectory = $crashSoakArtifactDirectory
                }
            )
        }
        $packageVerdict.passed = (@($packageVerdict.cases | Where-Object { -not $_.passed }).Count -eq 0)
        $packageVerdict.passedCount = @($packageVerdict.cases | Where-Object { $_.passed }).Count
        $packageVerdict.failedCount = @($packageVerdict.cases | Where-Object { -not $_.passed }).Count
        $packageVerdict | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $RootArtifactDirectory 'package-ci-verdict.json') -Encoding UTF8
        $packageVerdict | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $latestArtifactDirectory 'package-ci-verdict.json') -Encoding UTF8
        Set-Content -Path (Join-Path $latestArtifactDirectory 'latest-run.txt') -Value $RootArtifactDirectory -Encoding UTF8

        & (Join-Path $PSScriptRoot 'export-windows-lane-triage-bundle.ps1') `
            -InstallRoot $InstallRoot `
            -RootArtifactDirectory $RootArtifactDirectory `
            -OutputDirectory $latestArtifactDirectory `
            -BundleLabel ("windows-lane-triage-" + (Split-Path -Leaf $RootArtifactDirectory)) | Out-Null
    }
    finally {
        if ($null -ne $previousGhosttyExecutablePath) {
            $env:CMUX_GHOSTTY_EXE = $previousGhosttyExecutablePath
        } else {
            Remove-Item Env:CMUX_GHOSTTY_EXE -ErrorAction SilentlyContinue
        }
        if ($null -ne $previousGhosttyLibraryPath) {
            $env:CMUX_GHOSTTY_LIB = $previousGhosttyLibraryPath
        } else {
            Remove-Item Env:CMUX_GHOSTTY_LIB -ErrorAction SilentlyContinue
        }
        if ($null -ne $previousGhosttyResourcesDirectory) {
            $env:GHOSTTY_RESOURCES_DIR = $previousGhosttyResourcesDirectory
        } else {
            Remove-Item Env:GHOSTTY_RESOURCES_DIR -ErrorAction SilentlyContinue
        }
        if ($null -ne $previousBrowserHelperExecutablePath) {
            $env:CMUX_WINDOWS_BROWSER_HELPER_EXE = $previousBrowserHelperExecutablePath
        } else {
            Remove-Item Env:CMUX_WINDOWS_BROWSER_HELPER_EXE -ErrorAction SilentlyContinue
        }
        if ($null -ne $previousBrowserChildHelperExecutablePath) {
            $env:CMUX_WINDOWS_BROWSER_CHILD_HELPER_EXE = $previousBrowserChildHelperExecutablePath
        } else {
            Remove-Item Env:CMUX_WINDOWS_BROWSER_CHILD_HELPER_EXE -ErrorAction SilentlyContinue
        }
        if ($null -ne $previousShellHostHelperExecutablePath) {
            $env:CMUX_WINDOWS_SHELL_HOST_HELPER_EXE = $previousShellHostHelperExecutablePath
        } else {
            Remove-Item Env:CMUX_WINDOWS_SHELL_HOST_HELPER_EXE -ErrorAction SilentlyContinue
        }
        Stop-Transcript | Out-Null
    }
    Write-Host "Windows lane CI log: $logPath"
}
