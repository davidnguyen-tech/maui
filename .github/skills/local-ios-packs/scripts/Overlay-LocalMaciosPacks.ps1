<#
.SYNOPSIS
    Overlay locally built dotnet/macios packs onto the provisioned .NET SDK.

.DESCRIPTION
    Replaces provisioned iOS and/or MacCatalyst workload packs with locally built
    nupkg files from a dotnet/macios build. This lets you test local macios changes
    against a MAUI build without waiting for dependency flow.

    The script backs up everything it modifies and can fully restore via -Restore.

.PARAMETER MaciosArtifactsPath
    Path to the directory containing locally built .nupkg files from dotnet/macios.
    Typically: <macios-repo>/artifacts/package/<Configuration>/

.PARAMETER Platform
    Which platform packs to overlay: 'ios', 'maccatalyst', or 'all' (default).

.PARAMETER Restore
    Undo a previous overlay by restoring all backups.

.PARAMETER DotNetRoot
    Path to the .dotnet SDK directory. Default: auto-discover <repo-root>/.dotnet

.EXAMPLE
    # Overlay all iOS and MacCatalyst packs
    ./Overlay-LocalMaciosPacks.ps1 -MaciosArtifactsPath ~/repos/macios/artifacts/package/Debug/

.EXAMPLE
    # Overlay only iOS packs
    ./Overlay-LocalMaciosPacks.ps1 -MaciosArtifactsPath ~/repos/macios/artifacts/package/Debug/ -Platform ios

.EXAMPLE
    # Restore original packs
    ./Overlay-LocalMaciosPacks.ps1 -Restore
#>

