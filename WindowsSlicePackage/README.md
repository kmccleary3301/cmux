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