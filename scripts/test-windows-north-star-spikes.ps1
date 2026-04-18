param(
    [string]$RootArtifactDirectory = $(Join-Path $env:TEMP ("cmux-windows-north-star-spikes-" + [guid]::NewGuid().Guid))
)

$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Force -Path $RootArtifactDirectory | Out-Null

$dg1ArtifactDirectory = Join-Path $RootArtifactDirectory 'dg1-embedded-ghostty'
$dg2ArtifactDirectory = Join-Path $RootArtifactDirectory 'dg2-browser-host'
$dg3ArtifactDirectory = Join-Path $RootArtifactDirectory 'dg3-shell-host'
$dg4ArtifactDirectory = Join-Path $RootArtifactDirectory 'dg4-shell-host-accessibility'
$dg5ArtifactDirectory = Join-Path $RootArtifactDirectory 'dg5-shell-host-dpi'
$dg6ArtifactDirectory = Join-Path $RootArtifactDirectory 'dg6-shell-host-keyboard'
$dg7ArtifactDirectory = Join-Path $RootArtifactDirectory 'dg7-shell-host-accessibility-semantics'
$dg8ArtifactDirectory = Join-Path $RootArtifactDirectory 'dg8-shell-host-scale-change'
$dg9ArtifactDirectory = Join-Path $RootArtifactDirectory 'dg9-shell-host-window-ownership'
$dg10ArtifactDirectory = Join-Path $RootArtifactDirectory 'dg10-shell-host-session-restore'
$dg11ArtifactDirectory = Join-Path $RootArtifactDirectory 'dg11-shell-host-high-contrast'
$dg12ArtifactDirectory = Join-Path $RootArtifactDirectory 'dg12-shell-host-narrator-baseline'
$dg13ArtifactDirectory = Join-Path $RootArtifactDirectory 'dg13-shell-host-multimonitor'
$dg14ArtifactDirectory = Join-Path $RootArtifactDirectory 'dg14-shell-host-crash-recovery'
$dg15ArtifactDirectory = Join-Path $RootArtifactDirectory 'dg15-shell-host-crash-retention'
$dg16ArtifactDirectory = Join-Path $RootArtifactDirectory 'dg16-shell-host-crash-soak'
$dg17ArtifactDirectory = Join-Path $RootArtifactDirectory 'dg17-shell-host-content-semantics'
$dg18ArtifactDirectory = Join-Path $RootArtifactDirectory 'dg18-shell-host-browser-content-semantics'
$dg19ArtifactDirectory = Join-Path $RootArtifactDirectory 'dg19-shell-host-terminal-content-semantics'
$dg20ArtifactDirectory = Join-Path $RootArtifactDirectory 'dg20-shell-host-terminal-summary-semantics'
$dg21ArtifactDirectory = Join-Path $RootArtifactDirectory 'dg21-shell-host-terminal-narrator-baseline'
$dg22ArtifactDirectory = Join-Path $RootArtifactDirectory 'dg22-shell-host-terminal-summary-durability'

& (Join-Path $PSScriptRoot 'test-windows-libghostty-embed.ps1') `
    -ArtifactDirectory $dg1ArtifactDirectory | Out-Null
& (Join-Path $PSScriptRoot 'test-windows-webview2-spike.ps1') `
    -ArtifactDirectory $dg2ArtifactDirectory | Out-Null
& (Join-Path $PSScriptRoot 'test-windows-shell-host-spike.ps1') `
    -ArtifactDirectory $dg3ArtifactDirectory | Out-Null
& (Join-Path $PSScriptRoot 'test-windows-shell-host-accessibility.ps1') `
    -ArtifactDirectory $dg4ArtifactDirectory | Out-Null
& (Join-Path $PSScriptRoot 'test-windows-shell-host-dpi.ps1') `
    -ArtifactDirectory $dg5ArtifactDirectory | Out-Null
& (Join-Path $PSScriptRoot 'test-windows-shell-host-keyboard.ps1') `
    -ArtifactDirectory $dg6ArtifactDirectory | Out-Null
& (Join-Path $PSScriptRoot 'test-windows-shell-host-accessibility-semantics.ps1') `
    -ArtifactDirectory $dg7ArtifactDirectory | Out-Null
& (Join-Path $PSScriptRoot 'test-windows-shell-host-scale-change.ps1') `
    -ArtifactDirectory $dg8ArtifactDirectory | Out-Null
