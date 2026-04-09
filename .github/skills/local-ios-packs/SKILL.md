---
name: local-ios-packs
description: "Override provisioned iOS/MacCatalyst workload packs with locally built dotnet/macios packs. Use when testing local macios changes against MAUI."
metadata:
  author: dotnet-maui
  version: "1.0"
compatibility: "macOS only. Requires local dotnet/macios build output (nupkg files)."
---

# Local iOS/MacCatalyst Packs Overlay

Override the provisioned iOS and MacCatalyst workload packs in `.dotnet/` with locally built packs from a [dotnet/macios](https://github.com/dotnet/macios) checkout. This lets you test macios changes against MAUI without waiting for dependency flow through Maestro.

## When to Use

- **Testing local dotnet/macios changes** — you've made a fix or feature in macios and want to verify it works with MAUI before submitting a PR
- **Debugging platform issues** — you need to add diagnostics or logging to the iOS/MacCatalyst SDK and test against MAUI
- **Validating fixes before dependency updates** — a macios fix has been merged but hasn't flowed to MAUI yet; you want to test it now
- **Bisecting regressions** — testing different macios commits against the same MAUI code

## Prerequisites

1. **Built dotnet/macios repo** with nupkg output. You need the `.nupkg` files for the packs you want to overlay.
2. **Provisioned MAUI SDK** — the `.dotnet/` directory must exist. Run from the MAUI repo root:
   ```bash
   ./build.sh --restore
   ```
3. **PowerShell Core (pwsh)** — installed on macOS. The provisioned `.dotnet/` may include it, or install via `brew install powershell`.

## How It Works

The script uses a **manifest patching + pack replacement** approach:

1. Reads `WorkloadManifest.json` files to discover which packs are installed and their versions
2. Matches your local `.nupkg` files to the installed pack IDs
3. Backs up the existing pack directories (renaming to `*.overlay-backup`)
4. Extracts your local nupkgs into new version directories under `.dotnet/packs/`
5. Patches the manifest JSON to point to the new version
6. Records the overlay state in `.dotnet/.overlay-state.json` for clean restore

Everything is reversible — run with `-Restore` to undo all changes.

## Usage

### Overlay packs (all platforms)

```powershell
.github/skills/local-ios-packs/scripts/Overlay-LocalMaciosPacks.ps1 `
    -MaciosArtifactsPath ~/repos/macios/artifacts/package/Debug/
```

### Overlay only iOS packs

```powershell
.github/skills/local-ios-packs/scripts/Overlay-LocalMaciosPacks.ps1 `
    -MaciosArtifactsPath ~/repos/macios/artifacts/package/Debug/ `
    -Platform ios
```

### Overlay only MacCatalyst packs

```powershell
.github/skills/local-ios-packs/scripts/Overlay-LocalMaciosPacks.ps1 `
    -MaciosArtifactsPath ~/repos/macios/artifacts/package/Debug/ `
    -Platform maccatalyst
```

### Restore original packs

```powershell
.github/skills/local-ios-packs/scripts/Overlay-LocalMaciosPacks.ps1 -Restore
```

### Explicit .dotnet path

If the script can't auto-discover the `.dotnet/` directory (e.g., you're running it from outside the repo tree):

```powershell
.github/skills/local-ios-packs/scripts/Overlay-LocalMaciosPacks.ps1 `
    -MaciosArtifactsPath ~/repos/macios/artifacts/package/Debug/ `
    -DotNetRoot /path/to/maui-repo/.dotnet
```

## What Gets Overlaid

The script overlays the **current TFM** packs (e.g., net11.0) — not backcompat packs (net10.0). It identifies packs by reading the manifest and filtering for entries whose version matches the manifest's top-level version.

### iOS Packs

| Pack ID | Kind |
|---------|------|
| `Microsoft.iOS.Sdk.net11.0_26.2` | sdk |
| `Microsoft.iOS.Ref.net11.0_26.2` | framework |
| `Microsoft.iOS.Runtime.ios.net11.0_26.2` | framework |
| `Microsoft.iOS.Runtime.ios-arm64.net11.0_26.2` | framework |
| `Microsoft.iOS.Runtime.iossimulator-arm64.net11.0_26.2` | framework |
| `Microsoft.iOS.Runtime.iossimulator-x64.net11.0_26.2` | framework |

### MacCatalyst Packs

| Pack ID | Kind |
|---------|------|
| `Microsoft.MacCatalyst.Sdk.net11.0_26.2` | sdk |
| `Microsoft.MacCatalyst.Ref.net11.0_26.2` | framework |
| `Microsoft.MacCatalyst.Runtime.maccatalyst.net11.0_26.2` | framework |
| `Microsoft.MacCatalyst.Runtime.maccatalyst-arm64.net11.0_26.2` | framework |
| `Microsoft.MacCatalyst.Runtime.maccatalyst-x64.net11.0_26.2` | framework |

> **Note:** Pack IDs include a TFM suffix (e.g., `net11.0_26.2`) that changes between branches and versions. The script discovers these dynamically from the manifest — the table above shows example values.

## Building dotnet/macios

To produce the nupkg files needed by this script, build the [dotnet/macios](https://github.com/dotnet/macios) repo. The high-level steps:

```bash
cd ~/repos/macios
./configure
make all
make package
```

The nupkg files will be in `artifacts/package/<Configuration>/` (e.g., `artifacts/package/Debug/`).

For detailed instructions, see the [dotnet/macios build documentation](https://github.com/dotnet/macios/blob/main/docs/README.md). The exact build commands may vary by branch.

## Troubleshooting

### "No .nupkg files found"

Your `-MaciosArtifactsPath` doesn't contain nupkg files. Verify the path — it should point to the directory containing the built packages, typically `artifacts/package/<Configuration>/`.

### "No nupkg files matched any known pack IDs"

The nupkgs in your artifacts don't match the pack IDs in the installed manifest. This usually means:
- The macios branch you built doesn't match the MAUI branch's expected pack names
- The TFM suffix has changed (e.g., `net11.0_26.2` vs `net11.0_26.3`)

Check which packs the manifest expects by examining `.dotnet/sdk-manifests/*/microsoft.net.sdk.ios/WorkloadManifest.json`.

### "A previous overlay is still active"

Run with `-Restore` first to revert the previous overlay, then try again:
```powershell
.github/skills/local-ios-packs/scripts/Overlay-LocalMaciosPacks.ps1 -Restore
```

### "Found stale backup directories"

Backup directories exist but the `.overlay-state.json` is missing (possibly from a crashed previous run). Manually inspect and clean up the `*.overlay-backup` directories under `.dotnet/packs/`, then re-run provisioning:
```bash
./build.sh --restore
```

### "Found mixed versions in nupkg files"

All nupkg files must be from the same macios build. If you see mixed versions, clean and rebuild macios, or delete stale nupkgs from the artifacts directory.

### Build errors after overlay

If MAUI builds fail after overlaying, the local macios version may be incompatible. Check for API changes or missing dependencies. Restore with `-Restore` to go back to the known-good state.

## Limitations

- **Current TFM only** — overlays net11.0 packs, not backcompat (net10.0) packs. If you need to test older TFM packs, you'll need to modify the version filtering.
- **Does not override NETCore.App runtime packs** — Mono runtime packs (`Microsoft.NETCore.App.Runtime.Mono.*`) and AOT cross-compilation packs are NOT overlaid. For overriding NETCore.App Mono runtime packs (from dotnet/runtime), a separate workflow is needed (not covered by this skill).
- **macOS only** — the script targets macOS development workflows. Windows pack overlays (e.g., `Microsoft.iOS.Windows.Sdk`) are not supported.
- **Alias-to packs** — the script handles `alias-to` entries in the manifest, resolving to the correct pack name for macOS. If a future manifest changes alias patterns, the matching logic may need updating.
