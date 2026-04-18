param(
    [string]$OutputPath = $(Join-Path $env:TEMP ("cmux_windows_webview2_child_host_" + [guid]::NewGuid().Guid + '.exe')),
    [string]$SwiftRoot = $env:CMUX_SWIFT_ROOT,
    [string]$SwiftVersion = $env:CMUX_SWIFT_VERSION,
    [string]$MsvcVersion = $env:CMUX_MSVC_VERSION
)

$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
. (Join-Path $PSScriptRoot 'windows-slice-toolchain.ps1')
$toolchain = Initialize-CmuxWindowsSliceToolchain `
    -RepoRoot $repoRoot.Path `
    -SwiftRoot $SwiftRoot `
    -SwiftVersion $SwiftVersion `
    -MsvcVersion $MsvcVersion

$helperSource = Join-Path $PSScriptRoot 'windows-webview2-child-host.cpp'
$sdkRoot = Join-Path $repoRoot 'vendor\webview2-sdk\1.0.3912.50'
$sdkInclude = Join-Path $sdkRoot 'build\native\include'
$sdkLib = Join-Path $sdkRoot 'build\native\x64\WebView2LoaderStatic.lib'
$vcvars = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"

foreach ($requiredPath in @($helperSource, $sdkInclude, $sdkLib, $vcvars)) {
    if (-not (Test-Path $requiredPath)) {
        throw "Required WebView2 child-host dependency not found: $requiredPath"
    }
}

$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path $outputDirectory)) {
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
}
$outputStem = [System.IO.Path]::GetFileNameWithoutExtension($OutputPath)
$objectPath = Join-Path $outputDirectory "$outputStem.obj"
$pdbPath = Join-Path $outputDirectory "$outputStem.pdb"

$quotedSource = '"' + $helperSource + '"'
$quotedOutput = '"' + $OutputPath + '"'
$quotedInclude = '"' + $sdkInclude + '"'
$quotedLib = '"' + $sdkLib + '"'
$quotedVcvars = '"' + $vcvars + '"'
$quotedObject = '"' + $objectPath + '"'
$quotedPdb = '"' + $pdbPath + '"'

$compileCommand = @(
    "call $quotedVcvars >nul &&",
    'cl /nologo /std:c++17 /EHsc /FS /DUNICODE /D_UNICODE /DWIN32_LEAN_AND_MEAN',
    "/I $quotedInclude",
    "/Fo$quotedObject",
    "/Fd$quotedPdb",
    $quotedSource,
    "/Fe:$quotedOutput",
    "/link $quotedLib user32.lib gdi32.lib ole32.lib shell32.lib shlwapi.lib advapi32.lib"
) -join ' '

cmd.exe /d /c $compileCommand
if ($LASTEXITCODE -ne 0) {
    throw "Failed to build WebView2 child-host helper"
}

Write-Host "Built $OutputPath"
