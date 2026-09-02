<#
.SYNOPSIS
    Builds a reusable, fully-packaged WinPE base media folder (with PowerShell/
    StorageWMI already installed) using DISM - meant to be run occasionally on
    a REAL Windows host or VM, not in a container, and then reused by
    Build-WinPEImage.ps1 on every CI run without needing DISM at all.

.DESCRIPTION
    This is the DISM-dependent half of the WinPE build, split out on purpose:
    Mount-WindowsImage / Add-WindowsPackage need the WIMMount kernel filter
    driver, which lives at the HOST level even from inside a process-isolated
    container - and a killed/interrupted mount can leave that driver in a bad
    state that then poisons every other container scheduled onto the same
    host afterward. That's not something worth fighting on every CI run.

    Instead: run this script rarely (whenever the ADK version, package list, or
    architecture changes) on an actual Windows host where DISM mounting is
    reliable, and upload its output (the whole media\ folder, zipped) somewhere
    the CI pipeline can fetch it from (e.g. MinIO). Every day-to-day CI run then
    uses Build-WinPEImage.ps1, which only needs wimlib-imagex + oscdimg - no
    DISM, no Mount-WindowsImage, no host kernel driver dependency at all.

    Steps:
      1. copype.cmd lays out base WinPE media.
      2. Mounts boot.wim, adds WinPE-WMI -> WinPE-NetFX -> WinPE-PowerShell ->
         WinPE-StorageWMI (same minimal set as before - just PowerShell +
         Mount-DiskImage/Get-Disk/New-Partition/Format-Volume, nothing else).
      3. Runs component cleanup to shrink the image.
      4. Dismounts and saves.
      5. Zips the entire media\ folder (boot.wim + boot files + everything
         oscdimg needs later) to -OutputZipPath.

.PARAMETER OutputZipPath
    Where to write the zipped base media folder.

.PARAMETER AdkRoot
    Root of the Windows ADK install.

.PARAMETER Architecture
    WinPE architecture. Defaults to amd64.

.PARAMETER WorkDir
    Scratch directory for the build.

.PARAMETER DriverPath
    Optional path to a folder containing driver .inf files (searched
    recursively) to inject into the image - e.g. a display, chipset, or NIC
    driver your target hardware needs that WinPE's inbox drivers don't cover.

.PARAMETER GraphicsResolution
    Optional WinPE console display mode. Either an explicit "WIDTHxHEIGHT"
    (e.g. "1024x768") for the BCD graphicsresolution element, or "HIGHEST" to
    use bcdedit's highestmode instead. Leave unset to use the default.

