param(
    [string]$PackageRoot = $(Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')) 'WindowsSlicePackage')
)

$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
. (Join-Path $PSScriptRoot 'windows-slice-package-lock.ps1')
$manifestPath = Join-Path $PSScriptRoot 'windows-slice-sources.txt'
if (-not (Test-Path $manifestPath)) {
    throw "Windows slice source manifest not found: $manifestPath"
}

Invoke-CmuxWindowsSlicePackageLocked {
    if (-not (Test-Path $PackageRoot)) {
        New-Item -ItemType Directory -Force -Path $PackageRoot | Out-Null
    }

    $targetRoot = Join-Path $PackageRoot 'Sources\WindowsSliceApp'
    if (Test-Path $targetRoot) {
        Remove-Item -LiteralPath $targetRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null

    $sourceFiles = Get-Content -Path $manifestPath | Where-Object {
        $trimmed = $_.Trim()
        $trimmed -and -not $trimmed.StartsWith('#')
    }

    foreach ($relativeSource in $sourceFiles) {
        $sourcePath = Join-Path $repoRoot $relativeSource
        if (-not (Test-Path $sourcePath)) {
            throw "Listed source file does not exist: $relativeSource"
        }

        $relativeTargetPath = $relativeSource -replace '^Sources[\\/]', ''
        $targetPath = Join-Path $targetRoot $relativeTargetPath
        $targetDirectory = Split-Path -Parent $targetPath
        New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
        Copy-Item -Path $sourcePath -Destination $targetPath -Force
    }

$packageManifest = @'
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WindowsSlicePackage",
    products: [
        .executable(name: "cmux-windows-slice", targets: ["WindowsSliceApp"])
    ],
    targets: [
        .executableTarget(
            name: "WindowsSliceApp",
            path: "Sources/WindowsSliceApp"
        )
    ]
)
'@

$readme = @'
# Windows Slice Package

This directory is the formal SwiftPM build boundary for the Windows-safe cmux slice.

It is generated from `cmux/scripts/windows-slice-sources.txt` by:

```powershell
.\cmux\scripts\sync-windows-slice-package.ps1
```

Build it with:

```powershell
.\cmux\scripts\build-windows-slice-package.ps1
```
'@

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $PackageRoot 'Package.swift'), $packageManifest, $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $PackageRoot 'README.md'), $readme, $utf8NoBom)
    Copy-Item -Path $manifestPath -Destination (Join-Path $PackageRoot 'windows-slice-sources.txt') -Force
}

Write-Host "Synchronized Windows slice package at $PackageRoot"
