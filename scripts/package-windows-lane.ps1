param(
    [string]$OutputRoot = $(Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')) 'dist\windows-lane'),
    [string]$SwiftRoot = $env:CMUX_SWIFT_ROOT,
    [string]$SwiftVersion = $env:CMUX_SWIFT_VERSION,
    [string]$MsvcVersion = $env:CMUX_MSVC_VERSION,
    [string]$VersionLabel = '',
    [string]$ReleaseLabel = ''
)

$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$projectRoot = Resolve-Path (Join-Path $repoRoot '..')
. (Join-Path $PSScriptRoot 'windows-slice-package-lock.ps1')

function Get-GitRevision {
    param([string]$RepositoryRoot)

    try {
        $revision = git -C $RepositoryRoot rev-parse --short HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($revision)) {
            return $revision.Trim()
        }
    } catch {
    }

    return $null
}

function Get-GhosttyVersionLine {
    param([string]$ExecutablePath)

    try {
        $versionOutput = & $ExecutablePath +version 2>&1
        if ($LASTEXITCODE -eq 0 -and $versionOutput) {
            $versionLine = $versionOutput | Where-Object {
                $_ -match 'Ghostty ' -or $_ -match 'ghostty version='
            } | Select-Object -First 1
            if ($versionLine) {
                return $versionLine.Trim()
            }
            return ($versionOutput | Select-Object -First 1).Trim()
        }
    } catch {
    }

    return $null
}

$buildTimestamp = Get-Date
$cmuxRevision = Get-GitRevision -RepositoryRoot $repoRoot
$ghosttyRevision = Get-GitRevision -RepositoryRoot (Join-Path $projectRoot 'ghostty')
$resolvedVersionLabel = if ([string]::IsNullOrWhiteSpace($VersionLabel)) {
    $timestampLabel = $buildTimestamp.ToString('yyyyMMdd-HHmmss')
    if ($cmuxRevision) {
        "0.1.0-dev+$timestampLabel.$cmuxRevision"
    } else {
        "0.1.0-dev+$timestampLabel"
    }
} else {
    $VersionLabel.Trim()
}
$resolvedReleaseLabel = if ([string]::IsNullOrWhiteSpace($ReleaseLabel)) {
    "cmux-windows-lane-$resolvedVersionLabel"
} else {
    $ReleaseLabel.Trim()
}

$ghosttyExe = Join-Path $projectRoot 'ghostty\zig-out\bin\ghostty.exe'
$ghosttyLib = Join-Path $projectRoot 'ghostty\zig-out\lib\libghostty.so'
$ghosttyResourcesDir = Join-Path $projectRoot 'ghostty\zig-out\share\ghostty'
if (-not (Test-Path $ghosttyExe)) {
    throw "Ghostty executable not found at $ghosttyExe"
}
if (-not (Test-Path $ghosttyLib)) {
    throw "Ghostty embedded library not found at $ghosttyLib"
}
if (-not (Test-Path $ghosttyResourcesDir)) {
    throw "Ghostty resources directory not found at $ghosttyResourcesDir"
}