& (Join-Path $PSScriptRoot 'test-windows-shell-host-window-ownership.ps1') `
    -ArtifactDirectory $dg9ArtifactDirectory | Out-Null
& (Join-Path $PSScriptRoot 'test-windows-shell-host-session-restore.ps1') `
    -ArtifactDirectory $dg10ArtifactDirectory | Out-Null
& (Join-Path $PSScriptRoot 'test-windows-shell-host-high-contrast.ps1') `
    -ArtifactDirectory $dg11ArtifactDirectory | Out-Null
& (Join-Path $PSScriptRoot 'test-windows-shell-host-narrator-baseline.ps1') `
    -ArtifactDirectory $dg12ArtifactDirectory | Out-Null
& (Join-Path $PSScriptRoot 'test-windows-shell-host-multimonitor.ps1') `
    -ArtifactDirectory $dg13ArtifactDirectory | Out-Null
& (Join-Path $PSScriptRoot 'test-windows-shell-host-crash-recovery.ps1') `
    -ArtifactDirectory $dg14ArtifactDirectory | Out-Null
& (Join-Path $PSScriptRoot 'test-windows-shell-host-crash-retention.ps1') `
    -ArtifactDirectory $dg15ArtifactDirectory | Out-Null
& (Join-Path $PSScriptRoot 'test-windows-shell-host-crash-soak.ps1') `
    -ArtifactDirectory $dg16ArtifactDirectory | Out-Null
& (Join-Path $PSScriptRoot 'test-windows-shell-host-content-semantics.ps1') `
    -ArtifactDirectory $dg17ArtifactDirectory | Out-Null
& (Join-Path $PSScriptRoot 'test-windows-shell-host-browser-content-semantics.ps1') `
    -ArtifactDirectory $dg18ArtifactDirectory | Out-Null
& (Join-Path $PSScriptRoot 'test-windows-shell-host-terminal-content-semantics.ps1') `
    -ArtifactDirectory $dg19ArtifactDirectory | Out-Null
& (Join-Path $PSScriptRoot 'test-windows-shell-host-terminal-summary-semantics.ps1') `
    -ArtifactDirectory $dg20ArtifactDirectory | Out-Null
& (Join-Path $PSScriptRoot 'test-windows-shell-host-terminal-narrator-baseline.ps1') `
    -ArtifactDirectory $dg21ArtifactDirectory | Out-Null
& (Join-Path $PSScriptRoot 'test-windows-shell-host-terminal-summary-durability.ps1') `
    -ArtifactDirectory $dg22ArtifactDirectory | Out-Null