.EXAMPLE
    .\Build-WinPEBase.ps1 -OutputZipPath "D:\artifacts\winpe-base-amd64.zip" `
        -AdkRoot "C:\ADK\Assessment and Deployment Kit"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputZipPath,

    [string]$AdkRoot = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit",

    [ValidateSet("amd64", "x86", "arm64")]
    [string]$Architecture = "amd64",

    [string]$WorkDir = (Join-Path $env:TEMP "WinPEBaseBuild"),

    # Folder containing driver .inf files (searched recursively) to inject -
    # e.g. a display/chipset/NIC driver WinPE's inbox drivers don't cover for
    # your target hardware. Optional - leave unset to skip.
    [string]$DriverPath = "",

    # Optional WinPE console display mode. Either an explicit "WIDTHxHEIGHT"
    # value (e.g. "1024x768") for the BCD graphicsresolution element, or the
    # special value "HIGHEST" to use bcdedit's highestmode instead (whatever
    # resolution the firmware exposes as its highest - simpler, but can make
    # text/UI unreadably tiny on high-DPI displays). Leave unset to use
    # whatever this ADK/firmware combination defaults to.
    [string]$GraphicsResolution = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$ConfirmPreference = "None"

#region --- Pre-flight checks ---------------------------------------------------

function Assert-Admin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run from an elevated (Administrator) PowerShell session."
    }
}

Assert-Admin

Write-Host "==> Clearing any stale DISM mount points before starting..." -ForegroundColor Cyan
& dism.exe /cleanup-mountpoints | Out-Null

$winPeRoot = Join-Path $AdkRoot "Windows Preinstallation Environment"
$copypeCmd = Join-Path $winPeRoot "copype.cmd"
$ocsRoot   = Join-Path $winPeRoot "$Architecture\WinPE_OCs"

if (-not (Test-Path $copypeCmd)) {
    throw "copype.cmd not found at '$copypeCmd'. Install the Windows ADK Windows PE add-on."
}
if (-not (Test-Path $ocsRoot)) {
    throw "WinPE optional components folder not found at '$ocsRoot'."
}

#endregion

#region --- Step 1: Lay out base WinPE media with copype -------------------------

Write-Host "==> Preparing working directory..." -ForegroundColor Cyan

# This host is persistent across runs (unlike an ephemeral CI container), so a
# previous run that failed AFTER mounting but BEFORE dismounting cleanly (as
# just happened) can leave boot.wim locked and this Remove-Item unable to
# proceed. Clean up any stale mount under the old WorkDir first.
$staleMountDir = Join-Path $WorkDir "mount"
$staleMount = Get-WindowsImage -Mounted -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $staleMountDir }
if ($staleMount) {
    Write-Host "==> Found stale mount from a previous run at $staleMountDir - discarding it..." -ForegroundColor Yellow
    Dismount-WindowsImage -Path $staleMountDir -Discard -ErrorAction SilentlyContinue | Out-Null
}
# Belt-and-suspenders: also clear DISM's own mount bookkeeping in case the
# above didn't fully resolve it (e.g. mount is tracked but path mismatch).
& dism.exe /cleanup-mountpoints | Out-Null

if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
if (Test-Path $WorkDir) {
    throw "Failed to fully remove stale WorkDir '$WorkDir' - some file inside it is " +
          "likely still locked (e.g. from a mount that wasn't cleanly dismounted). " +
          "Building on top of a non-empty WorkDir would explain output size growing " +
          "across runs instead of staying consistent. Investigate what's locked " +
          "before continuing (Get-WindowsImage -Mounted, or a running process with " +
          "a handle open under $WorkDir)."
}

# See Build-WinPEImage.ps1's history for why these specific env vars are set
# directly rather than relying on DandISetEnv.bat's registry lookup.
$dandIRoot = Join-Path $AdkRoot "Deployment Tools"
$env:WinPERoot       = Join-Path $AdkRoot "Windows Preinstallation Environment"
$env:WinPERootNoArch = $env:WinPERoot
$env:DISMRoot        = Join-Path $dandIRoot "$Architecture\DISM"
$env:BCDBootRoot     = Join-Path $dandIRoot "$Architecture\BCDBoot"
$env:ImagingRoot     = Join-Path $dandIRoot "$Architecture\Imaging"
$env:OSCDImgRoot     = Join-Path $dandIRoot "$Architecture\Oscdimg"
$env:WdsmcastRoot    = Join-Path $dandIRoot "$Architecture\Wdsmcast"
$env:HelpIndexerRoot = Join-Path $dandIRoot "HelpIndexer"
$env:WSIMRoot        = Join-Path $dandIRoot "WSIM"

Write-Host "==> Running copype ($Architecture) -> $WorkDir ..." -ForegroundColor Cyan
& $copypeCmd $Architecture $WorkDir
if ($LASTEXITCODE -ne 0) {
    throw "copype.cmd failed with exit code $LASTEXITCODE."
}

$mediaDir = Join-Path $WorkDir "media"
$mountDir = Join-Path $WorkDir "mount"
$bootWim  = Join-Path $mediaDir "sources\boot.wim"

if (-not (Test-Path $bootWim)) { throw "boot.wim not found at expected path: $bootWim" }
if (-not (Test-Path $mountDir)) { New-Item -ItemType Directory -Path $mountDir | Out-Null }

function Write-SizeCheckpoint {
    param([string]$Label, [string]$Path)
    $bytes = (Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    $mb = [math]::Round($bytes / 1MB, 1)
    Write-Host "    [size checkpoint] $Label : $mb MB" -ForegroundColor Magenta
}

Write-SizeCheckpoint -Label "media\ right after copype (before any DISM servicing)" -Path $mediaDir

# Workaround for a documented bug in this ADK build family (10.1.26100.x):
# copype.cmd can exit 0 without actually copying the BIOS/UEFI boot firmware
# files (etfsboot.com, efisys.bin, efisys_noprompt.bin) into the media output,
# even though it's supposed to relocate them from the ADK's own Oscdimg folder.
# Rather than trust that step, copy them ourselves directly from the known
# source if copype didn't already put them where we need them.
Write-Host "==> Verifying boot firmware files (working around a known copype.cmd bug in this ADK build)..." -ForegroundColor Cyan
$oscdimgSourceDir = Join-Path $dandIRoot "$Architecture\Oscdimg"

$firmwareFiles = @(
    @{ Source = Join-Path $oscdimgSourceDir "etfsboot.com"; Dest = Join-Path $mediaDir "boot\etfsboot.com" }
    @{ Source = Join-Path $oscdimgSourceDir "efisys.bin"; Dest = Join-Path $mediaDir "efi\microsoft\boot\efisys.bin" }
    @{ Source = Join-Path $oscdimgSourceDir "efisys_noprompt.bin"; Dest = Join-Path $mediaDir "efi\microsoft\boot\efisys_noprompt.bin" }
)

foreach ($f in $firmwareFiles) {
    if (Test-Path $f.Dest) {
        Write-Host "    already present: $($f.Dest)" -ForegroundColor DarkGray
        continue
    }
    if (-not (Test-Path $f.Source)) {
        throw "copype.cmd did not copy '$($f.Dest)', AND the fallback source " +
              "'$($f.Source)' doesn't exist either. Check this ADK installation."
    }
    Write-Host "    copype.cmd did not provide $($f.Dest) - copying from $($f.Source) directly" -ForegroundColor Yellow
    $destParent = Split-Path $f.Dest -Parent
    if (-not (Test-Path $destParent)) { New-Item -ItemType Directory -Path $destParent -Force | Out-Null }
    Copy-Item -Path $f.Source -Destination $f.Dest -Force
}

# Enable the animated Windows Boot Manager progress screen (the spinning dots
# shown before WinPE's console appears). This is controlled by the BCD store
# baked into the media, not by boot.wim itself - "bootux" turns the animation
# on, and "quietboot" (commonly set for unattended/fast-boot media) suppresses
# it entirely if left enabled. Both the BIOS and UEFI boot stores need this set
# independently, since a device could boot via either path.
Write-Host "==> Enabling boot manager animation (bootux)..." -ForegroundColor Cyan
$bcdStores = @(
    Join-Path $mediaDir "boot\BCD"
    Join-Path $mediaDir "efi\microsoft\boot\BCD"
)
foreach ($bcdStore in $bcdStores) {
    if (-not (Test-Path $bcdStore)) {
        Write-Warning "BCD store not found at '$bcdStore' - skipping (this boot path may not be present in this build)."
        continue
    }
    & bcdedit.exe /store $bcdStore /set '{default}' bootux Standard | Out-Null
    & bcdedit.exe /store $bcdStore /set '{default}' quietboot No | Out-Null

    if ($GraphicsResolution) {
        if ($GraphicsResolution -eq 'HIGHEST') {
            & bcdedit.exe /store $bcdStore /set '{default}' highestmode Yes | Out-Null
            Write-Host "    display mode: highestmode Yes" -ForegroundColor DarkCyan
        }
        else {
            # graphicsresolution needs width and height as TWO SEPARATE
            # command-line arguments (e.g. "graphicsresolution 1024 768") -
            # not one string containing a space. A single PowerShell string
            # variable passed to a native command is one argv element
            # regardless of embedded whitespace, so this must be split into
            # actual separate arguments, not just have "x" replaced with " ".
            #
            # graphicsresolution also only supports a limited, hardware-
            # dependent set of values - there's no complete authoritative
            # list, so if this doesn't visibly change anything even with the
            # arguments passed correctly, try a different value (e.g.
            # 1024x768, 1024x600, 800x600) rather than assuming it's a bug.
            $resParts = $GraphicsResolution -split 'x'
            if ($resParts.Count -ne 2) {
                throw "-GraphicsResolution must be in WIDTHxHEIGHT format (e.g. '1024x768'), got '$GraphicsResolution'."
            }
            & bcdedit.exe /store $bcdStore /set '{default}' graphicsresolution $resParts[0] $resParts[1] | Out-Null
            Write-Host "    display mode: graphicsresolution $($resParts[0]) $($resParts[1])" -ForegroundColor DarkCyan
        }
    }

    Write-Host "    updated: $bcdStore" -ForegroundColor DarkCyan
}

#endregion

#region --- Step 2: Mount boot.wim and add only the required packages -----------

Write-Host "==> Mounting boot.wim..." -ForegroundColor Cyan
Mount-WindowsImage -ImagePath $bootWim -Index 1 -Path $mountDir | Out-Null

if ($DriverPath) {
    if (-not (Test-Path $DriverPath)) {
        throw "-DriverPath '$DriverPath' not found."
    }
    Write-Host "==> Adding driver(s) from $DriverPath ..." -ForegroundColor Cyan
    try {
        Add-WindowsDriver -Path $mountDir -Driver $DriverPath -Recurse -ForceUnsigned -ErrorAction Stop | Out-Null
        Write-Host "    driver(s) added successfully." -ForegroundColor Green
    }
    catch {
        Write-Warning "Error while adding driver(s) - discarding mount changes."
        Dismount-WindowsImage -Path $mountDir -Discard -ErrorAction SilentlyContinue | Out-Null
        throw
    }
}

# Order matters - each package depends on the ones before it.
$packages = @("WinPE-WMI", "WinPE-NetFX", "WinPE-PowerShell", "WinPE-StorageWMI")

try {
    foreach ($pkg in $packages) {
        $cabPath = Join-Path $ocsRoot "$pkg.cab"

        if (-not (Test-Path $cabPath)) {
            throw "Required package not found: $cabPath"
        }

        Write-Host "==> Adding package: $pkg" -ForegroundColor Cyan
        Add-WindowsPackage -Path $mountDir -PackagePath $cabPath | Out-Null
        # Deliberately NOT adding the "_en-us" language pack cab for each
        # package - base WinPE already ships English resources built in, so
        # these are only needed to support ADDITIONAL languages. Skipping
        # them is a meaningful, safe size reduction with no functional loss
        # for an English-only unattended build.
    }

    Write-Host "==> Running component cleanup to shrink the image..." -ForegroundColor Cyan
    & dism.exe /Image:$mountDir /Cleanup-Image /StartComponentCleanup /ResetBase
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Component cleanup returned exit code $LASTEXITCODE (non-fatal - continuing)."
    }

    Write-Host "==> Saving and unmounting boot.wim..." -ForegroundColor Cyan
    Dismount-WindowsImage -Path $mountDir -Save | Out-Null
}
catch {
    Write-Warning "Error while servicing boot.wim - discarding mount changes."
    Dismount-WindowsImage -Path $mountDir -Discard -ErrorAction SilentlyContinue | Out-Null
    throw
}

Write-SizeCheckpoint -Label "media\ after DISM servicing (packages + cleanup + dismount)" -Path $mediaDir

#endregion

#region --- Step 3: Package the media folder for reuse ---------------------------

# Remove non-English boot-menu locale folders (bg-bg, cs-cz, de-de, etc.) from
# both boot paths. These hold localized text for the boot MENU specifically -
# and since efisys_noprompt.bin means no menu/prompt is ever shown at all, none
# of this is used regardless of language. Matched by culture-code-style naming
# (e.g. "xx-XX") rather than a hardcoded list, so this stays correct even if a
# future ADK version ships a different locale set. "en-us" is explicitly kept.
Write-Host "==> Removing unused non-English boot-menu locale folders..." -ForegroundColor Cyan
$localeFolderPattern = '^[a-z]{2,3}(-[a-zA-Z]{2,8})+$'
$bootLocaleRoots = @(
    Join-Path $mediaDir "Boot"
    Join-Path $mediaDir "efi\microsoft\boot"
)
foreach ($localeRoot in $bootLocaleRoots) {
    if (-not (Test-Path $localeRoot)) { continue }
    Get-ChildItem -Path $localeRoot -Directory | Where-Object {
        $_.Name -match $localeFolderPattern -and $_.Name -ne 'en-us'
    } | ForEach-Object {
        Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Note deliberately NOT included: init.ps1 / startnet.cmd changes, and no ISO is
# built here. Those steps happen per-run in Build-WinPEImage.ps1 using wimlib-
# imagex, against a fresh working copy of this same base media - keeping this
# base image-specific but init-script-agnostic, so one base build serves any
# number of differently-configured CI runs.

Write-Host "==> Clearing Hidden/System/ReadOnly attributes before zipping..." -ForegroundColor Cyan
# Compress-Archive in Windows PowerShell 5.1 silently SKIPS files with the
# Hidden or System attribute set - its internal file enumeration doesn't use
# -Force, and it produces no warning or error when this happens. ADK boot
# binaries (etfsboot.com, efisys.bin, efisys_noprompt.bin) are commonly marked
# Hidden+System, so without this, they'd be missing from the zip with zero
# indication why - exactly what happened here.
Get-ChildItem -Path $mediaDir -Recurse -Force | ForEach-Object {
    if (-not $_.PSIsContainer) { $_.Attributes = 'Normal' }
}

Write-Host "==> Zipping media folder -> $OutputZipPath ..." -ForegroundColor Cyan
$outDir = Split-Path $OutputZipPath -Parent
if ($outDir -and -not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
if (Test-Path $OutputZipPath) { Remove-Item $OutputZipPath -Force }

Compress-Archive -Path (Join-Path $mediaDir "*") -DestinationPath $OutputZipPath -CompressionLevel Optimal

# Sanity check: confirm the boot files Build-WinPEImage.ps1 will need later are
# actually present in the zip, rather than finding out on the next CI run.
Write-Host "==> Verifying critical boot files were captured in the zip..." -ForegroundColor Cyan
$verifyDir = Join-Path $WorkDir "verify-zip"
Expand-Archive -Path $OutputZipPath -DestinationPath $verifyDir -Force
$requiredFiles = @("boot\etfsboot.com", "efi\microsoft\boot\efisys_noprompt.bin")
foreach ($rel in $requiredFiles) {
    $checkPath = Join-Path $verifyDir $rel
    if (-not (Test-Path $checkPath)) {
        throw "Sanity check failed: '$rel' is missing from the zip. Check for other " +
              "Hidden/System files that may still be getting skipped."
    }
}
Remove-Item $verifyDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "==> Verified: required boot files are present in the zip." -ForegroundColor Green

$sizeMB = [math]::Round((Get-Item $OutputZipPath).Length / 1MB, 1)
Write-Host "==> Base media package created: $OutputZipPath ($sizeMB MB)" -ForegroundColor Green

#endregion

#region --- Cleanup ---------------------------------------------------------------

Write-Host "==> Cleaning up working directory..." -ForegroundColor Cyan
Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Done. Upload $OutputZipPath somewhere your CI pipeline can fetch it from" -ForegroundColor Green
Write-Host "(e.g. MinIO), then pass its URL to Build-WinPEImage.ps1's -BaseMediaUrl." -ForegroundColor Green
Write-Host "Re-run this script only when the ADK version, package list, or architecture changes." -ForegroundColor Green

#endregion
