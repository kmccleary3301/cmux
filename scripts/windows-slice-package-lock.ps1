function Invoke-CmuxWindowsSlicePackageLocked {
    param(
        [scriptblock]$Script,
        [int]$TimeoutSeconds = 180,
        [string]$LockName = 'Global\cmux_windows_slice_package_lock'
    )

    if ($null -eq $Script) {
        throw 'Invoke-CmuxWindowsSlicePackageLocked requires a script block.'
    }

    $mutex = New-Object System.Threading.Mutex($false, $LockName)
    $lockAcquired = $false

    try {
        $lockAcquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
        if (-not $lockAcquired) {
            throw "Timed out waiting for Windows slice package lock: $LockName"
        }

        & $Script
    }
    finally {
        if ($lockAcquired) {
            [void]$mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}