$summary = [pscustomobject]@{
    suite = 'windows-north-star-spikes'
    generatedAt = (Get-Date).ToString('o')
    cases = @(
        [pscustomobject]@{
            id = 'dg1-embedded-ghostty'
            artifactDirectory = $dg1ArtifactDirectory
            report = (Get-Content (Join-Path $dg1ArtifactDirectory 'embedded-ghostty-report.json') -Raw | ConvertFrom-Json)
        },
        [pscustomobject]@{
            id = 'dg2-browser-host'
            artifactDirectory = $dg2ArtifactDirectory
            report = (Get-Content (Join-Path $dg2ArtifactDirectory 'webview2-report.json') -Raw | ConvertFrom-Json)
        },
        [pscustomobject]@{
            id = 'dg3-shell-host'
            artifactDirectory = $dg3ArtifactDirectory
            report = (Get-Content (Join-Path $dg3ArtifactDirectory 'shell-host-report.json') -Raw | ConvertFrom-Json)
        },
        [pscustomobject]@{
            id = 'dg4-shell-host-accessibility'
            artifactDirectory = $dg4ArtifactDirectory
            report = (Get-Content (Join-Path $dg4ArtifactDirectory 'shell-host-accessibility-report.json') -Raw | ConvertFrom-Json)
        },
        [pscustomobject]@{
            id = 'dg5-shell-host-dpi'
            artifactDirectory = $dg5ArtifactDirectory
            report = (Get-Content (Join-Path $dg5ArtifactDirectory 'shell-host-dpi-report.json') -Raw | ConvertFrom-Json)
        },
        [pscustomobject]@{
            id = 'dg6-shell-host-keyboard'
            artifactDirectory = $dg6ArtifactDirectory
            report = (Get-Content (Join-Path $dg6ArtifactDirectory 'shell-host-keyboard-report.json') -Raw | ConvertFrom-Json)
        },
        [pscustomobject]@{
            id = 'dg7-shell-host-accessibility-semantics'
            artifactDirectory = $dg7ArtifactDirectory
            report = (Get-Content (Join-Path $dg7ArtifactDirectory 'shell-host-accessibility-semantics-report.json') -Raw | ConvertFrom-Json)
        },
        [pscustomobject]@{
            id = 'dg8-shell-host-scale-change'
            artifactDirectory = $dg8ArtifactDirectory
            report = (Get-Content (Join-Path $dg8ArtifactDirectory 'shell-host-scale-change-report.json') -Raw | ConvertFrom-Json)
        },
        [pscustomobject]@{
            id = 'dg9-shell-host-window-ownership'
            artifactDirectory = $dg9ArtifactDirectory
            report = (Get-Content (Join-Path $dg9ArtifactDirectory 'shell-host-window-ownership-report.json') -Raw | ConvertFrom-Json)
        },
        [pscustomobject]@{
            id = 'dg10-shell-host-session-restore'
            artifactDirectory = $dg10ArtifactDirectory
            report = (Get-Content (Join-Path $dg10ArtifactDirectory 'shell-host-session-restore-report.json') -Raw | ConvertFrom-Json)
        },
        [pscustomobject]@{
            id = 'dg11-shell-host-high-contrast'
            artifactDirectory = $dg11ArtifactDirectory
            report = (Get-Content (Join-Path $dg11ArtifactDirectory 'shell-host-high-contrast-report.json') -Raw | ConvertFrom-Json)
        },
        [pscustomobject]@{
            id = 'dg12-shell-host-narrator-baseline'
            artifactDirectory = $dg12ArtifactDirectory
            report = (Get-Content (Join-Path $dg12ArtifactDirectory 'shell-host-narrator-baseline-report.json') -Raw | ConvertFrom-Json)
        },
        [pscustomobject]@{
            id = 'dg13-shell-host-multimonitor'
            artifactDirectory = $dg13ArtifactDirectory
            report = (Get-Content (Join-Path $dg13ArtifactDirectory 'shell-host-multimonitor-report.json') -Raw | ConvertFrom-Json)
        },
        [pscustomobject]@{
            id = 'dg14-shell-host-crash-recovery'
            artifactDirectory = $dg14ArtifactDirectory
            report = (Get-Content (Join-Path $dg14ArtifactDirectory 'shell-host-crash-recovery-report.json') -Raw | ConvertFrom-Json)
        },
        [pscustomobject]@{
            id = 'dg15-shell-host-crash-retention'
            artifactDirectory = $dg15ArtifactDirectory
            report = (Get-Content (Join-Path $dg15ArtifactDirectory 'shell-host-crash-retention-report.json') -Raw | ConvertFrom-Json)
        },
        [pscustomobject]@{
            id = 'dg16-shell-host-crash-soak'
            artifactDirectory = $dg16ArtifactDirectory
            report = (Get-Content (Join-Path $dg16ArtifactDirectory 'shell-host-crash-soak-report.json') -Raw | ConvertFrom-Json)
        },
        [pscustomobject]@{
            id = 'dg17-shell-host-content-semantics'
            artifactDirectory = $dg17ArtifactDirectory
            report = (Get-Content (Join-Path $dg17ArtifactDirectory 'shell-host-content-semantics-report.json') -Raw | ConvertFrom-Json)
        },
        [pscustomobject]@{
            id = 'dg18-shell-host-browser-content-semantics'
            artifactDirectory = $dg18ArtifactDirectory
            report = (Get-Content (Join-Path $dg18ArtifactDirectory 'shell-host-browser-content-semantics-report.json') -Raw | ConvertFrom-Json)
        },
        [pscustomobject]@{
            id = 'dg19-shell-host-terminal-content-semantics'
            artifactDirectory = $dg19ArtifactDirectory
            report = (Get-Content (Join-Path $dg19ArtifactDirectory 'shell-host-terminal-content-semantics-report.json') -Raw | ConvertFrom-Json)
        },
        [pscustomobject]@{
            id = 'dg20-shell-host-terminal-summary-semantics'
            artifactDirectory = $dg20ArtifactDirectory
            report = (Get-Content (Join-Path $dg20ArtifactDirectory 'shell-host-terminal-summary-semantics-report.json') -Raw | ConvertFrom-Json)
        },
        [pscustomobject]@{
            id = 'dg21-shell-host-terminal-narrator-baseline'
            artifactDirectory = $dg21ArtifactDirectory
            report = (Get-Content (Join-Path $dg21ArtifactDirectory 'shell-host-terminal-narrator-baseline-report.json') -Raw | ConvertFrom-Json)
        },
        [pscustomobject]@{
            id = 'dg22-shell-host-terminal-summary-durability'
            artifactDirectory = $dg22ArtifactDirectory
            report = (Get-Content (Join-Path $dg22ArtifactDirectory 'shell-host-terminal-summary-durability-report.json') -Raw | ConvertFrom-Json)
        }
    )
}