Invoke-CmuxWindowsSlicePackageLocked {
    $binDirectory = Join-Path $OutputRoot 'bin'
    $docsDirectory = Join-Path $OutputRoot 'docs'
    $logsDirectory = Join-Path $OutputRoot 'logs'
    $artifactsDirectory = Join-Path $OutputRoot 'artifacts'
    $toolsDirectory = Join-Path $OutputRoot 'tools'
    $resourcesDirectory = Join-Path $OutputRoot 'resources'
    $ghosttyResourcesOutputDirectory = Join-Path $resourcesDirectory 'ghostty'
    $ghosttyLogsDirectory = Join-Path $logsDirectory 'ghostty'
    $cmuxLogsDirectory = Join-Path $logsDirectory 'cmux'

    foreach ($directory in @($OutputRoot, $binDirectory, $docsDirectory, $logsDirectory, $artifactsDirectory, $toolsDirectory, $resourcesDirectory, $ghosttyResourcesOutputDirectory, $ghosttyLogsDirectory, $cmuxLogsDirectory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $sliceExe = Join-Path $binDirectory 'cmux-windows-slice.exe'
    & (Join-Path $PSScriptRoot 'build-windows-slice-package.ps1') `
        -OutputPath $sliceExe `
        -SwiftRoot $SwiftRoot `
        -SwiftVersion $SwiftVersion `
        -MsvcVersion $MsvcVersion `
        -Sync | Out-Null

    Copy-Item -Path $ghosttyExe -Destination (Join-Path $binDirectory 'ghostty.exe') -Force
    Copy-Item -Path $ghosttyLib -Destination (Join-Path $binDirectory 'libghostty.so') -Force
    Copy-Item -Path (Join-Path $ghosttyResourcesDir '*') -Destination $ghosttyResourcesOutputDirectory -Recurse -Force
    Copy-Item -Path (Join-Path $projectRoot 'docs_tmp\WINDOWS_SLICE_BUILD_CONTRACT_V1.md') -Destination (Join-Path $docsDirectory 'WINDOWS_SLICE_BUILD_CONTRACT_V1.md') -Force
    Copy-Item -Path (Join-Path $projectRoot 'docs_tmp\WINDOWS_PORT_EXECUTION_PLAN_V1.md') -Destination (Join-Path $docsDirectory 'WINDOWS_PORT_EXECUTION_PLAN_V1.md') -Force
    Copy-Item -Path (Join-Path $projectRoot 'docs_tmp\WINDOWS_CLEAN_MACHINE_BOOTSTRAP_V1.md') -Destination (Join-Path $docsDirectory 'WINDOWS_CLEAN_MACHINE_BOOTSTRAP_V1.md') -Force
    Copy-Item -Path (Join-Path $projectRoot 'docs_tmp\WINDOWS_LANE_OPERATOR_QUICKSTART_V1.md') -Destination (Join-Path $docsDirectory 'WINDOWS_LANE_OPERATOR_QUICKSTART_V1.md') -Force
    Copy-Item -Path (Join-Path $projectRoot 'docs_tmp\HANDOFF_V1.md') -Destination (Join-Path $docsDirectory 'HANDOFF_V1.md') -Force
    Copy-Item -Path (Join-Path $PSScriptRoot 'windows-slice-package-lock.ps1') -Destination (Join-Path $toolsDirectory 'windows-slice-package-lock.ps1') -Force
    Copy-Item -Path (Join-Path $PSScriptRoot 'test-windows-slice.ps1') -Destination (Join-Path $toolsDirectory 'test-windows-slice.ps1') -Force
    Copy-Item -Path (Join-Path $PSScriptRoot 'test-windows-notification.ps1') -Destination (Join-Path $toolsDirectory 'test-windows-notification.ps1') -Force
    Copy-Item -Path (Join-Path $PSScriptRoot 'test-windows-all.ps1') -Destination (Join-Path $toolsDirectory 'test-windows-all.ps1') -Force
    Copy-Item -Path (Join-Path $PSScriptRoot 'test-windows-shell-host-crash-recovery.ps1') -Destination (Join-Path $toolsDirectory 'test-windows-shell-host-crash-recovery.ps1') -Force
    Copy-Item -Path (Join-Path $PSScriptRoot 'test-windows-shell-host-crash-retention.ps1') -Destination (Join-Path $toolsDirectory 'test-windows-shell-host-crash-retention.ps1') -Force
    Copy-Item -Path (Join-Path $PSScriptRoot 'test-windows-shell-host-crash-soak.ps1') -Destination (Join-Path $toolsDirectory 'test-windows-shell-host-crash-soak.ps1') -Force
    Copy-Item -Path (Join-Path $PSScriptRoot 'run-windows-lane-ci.ps1') -Destination (Join-Path $toolsDirectory 'run-windows-lane-ci.ps1') -Force
    Copy-Item -Path (Join-Path $PSScriptRoot 'export-windows-lane-triage-bundle.ps1') -Destination (Join-Path $toolsDirectory 'export-windows-lane-triage-bundle.ps1') -Force
    Copy-Item -Path (Join-Path $PSScriptRoot 'build-windows-release.ps1') -Destination (Join-Path $toolsDirectory 'build-windows-release.ps1') -Force

    $readme = @"
cmux Windows lane package

Release label: $resolvedReleaseLabel
Version: $resolvedVersionLabel

Layout:
- bin\\cmux-windows-slice.exe
- bin\\ghostty.exe
- bin\\libghostty.so
- bin\\cmux_windows_webview2_spike.exe
- bin\\cmux_windows_webview2_child_host.exe
- bin\\cmux_windows_shell_host_spike.exe
- tools\\windows-slice-package-lock.ps1
- tools\\test-windows-all.ps1
- tools\\test-windows-shell-host-crash-recovery.ps1
- tools\\test-windows-shell-host-crash-retention.ps1
- tools\\test-windows-shell-host-crash-soak.ps1
- tools\\run-windows-lane-ci.ps1
- tools\\export-windows-lane-triage-bundle.ps1
- tools\\build-windows-release.ps1
- resources\\ghostty\\
- artifacts\\
- logs\\
- docs\\

Recommended validation command:
  powershell -ExecutionPolicy Bypass -File .\\tools\\run-windows-lane-ci.ps1 -InstallRoot '$OutputRoot'

Operator quickstart:
  docs\\WINDOWS_LANE_OPERATOR_QUICKSTART_V1.md

Primary diagnostics:
  logs\\windows-lane-ci.log
  artifacts\\latest\\package-ci-verdict.json
  artifacts\\latest\\package-ci-summary.json
  artifacts\\latest\\crash-triage-summary.json
  artifacts\\latest\\triage-bundle-summary.json
  artifacts\\latest\\windows-lane-triage-latest.zip
  artifacts\\latest\\latest-run.txt
  artifacts\\r\\<run-id>\\smoke-verdict.json
  artifacts\\r\\<run-id>\\slice\\*\\ghostty-bridge-reports.json
"@

    Set-Content -Path (Join-Path $OutputRoot 'README.txt') -Value $readme -Encoding UTF8

    $runtimePrerequisites = @"
cmux Windows lane runtime prerequisites

- Windows host with OpenGL-capable graphics stack for the current Ghostty debug build
- No repo-relative paths are required at runtime; the packaged lane expects:
  - .\bin\cmux-windows-slice.exe
  - .\bin\ghostty.exe
  - .\bin\cmux_windows_webview2_spike.exe
  - .\bin\cmux_windows_webview2_child_host.exe
  - .\bin\cmux_windows_shell_host_spike.exe
  - .\resources\ghostty\
- Validation entrypoint:
  powershell -ExecutionPolicy Bypass -File .\tools\run-windows-lane-ci.ps1 -InstallRoot '$OutputRoot'
- Validation artifacts:
  - .\artifacts\r\<run-id>\
  - .\artifacts\latest\
  - .\logs\windows-lane-ci.log
- Crash triage summary:
  - .\artifacts\latest\crash-triage-summary.json
- Crash triage bundle:
  - .\artifacts\latest\triage-bundle-summary.json
  - .\artifacts\latest\windows-lane-triage-latest.zip
- Ghostty bridge diagnostics:
  - .\artifacts\r\<run-id>\slice\*\ghostty-bridge-reports.json
  - .\artifacts\r\<run-id>\slice\*\ghostty-session-*-stdout.log
  - .\artifacts\r\<run-id>\slice\*\ghostty-session-*-stderr.log
- Mixed shell-host diagnostics:
  - .\artifacts\r\<run-id>\slice\mixed-shell-host\shell-host-preview.txt
  - .\artifacts\r\<run-id>\slice\mixed-shell-host\captured-artifacts.json
  - .\artifacts\r\<run-id>\slice\mixed-shell-host\captured-runtime\
- Clean-machine build/bootstrap instructions:
  - .\docs\WINDOWS_CLEAN_MACHINE_BOOTSTRAP_V1.md
- Operator runbook:
  - .\docs\WINDOWS_LANE_OPERATOR_QUICKSTART_V1.md
"@

    Set-Content -Path (Join-Path $docsDirectory 'RUNTIME_PREREQUISITES.txt') -Value $runtimePrerequisites -Encoding UTF8

    $ghosttyVersionLine = Get-GhosttyVersionLine -ExecutablePath (Join-Path $binDirectory 'ghostty.exe')
    if ([string]::IsNullOrWhiteSpace($ghosttyVersionLine)) {
        $ghosttyVersionLine = 'unavailable_from_binary_probe'
    }

    $buildInfo = [pscustomobject]@{
        packagedAt = $buildTimestamp.ToString('o')
        version = $resolvedVersionLabel
        releaseLabel = $resolvedReleaseLabel
        outputRoot = (Resolve-Path $OutputRoot).Path
        sliceExecutable = (Resolve-Path $sliceExe).Path
        ghosttyExecutable = (Resolve-Path (Join-Path $binDirectory 'ghostty.exe')).Path
        cmuxRevision = $cmuxRevision
        ghosttyRevision = $ghosttyRevision
        ghosttyVersionLine = $ghosttyVersionLine
        artifactName = "$resolvedReleaseLabel.zip"
        canonicalReleaseCommand = "powershell -ExecutionPolicy Bypass -File .\\cmux\\scripts\\build-windows-release.ps1 -VersionLabel '$resolvedVersionLabel'"
        docs = @(
            'docs\\WINDOWS_SLICE_BUILD_CONTRACT_V1.md',
            'docs\\WINDOWS_PORT_EXECUTION_PLAN_V1.md',
            'docs\\WINDOWS_CLEAN_MACHINE_BOOTSTRAP_V1.md',
            'docs\\WINDOWS_LANE_OPERATOR_QUICKSTART_V1.md',
            'docs\\HANDOFF_V1.md',
            'docs\\RUNTIME_PREREQUISITES.txt'
        )
        tools = @(
            'tools\\windows-slice-package-lock.ps1',
            'tools\\test-windows-slice.ps1',
            'tools\\test-windows-notification.ps1',
            'tools\\test-windows-all.ps1',
            'tools\\test-windows-shell-host-crash-recovery.ps1',
            'tools\\test-windows-shell-host-crash-retention.ps1',
            'tools\\test-windows-shell-host-crash-soak.ps1',
            'tools\\run-windows-lane-ci.ps1',
            'tools\\export-windows-lane-triage-bundle.ps1',
            'tools\\build-windows-release.ps1'
        )
        runtimeAssets = @(
            'bin\\ghostty.exe',
            'bin\\libghostty.so',
            'bin\\cmux_windows_webview2_spike.exe',
            'bin\\cmux_windows_webview2_child_host.exe',
            'bin\\cmux_windows_shell_host_spike.exe',
            'resources\\ghostty'
        )
        artifactRootPattern = 'artifacts\\r\\<run-id>'
        latestArtifactPointerRoot = 'artifacts\\latest'
        logPath = 'logs\\windows-lane-ci.log'
        crashTriageSummaryPath = 'artifacts\\latest\\crash-triage-summary.json'
        triageBundleSummaryPath = 'artifacts\\latest\\triage-bundle-summary.json'
        triageBundlePath = 'artifacts\\latest\\windows-lane-triage-latest.zip'
        ghosttyLogPattern = 'artifacts\\r\\<run-id>\\slice\\*\\ghostty-session-*-stdout.log / *-stderr.log'
        ghosttyBridgeReportPattern = 'artifacts\\r\\<run-id>\\slice\\*\\ghostty-bridge-reports.json'
        shellHostArtifactPattern = 'artifacts\\r\\<run-id>\\slice\\mixed-shell-host\\captured-runtime\\*'
    }

    $buildInfo | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $OutputRoot 'build-info.json') -Encoding UTF8
}

Write-Host "Packaged Windows lane at $OutputRoot"
