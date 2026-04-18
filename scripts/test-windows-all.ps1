param(
    [string]$RootArtifactDirectory = $(Join-Path $env:TEMP ("cmux-windows-all-artifacts-" + [guid]::NewGuid().Guid)),
    [string]$SliceExecutablePath = ''
)

$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Force -Path $RootArtifactDirectory | Out-Null

$sliceArtifactDirectory = Join-Path $RootArtifactDirectory 'slice'
$notificationArtifactDirectory = Join-Path $RootArtifactDirectory 'notification'

& (Join-Path $PSScriptRoot 'test-windows-slice.ps1') `
    -ArtifactDirectory $sliceArtifactDirectory `
    -SliceExecutablePath $SliceExecutablePath
& (Join-Path $PSScriptRoot 'test-windows-notification.ps1') `
    -ArtifactDirectory $notificationArtifactDirectory `
    -SliceExecutablePath $SliceExecutablePath

$combinedSummary = [pscustomobject]@{
    suites = @(
        (Get-Content (Join-Path $sliceArtifactDirectory 'smoke-summary.json') -Raw | ConvertFrom-Json),
        (Get-Content (Join-Path $notificationArtifactDirectory 'smoke-summary.json') -Raw | ConvertFrom-Json)
    )
}

$combinedSummary | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $RootArtifactDirectory 'smoke-summary.json') -Encoding UTF8

$suiteVerdicts = @(
    (Get-Content (Join-Path $sliceArtifactDirectory 'smoke-verdict.json') -Raw | ConvertFrom-Json),
    (Get-Content (Join-Path $notificationArtifactDirectory 'smoke-verdict.json') -Raw | ConvertFrom-Json)
)

$combinedVerdict = [pscustomobject]@{
    suite = 'windows-all'
    suiteCount = $suiteVerdicts.Count
    caseCount = (@($suiteVerdicts | ForEach-Object { $_.caseCount } | Measure-Object -Sum).Sum)
    passedCount = (@($suiteVerdicts | ForEach-Object { $_.passedCount } | Measure-Object -Sum).Sum)
    failedCount = (@($suiteVerdicts | ForEach-Object { $_.failedCount } | Measure-Object -Sum).Sum)
    passed = (-not ($suiteVerdicts | Where-Object { -not $_.passed }))
    suites = $suiteVerdicts
}

$combinedVerdict | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $RootArtifactDirectory 'smoke-verdict.json') -Encoding UTF8

Write-Host "Windows smoke suite passed"
Write-Host $RootArtifactDirectory
