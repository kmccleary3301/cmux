param(
    [string]$InstallRoot = $(Resolve-Path (Join-Path $PSScriptRoot '..')),
    [string]$RootArtifactDirectory = '',
    [string]$OutputDirectory = '',
    [string]$BundleLabel = ''
)

$ErrorActionPreference = 'Stop'

$resolvedInstallRoot = (Resolve-Path $InstallRoot -ErrorAction Stop).Path
$latestArtifactDirectory = Join-Path $resolvedInstallRoot 'artifacts\latest'

if ([string]::IsNullOrWhiteSpace($RootArtifactDirectory)) {
    $latestRunPointerPath = Join-Path $latestArtifactDirectory 'latest-run.txt'
    if (-not (Test-Path $latestRunPointerPath)) {
        throw "Latest run pointer not found at $latestRunPointerPath"
    }
    $RootArtifactDirectory = (Get-Content -Path $latestRunPointerPath -Raw).Trim()
}

$resolvedRootArtifactDirectory = (Resolve-Path $RootArtifactDirectory -ErrorAction Stop).Path
$resolvedOutputDirectory = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $latestArtifactDirectory
} else {
    (Resolve-Path $OutputDirectory -ErrorAction Stop).Path
}

New-Item -ItemType Directory -Force -Path $resolvedOutputDirectory | Out-Null

$runId = Split-Path -Leaf $resolvedRootArtifactDirectory
$resolvedBundleLabel = if ([string]::IsNullOrWhiteSpace($BundleLabel)) {
    "windows-lane-triage-$runId"
} else {
    $BundleLabel.Trim()
}

$timestamp = Get-Date -Format 'yyyyMMddHHmmss'
$stagingRoot = Join-Path $env:TEMP ("cmux-windows-lane-triage-staging-" + [guid]::NewGuid().Guid)
$bundleRoot = Join-Path $stagingRoot $resolvedBundleLabel
New-Item -ItemType Directory -Force -Path $bundleRoot | Out-Null

function Copy-IfPresent {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )

    if (-not (Test-Path $SourcePath)) { return $false }
    $destinationParent = Split-Path -Parent $DestinationPath
    if (-not [string]::IsNullOrWhiteSpace($destinationParent)) {
        New-Item -ItemType Directory -Force -Path $destinationParent | Out-Null
    }
    Copy-Item -Path $SourcePath -Destination $DestinationPath -Recurse -Force
    return $true
}

$copiedEntries = New-Object System.Collections.Generic.List[object]
$missingEntries = New-Object System.Collections.Generic.List[object]

function Record-CopyResult {
    param(
        [string]$Id,
        [string]$SourcePath,
        [string]$RelativeDestination
    )

    $destinationPath = Join-Path $bundleRoot $RelativeDestination
    if (Copy-IfPresent -SourcePath $SourcePath -DestinationPath $destinationPath) {
        $copiedEntries.Add([pscustomobject]@{
            id = $Id
            sourcePath = $SourcePath
            relativeDestination = $RelativeDestination
        })
    } else {
        $missingEntries.Add([pscustomobject]@{
            id = $Id
            sourcePath = $SourcePath
            relativeDestination = $RelativeDestination
        })
    }
}

Record-CopyResult -Id 'build-info' -SourcePath (Join-Path $resolvedInstallRoot 'build-info.json') -RelativeDestination 'build-info.json'
Record-CopyResult -Id 'package-readme' -SourcePath (Join-Path $resolvedInstallRoot 'README.txt') -RelativeDestination 'README.txt'
Record-CopyResult -Id 'operator-quickstart' -SourcePath (Join-Path $resolvedInstallRoot 'docs\WINDOWS_LANE_OPERATOR_QUICKSTART_V1.md') -RelativeDestination 'docs\WINDOWS_LANE_OPERATOR_QUICKSTART_V1.md'
Record-CopyResult -Id 'runtime-prerequisites' -SourcePath (Join-Path $resolvedInstallRoot 'docs\RUNTIME_PREREQUISITES.txt') -RelativeDestination 'docs\RUNTIME_PREREQUISITES.txt'
Record-CopyResult -Id 'ci-log' -SourcePath (Join-Path $resolvedInstallRoot 'logs\windows-lane-ci.log') -RelativeDestination 'logs\windows-lane-ci.log'
Record-CopyResult -Id 'package-ci-summary' -SourcePath (Join-Path $latestArtifactDirectory 'package-ci-summary.json') -RelativeDestination 'artifacts\latest\package-ci-summary.json'
Record-CopyResult -Id 'package-ci-verdict' -SourcePath (Join-Path $latestArtifactDirectory 'package-ci-verdict.json') -RelativeDestination 'artifacts\latest\package-ci-verdict.json'
Record-CopyResult -Id 'crash-triage-summary' -SourcePath (Join-Path $latestArtifactDirectory 'crash-triage-summary.json') -RelativeDestination 'artifacts\latest\crash-triage-summary.json'
Record-CopyResult -Id 'latest-run-pointer' -SourcePath (Join-Path $latestArtifactDirectory 'latest-run.txt') -RelativeDestination 'artifacts\latest\latest-run.txt'
Record-CopyResult -Id 'root-artifact-directory' -SourcePath $resolvedRootArtifactDirectory -RelativeDestination ('artifacts\r\' + $runId)

$manifest = [pscustomobject]@{
    bundleLabel = $resolvedBundleLabel
    generatedAt = (Get-Date).ToString('o')
    installRoot = $resolvedInstallRoot
    rootArtifactDirectory = $resolvedRootArtifactDirectory
    copiedEntries = @($copiedEntries.ToArray())
    missingEntries = @($missingEntries.ToArray())
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $bundleRoot 'triage-bundle-manifest.json') -Encoding UTF8

$versionedBundlePath = Join-Path $resolvedOutputDirectory ($resolvedBundleLabel + '-' + $timestamp + '.zip')
$latestBundlePath = Join-Path $resolvedOutputDirectory 'windows-lane-triage-latest.zip'

Remove-Item -Force $versionedBundlePath -ErrorAction SilentlyContinue
Remove-Item -Force $latestBundlePath -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $bundleRoot '*') -DestinationPath $versionedBundlePath -Force
Copy-Item -Path $versionedBundlePath -Destination $latestBundlePath -Force

$summary = [pscustomobject]@{
    bundleLabel = $resolvedBundleLabel
    generatedAt = (Get-Date).ToString('o')
    installRoot = $resolvedInstallRoot
    rootArtifactDirectory = $resolvedRootArtifactDirectory
    versionedBundlePath = $versionedBundlePath
    latestBundlePath = $latestBundlePath
    manifestPath = Join-Path $bundleRoot 'triage-bundle-manifest.json'
}
$summary | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $resolvedOutputDirectory 'triage-bundle-summary.json') -Encoding UTF8

Remove-Item -Recurse -Force $stagingRoot -ErrorAction SilentlyContinue

Write-Host "Exported Windows lane triage bundle: $versionedBundlePath"
Write-Host $latestBundlePath
