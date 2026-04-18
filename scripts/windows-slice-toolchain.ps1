function Initialize-CmuxWindowsSliceToolchain {
    param(
        [string]$RepoRoot,
        [string]$SwiftRoot = $env:CMUX_SWIFT_ROOT,
        [string]$SwiftVersion = $env:CMUX_SWIFT_VERSION,
        [string]$MsvcVersion = $env:CMUX_MSVC_VERSION
    )

    if ([string]::IsNullOrWhiteSpace($SwiftRoot)) {
        $SwiftRoot = 'C:\Users\subje\AppData\Local\Programs\Swift'
    }
    if ([string]::IsNullOrWhiteSpace($SwiftVersion)) {
        $SwiftVersion = '6.2.4'
    }
    if ([string]::IsNullOrWhiteSpace($MsvcVersion)) {
        $MsvcVersion = '14.38.33130'
    }

    $swiftToolchainBin = Join-Path $SwiftRoot "Toolchains\$SwiftVersion+Asserts\usr\bin"
    $swiftRuntimeBin = Join-Path $SwiftRoot "Runtimes\$SwiftVersion\usr\bin"
    $swiftSdkRoot = Join-Path $SwiftRoot "Platforms\$SwiftVersion\Windows.platform\Developer\SDKs\Windows.sdk"
    $msvcBin = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\$MsvcVersion\bin\Hostx64\x64"

    if (-not (Test-Path $swiftSdkRoot)) {
        throw "Swift Windows SDK not found at $swiftSdkRoot"
    }

    foreach ($path in @($swiftToolchainBin, $swiftRuntimeBin, $msvcBin)) {
        if (-not (Test-Path $path)) {
            throw "Required toolchain path not found: $path"
        }
    }

    $env:SDKROOT = $swiftSdkRoot
    $env:SWIFTFLAGS = '-sdk ' + $env:SDKROOT + ' -resource-dir ' + $env:SDKROOT + '\usr\lib\swift -I ' + $env:SDKROOT + '\usr\lib\swift -L ' + $env:SDKROOT + '\usr\lib\swift\windows'

    $pathEntries = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @($msvcBin, $swiftToolchainBin, $swiftRuntimeBin) + ($env:Path -split ';')) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $trimmed = $candidate.Trim()
        if ($pathEntries.Contains($trimmed)) { continue }
        [void]$pathEntries.Add($trimmed)
    }
    $env:Path = ($pathEntries -join ';')
    $env:CMUX_REPO_ROOT = $RepoRoot

    $ghosttyExe = Join-Path $RepoRoot '..\ghostty\zig-out\bin\ghostty.exe'
    if (Test-Path $ghosttyExe) {
        $env:CMUX_GHOSTTY_EXE = (Resolve-Path $ghosttyExe).Path
    }

    [pscustomobject]@{
        RepoRoot = $RepoRoot
        SwiftRoot = $SwiftRoot
        SwiftVersion = $SwiftVersion
        MsvcVersion = $MsvcVersion
        SwiftToolchainBin = $swiftToolchainBin
        SwiftRuntimeBin = $swiftRuntimeBin
        SwiftSdkRoot = $swiftSdkRoot
        MsvcBin = $msvcBin
        GhosttyExe = $(if (Test-Path $ghosttyExe) { (Resolve-Path $ghosttyExe).Path } else { $null })
    }
}
