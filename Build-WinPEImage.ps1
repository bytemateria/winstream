<#
.SYNOPSIS
    Builds a customized, no-prompt WinPE ISO from a PREBUILT base media package
    (produced by Build-WinPEBase.ps1), using wimlib-imagex instead of DISM -
    no Mount-WindowsImage, no Add-WindowsPackage, no host kernel filter-driver
    dependency. Safe to run inside a process-isolated Windows container.

.DESCRIPTION
    Build-WinPEBase.ps1 handles the one-time/occasional DISM-dependent work
    (installing WinPE-WMI/NetFX/PowerShell/StorageWMI into boot.wim) on a real
    Windows host, and produces a reusable zipped media\ folder. This script
    takes that prebuilt package and, on every CI run:
      1. Fetches and extracts the base media package (from -BaseMediaUrl or a
         local -BaseMediaPath) into a fresh working copy.
      2. Renders init.ps1 from the external template (same token substitution
         as before) and injects it into boot.wim via wimlib-imagex.
      3. Extracts startnet.cmd from boot.wim, appends the init.ps1 launch line
         locally, and writes it back via wimlib-imagex - all in user mode, no
         kernel driver of any kind involved.
      4. Rebuilds a bootable ISO with oscdimg using efisys_noprompt.bin (the
         file that actually removes the "Press any key to boot..." prompt on
         UEFI; BIOS boot via etfsboot.com never shows it).

