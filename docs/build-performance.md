# Windows Build Performance Playbook

This document captures Windows-specific knobs that materially affect inner-loop
build wall-clock on the dotnet/aspire repo. Numbers cited here come from a
local measurement fleet of 25 runs (M01..M25) on a single Windows 11 host
against `Aspire.slnx` (427 csproj, 6 NuGet feeds, 242 PackageVersions). For the
raw data format see [results.csv format](#resultscsv-format) at the bottom.

> Background: a contributor profiling this repo on Windows 11 saw cold
> inner-loop wall-clock roughly 2x slower than the same repo on macOS. None of
> the dominant factors are repo bugs - they are machine/OS configuration that
> every Windows .NET contributor inherits silently. This playbook captures the
> fixes.

## Table of contents

- [Quick start - the three highest-value wins](#quick-start---the-three-highest-value-wins)
- [1. Use Aspire-FastDev.slnf for inner loop](#1-use-aspire-fastdevslnf-for-inner-loop)
- [2. Microsoft Defender exclusions (admin)](#2-microsoft-defender-exclusions-admin)
- [3. Dev Drive on Windows 11](#3-dev-drive-on-windows-11)
- [4. Server GC for the build host](#4-server-gc-for-the-build-host)
- [5. dotnet build /m:N parallelism tuning](#5-dotnet-build-mn-parallelism-tuning)
- [6. Misconfigured Azure Artifacts credential provider (~47 s tax)](#6-misconfigured-azure-artifacts-credential-provider-47-s-tax)
- [Recommendation -> measurement reference table](#recommendation---measurement-reference-table)
- [results.csv format](#resultscsv-format)

## Quick start - the three highest-value wins

If you do nothing else, do these three, in this order. They are independent
and additive.

1. **Defender exclusions** (admin) - see [section 2](#2-microsoft-defender-exclusions-admin).
   Expected 15-40% cold wall improvement based on synth consensus (M21/M22/M25
   require an elevated re-run to close out the measurement).
2. **Dev Drive** for repo + NuGet cache + .dotnet - see [section 3](#3-dev-drive-on-windows-11).
   The naive setup measured *slower* (M23); the correct setup is below.
3. **`Aspire-FastDev.slnf`** for daily Hosting/AppHost/Cli/Dashboard work - see
   [section 1](#1-use-aspire-fastdevslnf-for-inner-loop). Cold wall 39.26 s
   (M07) vs 244.75 s for full `Aspire.slnx` (M03) - 6.2x.

Everything else in this doc is smaller (single-digit-percent wins, or
machine-bug fixes that only matter if you have hit them).

## 1. Use Aspire-FastDev.slnf for inner loop

For day-to-day work on Hosting / AppHost / Cli / Dashboard, build the
9-project filter rather than the 427-project full graph.

```powershell
dotnet build Aspire-FastDev.slnf
```

Measured cold wall:

| Target | Cold wall | Source |
|---|---|---|
| `Aspire.slnx` (full) | 244.75 s | M03 |
| `Aspire-Core.slnf` | 96.52 s | M05 |
| `Aspire-FastDev.slnf` | 39.26 s | M07 |

`Aspire-FastDev.slnf` lands via PR P1. Until that PR merges, `Aspire-Core.slnf`
is the next-best filter (still 2.5x faster than full).

Run the full `Aspire.slnx` (or `build.cmd`) before pushing a PR so analyzers
and the broader graph still validate your change.

## 2. Microsoft Defender exclusions (admin)

Real-time AV scanning is the single largest unverified Windows tax on this
repo (synth-1 hypothesis #1). On a developer machine where the source tree
is already trusted, exclude the repo, the NuGet cache, the local SDK, and
the four compiler processes.

> **Run elevated.** `Add-MpPreference` requires an admin PowerShell session.
> Trade-off: this excludes your source tree and toolchain from real-time AV.
> Only do this on a developer machine where you accept that trade-off.

Adjust the paths to match your checkout. Example for `C:\Users\<you>\source\aspire`:

```powershell
# Repo + per-user package/SDK caches
Add-MpPreference -ExclusionPath "$env:USERPROFILE\source\aspire"
Add-MpPreference -ExclusionPath "$env:USERPROFILE\.nuget\packages"
Add-MpPreference -ExclusionPath "$env:USERPROFILE\source\aspire\.dotnet"
Add-MpPreference -ExclusionPath "$env:USERPROFILE\source\aspire\artifacts"

# Common output folders (covers any obj/bin under the repo)
Add-MpPreference -ExclusionPath "$env:USERPROFILE\source\aspire\**\obj"
Add-MpPreference -ExclusionPath "$env:USERPROFILE\source\aspire\**\bin"

# Build/compiler processes
Add-MpPreference -ExclusionProcess "dotnet.exe"
Add-MpPreference -ExclusionProcess "MSBuild.exe"
Add-MpPreference -ExclusionProcess "VBCSCompiler.exe"
Add-MpPreference -ExclusionProcess "csc.exe"
```

Verify:

```powershell
Get-MpPreference | Select-Object -ExpandProperty ExclusionPath
Get-MpPreference | Select-Object -ExpandProperty ExclusionProcess
```

Roll back with the same incantation, swapping `Add-MpPreference` for
`Remove-MpPreference`.

**Status:** synth consensus expects 15-40% cold-wall improvement. M21
(Defender attribution), M22 (`Get-MpPerformanceRecording`), and M25 (WPR ETW
file-IO trace) were SKIPPED in the measurement fleet because they require an
elevated session. Re-running them under admin is the way to close the loop.

## 3. Dev Drive on Windows 11

A Dev Drive (ReFS volume with `MsSecFlt`-only AV policy) avoids real-time
filter-driver overhead for build I/O. It only helps if **all** of the source
tree, the NuGet cache, and the local SDK live on the Dev Drive.

### Set it up (admin)

```powershell
# 1. Confirm the system supports Dev Drive
fsutil devdrv enable

# 2. Create a VHDX-backed Dev Drive (50 GB is comfortable for this repo +
#    package cache + .dotnet; size to taste). Use Settings -> System ->
#    Storage -> Disks & volumes -> Create VHD, format ReFS, mark as Dev Drive,
#    or run the equivalent diskpart/Storage cmdlets. Mount it as e.g. G:.

# 3. Trust the Dev Drive (reduces the AV filter set further on a dev machine)
fsutil devdrv trust G:
fsutil devdrv query  G:
```

### Move the repo and the caches onto it

```powershell
# Per shell (or set as user env var via SystemPropertiesAdvanced):
$env:NUGET_PACKAGES    = "G:\nuget\packages"
$env:DOTNET_INSTALL_DIR = "G:\src\aspire\.dotnet"

# Move/clone the repo onto the Dev Drive
git clone https://github.com/dotnet/aspire G:\src\aspire
```

### Caveat - M23 was inconclusive

M23 measured the Dev Drive case at **130.52 s** versus **107.79 s** on NTFS
C: (M05a + M05) - i.e. *slower*. The reason was that `NUGET_PACKAGES` was
left pointing at `C:\.tools\.nuget\packages\`, so every restore round-tripped
between the Dev Drive (source/output) and NTFS (package cache), defeating the
point.

Treat the M23 number as a measurement of a half-configured setup, not as
evidence that Dev Drive is slow. Re-measure with `NUGET_PACKAGES` and
`DOTNET_INSTALL_DIR` both on the Dev Drive before drawing any conclusion.

## 4. Server GC for the build host

Server GC produces a small but real warm-build improvement for MSBuild and
the Roslyn compiler servers.

```powershell
$env:DOTNET_gcServer = "1"
# Optional companions; re-measure cold before adopting:
$env:DOTNET_TieredPGO = "1"
```

Measured: M20 (`DOTNET_gcServer=1` + `DOTNET_TieredPGO=1`) warm Aspire-Core
= 26.78 s vs M17 baseline warm = 28.15 s. The delta is within the noise
band of this fleet, so treat as a modest win, not a silver bullet, and only
re-measure cold full-slnx before promoting to a default.

## 5. dotnet build /m:N parallelism tuning

MSBuild's `/m:N` flag bounds the number of parallel project builds. Higher
is not always better - oversubscribing physical cores costs more in context
switching, lock contention, and shared-compiler queue pressure than it gains.

| Run | Filter | `/m` | Warm wall | Source |
|---|---|---|---|---|
| M18 | `Aspire-Core.slnf` | 4  | 19.91 s | M18 |
| M19 | `Aspire-Core.slnf` | 32 | 34.82 s | M19 |

On the measurement host `/m:4` beat `/m:32` by ~15 s warm on Aspire-Core.
The result is single-datapoint per cell, so do not over-fit, but the
guidance is straightforward:

- Do not exceed your **physical** core count (not logical/SMT count).
- Start with `/m:4` for small filters; raise toward physical-core count for
  the full graph.
- If you have a hyperthreaded 8-core box, `/m:8` is a sane default.

```powershell
dotnet build Aspire-Core.slnf /m:4
```

## 6. Misconfigured Azure Artifacts credential provider (~47 s tax)

This is a **machine bug, not a repo bug**. All six Aspire NuGet feeds are
public; no credential provider is required. If a misconfigured
`CredentialProvider.Microsoft.dll` is present (often left over from a
previous Azure DevOps install), it adds roughly **47 seconds of dead time
per `dotnet restore`** even when no feed needs auth.

### Symptom

`dotnet restore` (or any restore-issuing command) hangs for ~45-50 s with
no log output, then fails or proceeds. Verbose restore output may include
something like:

```
error MSB1009: ... failed within 46.859 seconds with exit code -1
```

### Fix

Either uninstall the misconfigured plugin:

```powershell
Remove-Item -Recurse -Force "$env:USERPROFILE\.nuget\plugins\netcore\CredentialProvider.Microsoft"
```

Or unset the offending env vars per shell:

```powershell
Remove-Item Env:NUGET_NETCORE_PLUGIN_PATHS  -ErrorAction SilentlyContinue
Remove-Item Env:NUGET_NETFX_PLUGIN_PATHS    -ErrorAction SilentlyContinue
Get-ChildItem Env:NUGET_CREDENTIALPROVIDER_* -ErrorAction SilentlyContinue | Remove-Item
$env:NUGET_PLUGIN_PATHS = ""
```

If you actively use Azure Artifacts on another repo, prefer the per-shell
unset over the uninstall.

## Recommendation -> measurement reference table

| # | Recommendation | Primary measurement(s) | Comparator |
|---|---|---|---|
| 1 | Use `Aspire-FastDev.slnf` | M07 (39.26 s cold) | M03 (244.75 s) full; M05 (96.52 s) Core |
| 2 | Defender exclusions | M21 / M22 / M25 (SKIPPED - admin) | re-run elevated to close synth-1 #1 |
| 3 | Dev Drive setup (full) | M23 (130.52 s, half-configured) | M05a + M05 (107.79 s) NTFS |
| 4 | `DOTNET_gcServer=1` (+ `TieredPGO=1`) | M20 (26.78 s warm) | M17 (28.15 s warm) baseline |
| 5 | `/m:4` over `/m:32` on small filters | M18 (19.91 s warm) | M19 (34.82 s warm) |
| 5 | Static-graph restore (lands via P2) | M15a (17.55 s warm restore) | M02 (32.97 s warm restore) |
| 6 | Unset Azure Artifacts credential provider | observed ~47 s dead time per restore | n/a (machine bug) |

Additional context for related items deferred from this PR set:

- `/graph` build as default: M14 warm Aspire-Core = 84.98 s vs M06 12.4 s -
  re-evaluation invalidated up-to-date checks. Negative warm signal; needs
  cold full-slnx re-measurement.
- `EnforceCodeStyleInBuild=false` as default: M12 = 73.09 s, *slower* than
  baseline due to property-key invalidation in a warm run. Offered behind
  the opt-in `AspireFastInnerLoop` flag (PR P5) instead.
- `UsePublicApiAnalyzers`: 0 `PublicAPI.{Shipped,Unshipped}.txt` files exist
  in the repo; analyzer loads on ~100 src projects for zero baseline content.
  Lands via PR P3.

## results.csv format

The measurement fleet stored each run as one row in a `results.csv`. The
actual numbers are platform- and host-specific (Defender state, CPU, disk,
NuGet cache warmth, etc.) and are not checked into this repo. The schema is
documented here so future benchmarkers can produce comparable data.

| Column | Meaning |
|---|---|
| `id` | Run identifier, `M01`..`M25` in the original fleet |
| `target` | `Aspire.slnx`, `Aspire-Core.slnf`, `Aspire-FastDev.slnf`, etc. |
| `state` | `cold` or `warm` |
| `command` | Exact command line, e.g. `dotnet build Aspire-Core.slnf /m:4` |
| `env` | Notable env vars set for the run (e.g. `DOTNET_gcServer=1`) |
| `wall_seconds` | Wall-clock seconds, fractional |
| `exit_code` | Process exit code (0 = success) |
| `notes` | Free text - host config, what was being isolated, anomalies |

Recommended methodology: run each cell at least 3 times, drop the first as
warm-up, report median. Always record host CPU, physical core count, AV
state, and whether the source tree / NuGet cache are on a Dev Drive - those
four variables explain most cross-host variance.