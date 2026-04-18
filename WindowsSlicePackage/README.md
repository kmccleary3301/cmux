# Windows Slice Package

This directory is the formal SwiftPM build boundary for the Windows-safe `cmux` slice.

It exists to give the Windows lane a durable, reproducible module boundary instead of relying only on ad hoc script compilation. The package is generated from the canonical slice manifest in [`../scripts/windows-slice-sources.txt`](../scripts/windows-slice-sources.txt).

## What it contains

The package mirrors the Windows-safe source set:

- core reducer/state/bootstrap files
- Windows bootstrap and host code
- Windows Ghostty bridge, browser host, notification host, shell host, and smoke harness
- the generated `windows-slice-sources.txt` snapshot used to materialize the package

It does **not** include:

- macOS-only app graph files
- AppKit/WebKit/Bonsplit-heavy source
- build output under `.build/`

## Canonical workflow

Sync the package from the source manifest:

```powershell
.\cmux\scripts\sync-windows-slice-package.ps1
```

Build the package:

```powershell
.\cmux\scripts\build-windows-slice-package.ps1 -Sync
```

Package the Windows lane:

```powershell
.\cmux\scripts\package-windows-lane.ps1
```

Validate the packaged lane:

```powershell
.\cmux\dist\windows-lane\tools\run-windows-lane-ci.ps1 -InstallRoot (Resolve-Path .\cmux\dist\windows-lane).Path
```

## Source of truth

The package contents should be treated as generated output.

The real ownership points are:

- [`../scripts/windows-slice-sources.txt`](../scripts/windows-slice-sources.txt)
- [`../scripts/sync-windows-slice-package.ps1`](../scripts/sync-windows-slice-package.ps1)
- [`../scripts/build-windows-slice-package.ps1`](../scripts/build-windows-slice-package.ps1)

If the package and the slice manifest drift, regenerate the package instead of editing package sources by hand.

## Validation notes

- Package builds are expected to run on Windows with the local Swift + MSVC toolchain configured by the repo scripts.
- The package is part of the broader Windows lane, not a standalone end-user distribution by itself.
- Use the packaged lane under `dist/windows-lane` for end-to-end validation, triage bundles, and install-root checks.