.REQUIREMENTS
    - wimlib-imagex.exe (https://wimlib.net/) - works in a container, no
      wimmount/filter-driver dependency.
    - oscdimg.exe (from the Windows ADK Deployment Tools).
    - Does NOT require: DISM, Mount-WindowsImage, Add-WindowsPackage, or
      Administrator privileges - none of the operations here need them.

.PARAMETER OutputIsoPath
    Path where the WinPE ISO will be written.

.PARAMETER BaseMediaUrl
    HTTP(S) URL to the zipped base media package produced by
    Build-WinPEBase.ps1. Mutually exclusive with -BaseMediaPath.

.PARAMETER BaseMediaPath
    Local path to an already-extracted base media folder, or to the zip file
    itself. Mutually exclusive with -BaseMediaUrl.

.PARAMETER WindowsIsoUrl
    HTTP(S) URL the init script will download the target Windows ISO from at
    boot time.

.PARAMETER ImageIndex
    Index inside the downloaded ISO's install.wim/install.esd to apply.

.PARAMETER TargetDiskNumber
    Disk number to install to, or "AUTO" (default) to let the init script pick
    the first non-USB fixed disk it finds at boot time.

.PARAMETER UnattendXmlUrl
    Optional HTTP(S) URL to an autounattend.xml copied to
    C:\Windows\Panther\unattend.xml after the image is applied.

.PARAMETER BackgroundImagePath
    Optional local path to a JPEG file to use as the WinPE boot background,
    replacing the default winpe.jpg at \Windows\System32\winpe.jpg in
    boot.wim. Must be a .jpg/.jpeg file - WinPE only supports JPEG for this.

.PARAMETER InitTemplatePath
    Path to the init script template. Defaults to
    "init.download-install.template.ps1" next to this script.

.PARAMETER WimlibImagexPath
    Path to wimlib-imagex.exe. Defaults to assuming it's on PATH.

.PARAMETER OscdimgPath
    Path to oscdimg.exe.

.EXAMPLE
    .\Build-WinPEImage.ps1 `
        -OutputIsoPath "D:\ISOs\WinPE-AutoInstall.iso" `
        -BaseMediaUrl "https://storage.example.com/winpe-base-amd64.zip" `
        -WindowsIsoUrl "https://storage.example.com/WinServer2025.iso" `
        -ImageIndex 4 `
        -UnattendXmlUrl "https://storage.example.com/autounattend.xml"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputIsoPath,

    [string]$BaseMediaUrl = "",
    [string]$BaseMediaPath = "",

    [Parameter(Mandatory = $true)]
    [string]$WindowsIsoUrl,

    [int]$ImageIndex = 4,

    [string]$TargetDiskNumber = "AUTO",

    [string]$UnattendXmlUrl = "",

    [string]$BackgroundImagePath = "",

    [string]$InitTemplatePath = "",

    [string]$WimlibImagexPath = "wimlib-imagex.exe",

    [string]$OscdimgPath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",

    [string]$WorkDir = (Join-Path $env:TEMP "WinPEImageBuild"),

    [string]$VolumeLabel = "MINWINPE"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

#region --- Resolve script directory (do not rely on $PSScriptRoot alone) -------

$ScriptDir =
    if ($PSScriptRoot) { $PSScriptRoot }
    elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
    else { $null }

if ([string]::IsNullOrWhiteSpace($InitTemplatePath)) {
    if (-not $ScriptDir) {
        throw "Could not determine this script's directory automatically. Pass -InitTemplatePath explicitly."
    }
    $InitTemplatePath = Join-Path $ScriptDir "\src\init.download-install.template.ps1"
}

#endregion

#region --- Pre-flight checks ---------------------------------------------------

if ([string]::IsNullOrWhiteSpace($BaseMediaUrl) -and [string]::IsNullOrWhiteSpace($BaseMediaPath)) {
    throw "Pass either -BaseMediaUrl or -BaseMediaPath (the output of Build-WinPEBase.ps1)."
}
if (-not [string]::IsNullOrWhiteSpace($BaseMediaUrl) -and -not [string]::IsNullOrWhiteSpace($BaseMediaPath)) {
    throw "Pass only one of -BaseMediaUrl or -BaseMediaPath, not both."
}
if (-not (Test-Path $OscdimgPath)) {
    throw "oscdimg.exe not found at '$OscdimgPath'."
}
if (-not (Get-Command $WimlibImagexPath -ErrorAction SilentlyContinue) -and -not (Test-Path $WimlibImagexPath)) {
    throw "wimlib-imagex not found ('$WimlibImagexPath'). Install it from https://wimlib.net/ " +
          "or pass -WimlibImagexPath pointing to the executable."
}
if (-not (Test-Path $InitTemplatePath)) {
    throw "Init script template not found at '$InitTemplatePath'."
}
if ($BackgroundImagePath) {
    if (-not (Test-Path $BackgroundImagePath)) {
        throw "-BackgroundImagePath '$BackgroundImagePath' not found."
    }
    if ($BackgroundImagePath -notmatch '\.jpe?g$') {
        throw "-BackgroundImagePath must be a .jpg/.jpeg file - WinPE only supports JPEG for winpe.jpg."
    }
}

#endregion

#region --- Step 1: Fetch and stage the prebuilt base media ----------------------

Write-Host "==> Preparing working directory..." -ForegroundColor Cyan
if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
New-Item -ItemType Directory -Path $WorkDir | Out-Null

$mediaDir = Join-Path $WorkDir "media"

if ($BaseMediaUrl) {
    Write-Host "==> Downloading base media package from $BaseMediaUrl ..." -ForegroundColor Cyan
    $zipPath = Join-Path $WorkDir "base-media.zip"
    Invoke-WebRequest -Uri $BaseMediaUrl -OutFile $zipPath -UseBasicParsing
    Write-Host "==> Extracting base media package..." -ForegroundColor Cyan
    Expand-Archive -Path $zipPath -DestinationPath $mediaDir -Force
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
}
else {
    if ((Get-Item $BaseMediaPath).PSIsContainer) {
        Write-Host "==> Copying base media folder from $BaseMediaPath ..." -ForegroundColor Cyan
        Copy-Item -Path (Join-Path $BaseMediaPath "*") -Destination $mediaDir -Recurse -Container
    }
    elseif ($BaseMediaPath -match '\.zip$') {
        Write-Host "==> Extracting base media package from $BaseMediaPath ..." -ForegroundColor Cyan
        Expand-Archive -Path $BaseMediaPath -DestinationPath $mediaDir -Force
    }
    else {
        throw "-BaseMediaPath must be either a directory or a .zip file."
    }
}

# The base package is read-only-ish in spirit (shared/reused across many CI
# runs), so make sure our working copy is actually writable before wimlib
# tries to modify boot.wim in place.
Get-ChildItem -Path $mediaDir -Recurse | ForEach-Object {
    if (-not $_.PSIsContainer) { $_.Attributes = 'Normal' }
}

$bootWim = Join-Path $mediaDir "sources\boot.wim"
if (-not (Test-Path $bootWim)) {
    throw "boot.wim not found at expected path: $bootWim. Check the base media package contents."
}

#endregion

#region --- Step 2: Render the init script from the external template -----------

Write-Host "==> Rendering init script from template: $InitTemplatePath" -ForegroundColor Cyan

$template = Get-Content -Path $InitTemplatePath -Raw
$rendered = $template.Replace('__WINDOWS_ISO_URL__', $WindowsIsoUrl)
$rendered = $rendered.Replace('__IMAGE_INDEX__', [string]$ImageIndex)
$rendered = $rendered.Replace('__TARGET_DISK_NUMBER__', $TargetDiskNumber)
$rendered = $rendered.Replace('__UNATTEND_XML_URL__', $UnattendXmlUrl)

$renderedInitPath = Join-Path $WorkDir "init.ps1"
$rendered | Out-File -FilePath $renderedInitPath -Encoding utf8 -Force

#endregion

#region --- Step 3: Inject init.ps1 and update startnet.cmd via wimlib-imagex ----

# All of this is user-mode WIM file manipulation - no kernel filter driver,
# no Mount-WindowsImage, no Administrator privileges required. This is the
# entire point of splitting the DISM-dependent packaging step out into
# Build-WinPEBase.ps1: everything below is safe inside a container.

Write-Host "==> Injecting init.ps1 into boot.wim via wimlib-imagex..." -ForegroundColor Cyan
$addInitCommand = "add `"$renderedInitPath`" `"\Windows\System32\init.ps1`""
& $WimlibImagexPath update $bootWim 1 --command=$addInitCommand
if ($LASTEXITCODE -ne 0) {
    throw "wimlib-imagex failed to add init.ps1 (exit code $LASTEXITCODE)."
}

if ($BackgroundImagePath) {
    # Replaces the default WinPE boot background (Windows\System32\winpe.jpg).
    # The DISM-mounted-directory approach documented by Microsoft needs a
    # takeown/icacls dance first, since that file has restrictive ACLs by
    # default - wimlib's "add" replaces the WIM catalog entry directly using
    # our local file's own permissions, sidestepping that entirely.
    Write-Host "==> Replacing WinPE boot background with $BackgroundImagePath ..." -ForegroundColor Cyan
    $addBackgroundCommand = "add `"$BackgroundImagePath`" `"\Windows\System32\winpe.jpg`""
    & $WimlibImagexPath update $bootWim 1 --command=$addBackgroundCommand
    if ($LASTEXITCODE -ne 0) {
        throw "wimlib-imagex failed to replace winpe.jpg (exit code $LASTEXITCODE)."
    }
}

Write-Host "==> Extracting startnet.cmd to append the init.ps1 launch line..." -ForegroundColor Cyan
$extractDir = Join-Path $WorkDir "extracted"
New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

& $WimlibImagexPath extract $bootWim 1 "\Windows\System32\startnet.cmd" "--dest-dir=$extractDir"
if ($LASTEXITCODE -ne 0) {
    throw "wimlib-imagex failed to extract startnet.cmd (exit code $LASTEXITCODE)."
}

$extractedStartnet = Join-Path $extractDir "startnet.cmd"
if (-not (Test-Path $extractedStartnet)) {
    throw "startnet.cmd was not found at the expected extracted path: $extractedStartnet"
}

# startnet.cmd is what WinPE runs automatically at boot (via wpeinit) - so
# appending here means: initialize network/PnP first, then run our script.
# No shell prompt is ever shown to an operator.
Add-Content -Path $extractedStartnet -Value "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File %SYSTEMROOT%\System32\init.ps1"

Write-Host "==> Writing updated startnet.cmd back into boot.wim..." -ForegroundColor Cyan
$updateStartnetCommand = "add `"$extractedStartnet`" `"\Windows\System32\startnet.cmd`""
& $WimlibImagexPath update $bootWim 1 --command=$updateStartnetCommand
if ($LASTEXITCODE -ne 0) {
    throw "wimlib-imagex failed to update startnet.cmd (exit code $LASTEXITCODE)."
}

Write-Host "==> init.ps1 and startnet.cmd successfully updated in boot.wim" -ForegroundColor Green

#endregion

#region --- Step 4: Rebuild bootable ISO, no "press any key" prompt --------------

Write-Host "==> Building ISO with oscdimg..." -ForegroundColor Cyan

$etfsboot = Join-Path $mediaDir "boot\etfsboot.com"
$efisysNoPrompt = Join-Path $mediaDir "efi\microsoft\boot\efisys_noprompt.bin"

if (-not (Test-Path $etfsboot)) {
    throw "BIOS boot file not found: $etfsboot"
}
if (-not (Test-Path $efisysNoPrompt)) {
    # Required, not optional: efisys.bin (without _noprompt) is what causes
    # "Press any key to boot from CD or DVD..." on UEFI systems.
    throw "efisys_noprompt.bin not found at '$efisysNoPrompt'. Check the base media package."
}

$outDir = Split-Path $OutputIsoPath -Parent
if ($outDir -and -not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
if (Test-Path $OutputIsoPath) { Remove-Item $OutputIsoPath -Force }

$bootData = "2#p0,e,b$etfsboot#pEF,e,b$efisysNoPrompt"

& $OscdimgPath -m -o -u2 -udfver102 -bootdata:$bootData -l"$VolumeLabel" $mediaDir $OutputIsoPath
Write-Host "-l$VolumeLabel"
if ($LASTEXITCODE -ne 0) {
    throw "oscdimg failed to build the ISO (exit code $LASTEXITCODE)."
}

Write-Host "==> WinPE ISO created at: $OutputIsoPath" -ForegroundColor Green
$sizeMB = [math]::Round((Get-Item $OutputIsoPath).Length / 1MB, 1)
Write-Host "==> Final ISO size: $sizeMB MB" -ForegroundColor Green

#endregion

#region --- Cleanup ---------------------------------------------------------------

Write-Host "==> Cleaning up working directory..." -ForegroundColor Cyan
Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Done. Booting a device from '$OutputIsoPath' will, with no key presses:" -ForegroundColor Green
Write-Host "  1. Boot straight into WinPE (no 'press any key' prompt on UEFI or BIOS)"
Write-Host "  2. Auto-run init.ps1 via startnet.cmd once wpeinit brings up networking"
Write-Host "  3. Download $WindowsIsoUrl"
Write-Host "  4. Partition/format the target disk and apply image index $ImageIndex"
Write-Host "  5. Run bcdboot and reboot into the newly installed OS"

#endregion