[CmdletBinding(DefaultParameterSetName = 'Overlay')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Overlay')]
    [string]$MaciosArtifactsPath,

    [Parameter(ParameterSetName = 'Overlay')]
    [ValidateSet('ios', 'maccatalyst', 'all')]
    [string]$Platform = 'all',

    [Parameter(Mandatory = $true, ParameterSetName = 'Restore')]
    [switch]$Restore,

    [Parameter()]
    [string]$DotNetRoot
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Status {
    param([string]$Message)
    Write-Host "[overlay] $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[overlay] $Message" -ForegroundColor Green
}

function ConvertFrom-JsonWithTrailingCommas {
    <#
    .SYNOPSIS
        Parse JSON that contains trailing commas (common in workload manifests).
        PowerShell's ConvertFrom-Json is strict about trailing commas, so we
        strip them before parsing.
    #>
    param([string]$JsonText)
    # Remove trailing commas before closing brackets/braces
    $cleaned = $JsonText -replace ',\s*([\]\}])', '$1'
    return $cleaned | ConvertFrom-Json
}

function Find-DotNetRoot {
    <#
    .SYNOPSIS
        Walk up from the script location to find the repo root's .dotnet/ directory.
    #>
    param([string]$ExplicitPath)

    if ($ExplicitPath) {
        if (-not (Test-Path $ExplicitPath)) {
            throw "Specified -DotNetRoot does not exist: $ExplicitPath"
        }
        return (Resolve-Path $ExplicitPath).Path
    }

    # Walk up from script location to find .dotnet/
    $searchDir = $PSScriptRoot
    for ($i = 0; $i -lt 10; $i++) {
        $candidate = Join-Path $searchDir '.dotnet'
        if (Test-Path $candidate) {
            return (Resolve-Path $candidate).Path
        }
        $parent = Split-Path $searchDir -Parent
        if (-not $parent -or $parent -eq $searchDir) { break }
        $searchDir = $parent
    }

    throw "Could not find .dotnet/ directory. Run './build.sh --restore' first, or specify -DotNetRoot."
}

function Find-SdkBand {
    <#
    .SYNOPSIS
        Find the SDK version band that contains the iOS/MacCatalyst manifests.
    #>
    param([string]$DotNetRoot)

    $manifestsRoot = Join-Path $DotNetRoot 'sdk-manifests'
    if (-not (Test-Path $manifestsRoot)) {
        throw "No sdk-manifests directory found at: $manifestsRoot"
    }

    $bands = Get-ChildItem -Path $manifestsRoot -Directory | Sort-Object Name -Descending
    foreach ($band in $bands) {
        $iosManifestDir = Join-Path $band.FullName 'microsoft.net.sdk.ios'
        if (Test-Path $iosManifestDir) {
            return $band.Name
        }
    }

    throw "No SDK band found containing microsoft.net.sdk.ios manifest under: $manifestsRoot"
}

function Read-WorkloadManifest {
    <#
    .SYNOPSIS
        Read and parse a WorkloadManifest.json, handling trailing commas.
    #>
    param([string]$ManifestPath)

    if (-not (Test-Path $ManifestPath)) {
        throw "Manifest not found: $ManifestPath"
    }

    $raw = Get-Content -Path $ManifestPath -Raw
    return ConvertFrom-JsonWithTrailingCommas -JsonText $raw
}

function Get-PacksFromManifest {
    <#
    .SYNOPSIS
        Extract pack entries from a manifest, filtering by platform prefix.
        Returns a hashtable of pack ID → { Version, ResolvedName } where
        ResolvedName accounts for alias-to on the current macOS RID.
    #>
    param(
        [PSCustomObject]$Manifest,
        [string]$PlatformPrefix  # 'Microsoft.iOS' or 'Microsoft.MacCatalyst'
    )

    $result = @{}
    $currentRid = Get-MacOSRid

    $packMembers = $Manifest.packs | Get-Member -MemberType NoteProperty
    foreach ($member in $packMembers) {
        $packId = $member.Name
        # Filter to the requested platform prefix
        if (-not $packId.StartsWith("$PlatformPrefix.")) { continue }
        # Skip Windows-only packs
        if ($packId -match '\.Windows\.') { continue }
        # Skip template packs
        if ($packId -match '\.Templates') { continue }
        # Skip backcompat packs (net10.0, etc.) — only overlay current-TFM packs
        # Heuristic: current-TFM packs contain 'net11' or the highest net version in the ID
        # Better: only include packs whose version matches the manifest's top-level version
        $packInfo = $Manifest.packs.$packId
        if ($packInfo.version -ne $Manifest.version) { continue }

        # Resolve alias-to for macOS
        $resolvedName = $packId
        if ($packInfo.'alias-to') {
            $aliasMembers = $packInfo.'alias-to' | Get-Member -MemberType NoteProperty
            foreach ($aliasMember in $aliasMembers) {
                $aliasRid = $aliasMember.Name
                # Match current macOS RID or 'any'
                if ($aliasRid -eq $currentRid -or $aliasRid -eq 'any') {
                    $resolvedName = $packInfo.'alias-to'.$aliasRid
                    break
                }
            }
            # Also check osx-x64 as fallback if we're on osx-arm64
            if ($resolvedName -eq $packId -and $currentRid -eq 'osx-arm64') {
                foreach ($aliasMember in $aliasMembers) {
                    if ($aliasMember.Name -eq 'osx-x64') {
                        $resolvedName = $packInfo.'alias-to'.'osx-x64'
                        break
                    }
                }
            }
        }

        $result[$packId] = @{
            Version      = $packInfo.version
            ResolvedName = $resolvedName
            Kind         = $packInfo.kind
        }
    }

    return $result
}

function Get-MacOSRid {
    <#
    .SYNOPSIS
        Return the current macOS RID (e.g., osx-arm64).
    #>
    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    switch ($arch) {
        'Arm64' { return 'osx-arm64' }
        'X64'   { return 'osx-x64' }
        default { return 'osx-x64' }
    }
}

function Match-NupkgToPack {
    <#
    .SYNOPSIS
        Given a nupkg filename and a set of known pack entries, find the matching
        pack and extract the version from the filename.
    #>
    param(
        [string]$NupkgName,
        [hashtable]$Packs  # packId → { Version, ResolvedName }
    )

    # Build candidate names: both pack ID and resolved name (for alias-to cases)
    foreach ($entry in $Packs.GetEnumerator()) {
        $packId = $entry.Key
        $resolvedName = $entry.Value.ResolvedName

        # Try matching against resolved name first (handles alias-to)
        foreach ($candidateName in @($resolvedName, $packId)) {
            $prefix = "$candidateName."
            if ($NupkgName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                $versionPart = $NupkgName.Substring($prefix.Length)
                # Remove .nupkg suffix
                $version = $versionPart -replace '\.nupkg$', ''
                if ($version) {
                    return @{
                        PackId       = $packId
                        ResolvedName = $resolvedName
                        LocalVersion = $version
                        MatchedOn    = $candidateName
                    }
                }
            }
        }
    }

    return $null
}

function Remove-NuGetCruft {
    <#
    .SYNOPSIS
        Remove NuGet packaging metadata from an extracted nupkg directory.
        These aren't part of the actual pack content.
    #>
    param([string]$ExtractedPath)

    $cruftItems = @('_rels', 'package', '[Content_Types].xml')
    foreach ($item in $cruftItems) {
        $path = Join-Path $ExtractedPath $item
        if (Test-Path $path) {
            Remove-Item -Path $path -Recurse -Force
        }
    }
}

# ---------------------------------------------------------------------------
# Restore mode
# ---------------------------------------------------------------------------

function Invoke-Restore {
    param([string]$DotNetRoot)

    $stateFile = Join-Path $DotNetRoot '.overlay-state.json'
    if (-not (Test-Path $stateFile)) {
        throw "No overlay state file found at: $stateFile`nNothing to restore."
    }

    $state = Get-Content -Path $stateFile -Raw | ConvertFrom-Json
    Write-Status "Restoring overlay from $($state.timestamp)..."
    Write-Status "Old version: $($state.oldVersion) | Local version: $($state.newVersion)"

    $errors = @()

    # Restore each pack directory
    foreach ($pack in $state.packs) {
        $packDir = Join-Path $DotNetRoot "packs/$($pack.resolvedName)"
        $localVersionDir = Join-Path $packDir $pack.localVersion
        $backupDir = Join-Path $packDir "$($pack.installedVersion).overlay-backup"

        try {
            # Remove the local version directory
            if (Test-Path $localVersionDir) {
                Write-Status "  Removing $($pack.resolvedName)/$($pack.localVersion)"
                Remove-Item -Path $localVersionDir -Recurse -Force
            }

            # Restore the backup
            if (Test-Path $backupDir) {
                Write-Status "  Restoring $($pack.resolvedName)/$($pack.installedVersion)"
                Rename-Item -Path $backupDir -NewName $pack.installedVersion
            }
            else {
                Write-Warning "Backup not found: $backupDir"
            }
        }
        catch {
            $errors += "Failed to restore $($pack.resolvedName): $_"
        }
    }

    # Restore manifest backups
    foreach ($manifestBackup in $state.manifestBackups) {
        $backupPath = $manifestBackup
        $originalPath = $backupPath -replace '\.overlay-backup$', ''
        try {
            if (Test-Path $backupPath) {
                Write-Status "  Restoring manifest: $(Split-Path $originalPath -Leaf)"
                if (Test-Path $originalPath) {
                    Remove-Item -Path $originalPath -Force
                }
                Rename-Item -Path $backupPath -NewName (Split-Path $originalPath -Leaf)
            }
            else {
                Write-Warning "Manifest backup not found: $backupPath"
            }
        }
        catch {
            $errors += "Failed to restore manifest $backupPath : $_"
        }
    }

    # Remove state file
    Remove-Item -Path $stateFile -Force

    if ($errors.Count -gt 0) {
        Write-Warning "Restore completed with errors:"
        foreach ($err in $errors) {
            Write-Warning "  $err"
        }
    }
    else {
        Write-Success "Restore complete. All packs reverted to version $($state.oldVersion)."
    }
}

# ---------------------------------------------------------------------------
# Overlay mode
# ---------------------------------------------------------------------------

function Invoke-Overlay {
    param(
        [string]$MaciosArtifactsPath,
        [string]$Platform,
        [string]$DotNetRoot
    )

    # --- Discover environment ---
    $sdkBand = Find-SdkBand -DotNetRoot $DotNetRoot
    Write-Status "SDK band: $sdkBand"

    $manifestsBase = Join-Path $DotNetRoot "sdk-manifests/$sdkBand"

    # Determine which manifests to process based on platform
    $platformConfigs = @()
    if ($Platform -eq 'all' -or $Platform -eq 'ios') {
        $platformConfigs += @{
            Name           = 'iOS'
            Prefix         = 'Microsoft.iOS'
            ManifestDir    = 'microsoft.net.sdk.ios'
        }
    }
    if ($Platform -eq 'all' -or $Platform -eq 'maccatalyst') {
        $platformConfigs += @{
            Name           = 'MacCatalyst'
            Prefix         = 'Microsoft.MacCatalyst'
            ManifestDir    = 'microsoft.net.sdk.maccatalyst'
        }
    }

    # Read manifests and collect all pack information
    $allPacks = @{}           # packId → { Version, ResolvedName, Kind }
    $manifestPaths = @()      # paths to manifests we'll need to patch
    $installedVersion = $null

    foreach ($pc in $platformConfigs) {
        $manifestPath = Join-Path $manifestsBase "$($pc.ManifestDir)/WorkloadManifest.json"
        $manifest = Read-WorkloadManifest -ManifestPath $manifestPath
        $manifestPaths += $manifestPath

        Write-Status "$($pc.Name) manifest version: $($manifest.version)"

        if (-not $installedVersion) {
            $installedVersion = $manifest.version
        }
        elseif ($installedVersion -ne $manifest.version) {
            Write-Warning "iOS and MacCatalyst manifests have different versions ($installedVersion vs $($manifest.version)). Using iOS version."
        }

        $packs = Get-PacksFromManifest -Manifest $manifest -PlatformPrefix $pc.Prefix
        foreach ($entry in $packs.GetEnumerator()) {
            $allPacks[$entry.Key] = $entry.Value
        }
    }

    if ($allPacks.Count -eq 0) {
        throw "No packs found in manifests for platform '$Platform'."
    }

    Write-Status "Found $($allPacks.Count) installed packs (version: $installedVersion)"

    # --- Scan local nupkgs ---
    $artifactsDir = Resolve-Path $MaciosArtifactsPath
    $nupkgFiles = Get-ChildItem -Path $artifactsDir -Filter '*.nupkg' -File |
        Where-Object { $_.Name -notmatch '\.symbols\.nupkg$' }

    if ($nupkgFiles.Count -eq 0) {
        throw "No .nupkg files found in: $artifactsDir"
    }

    # Match nupkgs to known packs
    $matchedPacks = @()
    foreach ($nupkg in $nupkgFiles) {
        $match = Match-NupkgToPack -NupkgName $nupkg.Name -Packs $allPacks
        if ($match) {
            $match.NupkgPath = $nupkg.FullName
            $matchedPacks += $match
        }
    }

    if ($matchedPacks.Count -eq 0) {
        throw "No nupkg files matched any known pack IDs. Check that -MaciosArtifactsPath points to a dotnet/macios build output directory.`nKnown packs: $($allPacks.Keys -join ', ')"
    }

    # Verify all matched packs share the same version
    $localVersions = $matchedPacks | ForEach-Object { $_.LocalVersion } | Sort-Object -Unique
    if ($localVersions.Count -gt 1) {
        throw "Found mixed versions in nupkg files: $($localVersions -join ', '). All packs must be from the same build."
    }
    $localVersion = $localVersions[0]

    Write-Status "Local pack version: $localVersion"
    Write-Status "Matched $($matchedPacks.Count) of $($allPacks.Count) packs"

    # Warn about any packs in the manifest that don't have matching nupkgs
    $matchedPackIds = $matchedPacks | ForEach-Object { $_.PackId }
    $missingPacks = $allPacks.Keys | Where-Object { $_ -notin $matchedPackIds }
    if ($missingPacks.Count -gt 0) {
        Write-Warning "No nupkg found for these packs (they will keep the installed version):"
        foreach ($mp in $missingPacks) {
            Write-Warning "  $mp"
        }
    }

    # --- Check for dirty state ---
    $stateFile = Join-Path $DotNetRoot '.overlay-state.json'
    if (Test-Path $stateFile) {
        throw "A previous overlay is still active (found .overlay-state.json).`nRun with -Restore first to revert, then re-run the overlay."
    }

    # Also check for stale backup directories
    $existingBackups = Get-ChildItem -Path (Join-Path $DotNetRoot 'packs') -Directory -Filter '*.overlay-backup' -Recurse -ErrorAction SilentlyContinue
    if ($existingBackups.Count -gt 0) {
        throw "Found stale backup directories without a .overlay-state.json:`n$($existingBackups.FullName -join "`n")`nManually clean these up before proceeding."
    }

    # --- Backup and overlay ---
    $overlaidPacks = @()
    $manifestBackups = @()

    try {
        foreach ($pack in $matchedPacks) {
            $packId = $pack.PackId
            $resolvedName = $pack.ResolvedName
            $packBaseDir = Join-Path $DotNetRoot "packs/$resolvedName"
            $installedDir = Join-Path $packBaseDir $installedVersion
            $backupDir = Join-Path $packBaseDir "$installedVersion.overlay-backup"
            $localDir = Join-Path $packBaseDir $localVersion

            Write-Status "Overlaying $resolvedName..."

            # Backup the installed version directory
            if (Test-Path $installedDir) {
                Write-Status "  Backing up $installedVersion → $installedVersion.overlay-backup"
                Rename-Item -Path $installedDir -NewName "$installedVersion.overlay-backup"
            }
            else {
                Write-Warning "  Installed directory not found (skipping backup): $installedDir"
            }

            # Create new directory and extract nupkg
            Write-Status "  Extracting to $localVersion"
            New-Item -Path $localDir -ItemType Directory -Force | Out-Null
            Expand-Archive -Path $pack.NupkgPath -DestinationPath $localDir -Force

            # Clean up NuGet packaging metadata
            Remove-NuGetCruft -ExtractedPath $localDir

            $overlaidPacks += @{
                packId           = $packId
                resolvedName     = $resolvedName
                installedVersion = $installedVersion
                localVersion     = $localVersion
                nupkg            = (Split-Path $pack.NupkgPath -Leaf)
            }
        }

        # Patch WorkloadManifest.json files
        foreach ($manifestPath in $manifestPaths) {
            $backupPath = "$manifestPath.overlay-backup"
            Write-Status "Patching manifest: $(Split-Path $manifestPath -Leaf)"
            Copy-Item -Path $manifestPath -Destination $backupPath -Force
            $manifestBackups += $backupPath

            # Read the raw JSON text and replace version strings.
            # We do text replacement rather than object manipulation to preserve
            # the file's formatting and trailing commas (which are valid in the
            # manifest but would be lost through ConvertFrom-Json → ConvertTo-Json).
            $content = Get-Content -Path $manifestPath -Raw
            $content = $content.Replace("`"$installedVersion`"", "`"$localVersion`"")
            Set-Content -Path $manifestPath -Value $content -NoNewline
        }

        # Write overlay state file
        $state = @{
            oldVersion      = $installedVersion
            newVersion      = $localVersion
            packs           = $overlaidPacks
            manifestBackups = $manifestBackups
            timestamp       = (Get-Date -Format 'o')
            platform        = $Platform
        }
        $state | ConvertTo-Json -Depth 5 | Set-Content -Path $stateFile

        # --- Print summary ---
        Write-Host ""
        Write-Success "=== Overlay Complete ==="
        Write-Host ""
        Write-Host "  Installed version : $installedVersion"
        Write-Host "  Local version     : $localVersion"
        Write-Host "  Packs overlaid    : $($overlaidPacks.Count)"
        Write-Host ""
        foreach ($p in $overlaidPacks) {
            Write-Host "    $($p.resolvedName)" -ForegroundColor White
        }
        Write-Host ""
        Write-Host "  To restore original packs:" -ForegroundColor Yellow
        $restoreCmd = "  $($MyInvocation.MyCommand.Name) -Restore"
        if ($script:explicitDotNetRoot) {
            $restoreCmd += " -DotNetRoot '$DotNetRoot'"
        }
        Write-Host "    $restoreCmd" -ForegroundColor Yellow
        Write-Host ""
    }
    catch {
        Write-Error "Overlay failed: $_"
        Write-Warning "Attempting to roll back partial changes..."

        # Roll back any packs we already overlaid
        foreach ($pack in $overlaidPacks) {
            $packBaseDir = Join-Path $DotNetRoot "packs/$($pack.resolvedName)"
            $localDir = Join-Path $packBaseDir $pack.localVersion
            $backupDir = Join-Path $packBaseDir "$($pack.installedVersion).overlay-backup"

            try {
                if (Test-Path $localDir) {
                    Remove-Item -Path $localDir -Recurse -Force
                }
                if (Test-Path $backupDir) {
                    Rename-Item -Path $backupDir -NewName $pack.installedVersion
                }
            }
            catch {
                Write-Warning "Rollback failed for $($pack.resolvedName): $_"
            }
        }

        # Roll back manifest backups
        foreach ($backupPath in $manifestBackups) {
            $originalPath = $backupPath -replace '\.overlay-backup$', ''
            try {
                if (Test-Path $backupPath) {
                    if (Test-Path $originalPath) {
                        Remove-Item -Path $originalPath -Force
                    }
                    Rename-Item -Path $backupPath -NewName (Split-Path $originalPath -Leaf)
                }
            }
            catch {
                Write-Warning "Manifest rollback failed for $backupPath : $_"
            }
        }

        # Clean up state file if it was written
        if (Test-Path $stateFile) {
            Remove-Item -Path $stateFile -Force -ErrorAction SilentlyContinue
        }

        throw
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    $script:explicitDotNetRoot = [bool]$DotNetRoot
    $dotnetRoot = Find-DotNetRoot -ExplicitPath $DotNetRoot

    Write-Status "DOTNET_ROOT: $dotnetRoot"

    if ($Restore) {
        Invoke-Restore -DotNetRoot $dotnetRoot
    }
    else {
        if (-not (Test-Path $MaciosArtifactsPath)) {
            throw "Artifacts path does not exist: $MaciosArtifactsPath"
        }
        Invoke-Overlay -MaciosArtifactsPath $MaciosArtifactsPath -Platform $Platform -DotNetRoot $dotnetRoot
    }
}
catch {
    Write-Host ""
    Write-Error $_
    exit 1
}