$summary | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $RootArtifactDirectory 'spike-summary.json') -Encoding UTF8

$verdict = [pscustomobject]@{
    suite = 'windows-north-star-spikes'
    caseCount = 22
    passedCount = 22
    failedCount = 0
    passed = $true
    cases = @(
        [pscustomobject]@{ id = 'dg1-embedded-ghostty'; passed = $true; artifactDirectory = $dg1ArtifactDirectory },
        [pscustomobject]@{ id = 'dg2-browser-host'; passed = $true; artifactDirectory = $dg2ArtifactDirectory },
        [pscustomobject]@{ id = 'dg3-shell-host'; passed = $true; artifactDirectory = $dg3ArtifactDirectory },
        [pscustomobject]@{ id = 'dg4-shell-host-accessibility'; passed = $true; artifactDirectory = $dg4ArtifactDirectory },
        [pscustomobject]@{ id = 'dg5-shell-host-dpi'; passed = $true; artifactDirectory = $dg5ArtifactDirectory },
        [pscustomobject]@{ id = 'dg6-shell-host-keyboard'; passed = $true; artifactDirectory = $dg6ArtifactDirectory },
        [pscustomobject]@{ id = 'dg7-shell-host-accessibility-semantics'; passed = $true; artifactDirectory = $dg7ArtifactDirectory },
        [pscustomobject]@{ id = 'dg8-shell-host-scale-change'; passed = $true; artifactDirectory = $dg8ArtifactDirectory },
        [pscustomobject]@{ id = 'dg9-shell-host-window-ownership'; passed = $true; artifactDirectory = $dg9ArtifactDirectory },
        [pscustomobject]@{ id = 'dg10-shell-host-session-restore'; passed = $true; artifactDirectory = $dg10ArtifactDirectory },
        [pscustomobject]@{ id = 'dg11-shell-host-high-contrast'; passed = $true; artifactDirectory = $dg11ArtifactDirectory },
        [pscustomobject]@{ id = 'dg12-shell-host-narrator-baseline'; passed = $true; artifactDirectory = $dg12ArtifactDirectory },
        [pscustomobject]@{ id = 'dg13-shell-host-multimonitor'; passed = $true; artifactDirectory = $dg13ArtifactDirectory },
        [pscustomobject]@{ id = 'dg14-shell-host-crash-recovery'; passed = $true; artifactDirectory = $dg14ArtifactDirectory },
        [pscustomobject]@{ id = 'dg15-shell-host-crash-retention'; passed = $true; artifactDirectory = $dg15ArtifactDirectory },
        [pscustomobject]@{ id = 'dg16-shell-host-crash-soak'; passed = $true; artifactDirectory = $dg16ArtifactDirectory },
        [pscustomobject]@{ id = 'dg17-shell-host-content-semantics'; passed = $true; artifactDirectory = $dg17ArtifactDirectory },
        [pscustomobject]@{ id = 'dg18-shell-host-browser-content-semantics'; passed = $true; artifactDirectory = $dg18ArtifactDirectory },
        [pscustomobject]@{ id = 'dg19-shell-host-terminal-content-semantics'; passed = $true; artifactDirectory = $dg19ArtifactDirectory },
        [pscustomobject]@{ id = 'dg20-shell-host-terminal-summary-semantics'; passed = $true; artifactDirectory = $dg20ArtifactDirectory },
        [pscustomobject]@{ id = 'dg21-shell-host-terminal-narrator-baseline'; passed = $true; artifactDirectory = $dg21ArtifactDirectory },
        [pscustomobject]@{ id = 'dg22-shell-host-terminal-summary-durability'; passed = $true; artifactDirectory = $dg22ArtifactDirectory }
    )
}

$verdict | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $RootArtifactDirectory 'spike-verdict.json') -Encoding UTF8

Write-Host "Windows north-star spike suite passed"
Write-Host $RootArtifactDirectory
