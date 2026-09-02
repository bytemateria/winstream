# =============================================================================
# init.ps1 - runs automatically inside WinPE via startnet.cmd (after wpeinit).
# Downloads a Windows ISO, partitions the target disk, applies the image,
# sets up boot files, and (optionally) drops an unattend.xml for first boot.
#
# Rendered from init.download-install.template.ps1 by Build-WinPEImage.ps1.
# Tokens substituted at build time:
#   __WINDOWS_ISO_URL__     - HTTP(S) URL to the Windows ISO to install
#   __IMAGE_INDEX__         - index inside install.wim/install.esd to apply
#   __TARGET_DISK_NUMBER__  - disk number to install to, or AUTO to pick the
#                             first non-USB fixed disk
#   __UNATTEND_XML_URL__    - optional HTTP(S) URL to an autounattend.xml
#                             (e.g. built by Build-WinServerImage.ps1) copied
#                             to C:\Windows\Panther\unattend.xml so specialize/
#                             oobe continues unattended on first real boot.
#                             Leave empty in the build script to skip this.
# =============================================================================

$ErrorActionPreference = "Stop"

$IsoUrl            = "__WINDOWS_ISO_URL__"
$ImageIndex        = "__IMAGE_INDEX__"
$TargetDiskNumber  = "__TARGET_DISK_NUMBER__"
$UnattendXmlUrl    = "__UNATTEND_XML_URL__"

$LogPath = "X:\init-install.log"

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line
    Add-Content -Path $LogPath -Value $line
}

function Wait-ForNetwork {
    Write-Log "Waiting for network connectivity..."
    $maxAttempts = 30
    for ($i = 1; $i -le $maxAttempts; $i++) {
        # wpeinit already ran via startnet.cmd, but DHCP can take a moment.
        # Test-NetConnection depends on the NetTCPIP PowerShell module, which
        # is NOT part of minimal WinPE (WinPE-PowerShell gives you the engine,
        # not the full module library a real Windows install has) - use a raw
        # .NET Ping instead, which only needs WinPE-NetFX (already installed).
        try {
            $ping = New-Object System.Net.NetworkInformation.Ping
            $reply = $ping.Send("8.8.8.8", 2000)
            if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                Write-Log "Network is up (attempt $i)."
                return
            }
        }
        catch {
            # Network stack not ready yet - fall through to retry.
        }
        Start-Sleep -Seconds 2
    }
    throw "Network did not come up after $maxAttempts attempts. Check NIC drivers / DHCP."
}

function Select-TargetDisk {
    param([string]$RequestedDiskNumber)

    if ($RequestedDiskNumber -ne "AUTO") {
        $disk = Get-Disk -Number ([int]$RequestedDiskNumber)
        Write-Log "Using explicitly requested disk $($disk.Number) ($([math]::Round($disk.Size/1GB,1)) GB)."
        return $disk
    }

    $candidate = Get-Disk |
        Where-Object { $_.BusType -ne 'USB' -and $_.IsBoot -ne $true -and $_.OperationalStatus -eq 'Online' } |
        Sort-Object Number |
        Select-Object -First 1

    if (-not $candidate) {
        throw "Could not auto-select a target disk. Pass an explicit -TargetDiskNumber to the build script."
    }

    Write-Log "Auto-selected disk $($candidate.Number) ($([math]::Round($candidate.Size/1GB,1)) GB, BusType=$($candidate.BusType)) as install target."
    return $candidate
}

function Initialize-TargetDisk {
    param([Microsoft.Management.Infrastructure.CimInstance]$Disk)

    # Unconditional diskpart "clean" pass as the very first step, before any
    # of the PowerShell Storage cmdlet logic below runs. This matches a
    # manual step that's proven necessary/helpful on real hardware in
    # practice - a quick, forceful reset before the rest of the (already
    # more defensive/retrying) cleanup logic takes over.
    Write-Log "Running an initial 'diskpart clean' pass on disk $($Disk.Number)..."
    $initialDiskpartScript = @"
select disk $($Disk.Number)
clean
exit
"@
    $initialDiskpartScriptPath = Join-Path $env:TEMP "diskpart-initial-clean.txt"
    $initialDiskpartScript | Out-File -FilePath $initialDiskpartScriptPath -Encoding ascii -Force

    $initialDiskpartOutput = & diskpart.exe /s $initialDiskpartScriptPath
    $initialDiskpartOutput | ForEach-Object { Write-Log "  diskpart: $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  WARNING: initial diskpart clean exited with code $LASTEXITCODE - continuing anyway, the cleanup logic below will retry/verify."
    }
    Remove-Item -Path $initialDiskpartScriptPath -Force -ErrorAction SilentlyContinue

    # WinPE's default SAN policy (and leftover state from a disk's previous
    # life - BitLocker, Storage Spaces, dynamic disks, etc.) can leave a real
    # physical disk marked Offline or ReadOnly. Clear both explicitly before
    # touching it.
    $currentDiskState = Get-Disk -Number $Disk.Number
    Write-Log "Disk $($Disk.Number) state: PartitionStyle=$($currentDiskState.PartitionStyle), IsOffline=$($currentDiskState.IsOffline), IsReadOnly=$($currentDiskState.IsReadOnly), OperationalStatus=$($currentDiskState.OperationalStatus), BusType=$($currentDiskState.BusType)"
    if ($currentDiskState.IsOffline) {
        Write-Log "Disk $($Disk.Number) is offline - bringing it online..."
        Set-Disk -Number $Disk.Number -IsOffline $false
    }
    if ($currentDiskState.IsReadOnly) {
        Write-Log "Disk $($Disk.Number) is read-only - clearing read-only flag..."
        Set-Disk -Number $Disk.Number -IsReadOnly $false
    }

    Write-Log "Partition layout on disk $($Disk.Number) BEFORE cleanup:"
    $existingPartitions = Get-Partition -DiskNumber $Disk.Number -ErrorAction SilentlyContinue
    $existingPartitions | ForEach-Object { Write-Log "  Partition $($_.PartitionNumber): Type=$($_.Type), Size=$([math]::Round($_.Size/1MB,0))MB" }

    if ($existingPartitions) {
        Write-Log "Removing $($existingPartitions.Count) existing partition(s) individually..."
        foreach ($partition in $existingPartitions) {
            try {
                Remove-Partition -DiskNumber $Disk.Number -PartitionNumber $partition.PartitionNumber -Confirm:$false -ErrorAction Stop
                Write-Log "  Removed partition $($partition.PartitionNumber)."
            }
            catch {
                Write-Log "  WARNING: Failed to remove partition $($partition.PartitionNumber): $($_.Exception.Message)"
            }
        }
    }

    try {
        Clear-Disk -Number $Disk.Number -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
    }
    catch {
        Write-Log "Clear-Disk (backstop) reported: $($_.Exception.Message)"
    }

    # Previously this checked exactly once after a single Update-Disk +
    # 2-second sleep. This time, retry repeatedly (rescanning each attempt)
    # before concluding the disk genuinely still has partitions - the earlier
    # single-check approach may simply not have waited long enough.
    Write-Log "Waiting for disk $($Disk.Number) to report clean (retrying with rescans)..."
    $maxCleanAttempts = 15
    $isClean = $false
    for ($attempt = 1; $attempt -le $maxCleanAttempts; $attempt++) {
        Update-Disk -Number $Disk.Number -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        $remainingPartitions = Get-Partition -DiskNumber $Disk.Number -ErrorAction SilentlyContinue
        if (-not $remainingPartitions) {
            Write-Log "  Disk reports clean after $attempt attempt(s)."
            $isClean = $true
            break
        }
        Write-Log "  Attempt $attempt/${maxCleanAttempts}: still $($remainingPartitions.Count) partition(s) present - retrying..."
    }

    if (-not $isClean) {
        $remainingPartitions | ForEach-Object { Write-Log "  Partition $($_.PartitionNumber): Type=$($_.Type), Size=$([math]::Round($_.Size/1MB,0))MB" }
        throw "Disk $($Disk.Number) still has partitions after $maxCleanAttempts cleanup retries - cannot safely proceed. " +
              "Check whether one is protected (e.g. by BitLocker) or the disk is otherwise locked."
    }

    $diskAfterClear = Get-Disk -Number $Disk.Number
    if ($diskAfterClear.PartitionStyle -eq 'RAW') {
        Initialize-Disk -Number $Disk.Number -PartitionStyle GPT
    }
    else {
        Write-Log "Disk $($Disk.Number) PartitionStyle is '$($diskAfterClear.PartitionStyle)' (not RAW) after cleanup - skipping Initialize-Disk."
    }

    Write-Log "Creating EFI System Partition..."
    $esp = New-Partition -DiskNumber $Disk.Number -Size 260MB `
        -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -AssignDriveLetter -ErrorAction Stop
    if (-not $esp) {
        throw "New-Partition returned nothing for the EFI System Partition on disk $($Disk.Number)."
    }
    Format-Volume -Partition $esp -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false | Out-Null

    Write-Log "Creating Microsoft Reserved Partition..."
    New-Partition -DiskNumber $Disk.Number -Size 16MB `
        -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' -ErrorAction Stop | Out-Null

    Write-Log "Creating Windows partition (remaining space)..."
    $winPart = New-Partition -DiskNumber $Disk.Number -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
    if (-not $winPart) {
        throw "New-Partition returned nothing for the Windows partition on disk $($Disk.Number)."
    }
    Format-Volume -Partition $winPart -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false | Out-Null

    return [PSCustomObject]@{
        EspDriveLetter = $esp.DriveLetter
        WinDriveLetter = $winPart.DriveLetter
    }
}

function Get-DownloadTempPath {
    param([string]$WinDriveLetter)
    # Stage the ISO on the freshly formatted Windows partition - it has room,
    # unlike the RAM-backed X: drive WinPE itself runs from.
    return "$($WinDriveLetter):\install-source.iso"
}

# -----------------------------------------------------------------------------
# Progress window - a real WinForms window (title + status text + progress
# bar) shown throughout the install, similar in spirit to what MDT's Lite
# Touch wizard or SCCM's Task Sequence UI show (not the actual SCCM component
# itself, which is licensed ConfigMgr infrastructure - this is a from-scratch
# equivalent using WinPE-NetFX, already installed).
#
# Runs in its own background runspace with its own message loop
# ([System.Windows.Forms.Application]::Run), so it stays responsive even
# while the main thread is blocked in a long native call (dism /Apply-Image,
# Format-Volume, etc.) that wouldn't otherwise yield control back to a
# same-thread message pump. Cross-thread updates go through Control.Invoke,
# WinForms' own designed-for-this mechanism - NOT a workaround.
#
# Every function here is wrapped so that if WinForms fails to load or the
# window fails to create for any reason, the install continues normally
# without it - this is a cosmetic feature and must never be able to abort
# or hang the actual install.
# -----------------------------------------------------------------------------

function Start-ProgressWindow {
    param([string]$Title = "Windows Setup")

    try {
        $syncHash = [hashtable]::Synchronized(@{ Ready = $false })

        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.ApartmentState = "STA"
        $runspace.ThreadOptions = "ReuseThread"
        $runspace.Open()
        $runspace.SessionStateProxy.SetVariable('sync', $syncHash)
        $runspace.SessionStateProxy.SetVariable('titleText', $Title)

        $ps = [powershell]::Create()
        $ps.Runspace = $runspace
        [void]$ps.AddScript({
            Add-Type -AssemblyName System.Windows.Forms
            Add-Type -AssemblyName System.Drawing

            $form = New-Object System.Windows.Forms.Form
            $form.Text = $titleText
            $form.Size = New-Object System.Drawing.Size(640, 220)
            $form.StartPosition = "CenterScreen"
            $form.FormBorderStyle = "FixedDialog"
            $form.ControlBox = $false
            $form.MaximizeBox = $false
            $form.MinimizeBox = $false
            $form.BackColor = [System.Drawing.Color]::Black
            $form.TopMost = $true

            $titleLabel = New-Object System.Windows.Forms.Label
            $titleLabel.Text = $titleText
            $titleLabel.ForeColor = [System.Drawing.Color]::White
            $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
            $titleLabel.AutoSize = $false
            $titleLabel.Size = New-Object System.Drawing.Size(600, 35)
            $titleLabel.Location = New-Object System.Drawing.Point(20, 30)
            $form.Controls.Add($titleLabel)

            $statusLabel = New-Object System.Windows.Forms.Label
            $statusLabel.Text = "Preparing..."
            $statusLabel.ForeColor = [System.Drawing.Color]::LightGray
            $statusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
            $statusLabel.AutoSize = $false
            $statusLabel.Size = New-Object System.Drawing.Size(600, 25)
            $statusLabel.Location = New-Object System.Drawing.Point(20, 110)
            $form.Controls.Add($statusLabel)

            $progressBar = New-Object System.Windows.Forms.ProgressBar
            $progressBar.Location = New-Object System.Drawing.Point(20, 145)
            $progressBar.Size = New-Object System.Drawing.Size(600, 24)
            $progressBar.Minimum = 0
            $progressBar.Maximum = 100
            $progressBar.Style = "Continuous"
            $form.Controls.Add($progressBar)

            $sync.Form = $form
            $sync.TitleLabel = $titleLabel
            $sync.StatusLabel = $statusLabel
            $sync.ProgressBar = $progressBar
            $sync.Ready = $true

            [System.Windows.Forms.Application]::Run($form)
        })
        $asyncResult = $ps.BeginInvoke()

        # Wait briefly for the form/controls to actually be created before
        # returning - but never indefinitely, since a cosmetic feature must
        # never be able to hang the install if something goes wrong here.
        $waited = 0
        while (-not $syncHash.Ready -and $waited -lt 5000) {
            Start-Sleep -Milliseconds 50
            $waited += 50
        }

        if (-not $syncHash.Ready) {
            Write-Log "Progress window did not initialize in time - continuing without it."
            return $null
        }

        return [PSCustomObject]@{
            SyncHash    = $syncHash
            PowerShell  = $ps
            AsyncResult = $asyncResult
        }
    }
    catch {
        Write-Log "Progress window failed to start ($($_.Exception.Message)) - continuing without it."
        return $null
    }
}

function Set-ProgressStatus {
    param(
        [Parameter()]$Handle,
        [Parameter(Mandatory)][string]$Status,
        [int]$PercentComplete = -1
    )
    if (-not $Handle) { return }
    try {
        $sync = $Handle.SyncHash
        if ($sync.Form -and -not $sync.Form.IsDisposed) {
            # BeginInvoke (not Invoke) - Invoke is SYNCHRONOUS and blocks the
            # calling thread until the UI thread actually processes the
            # update, which stalls the download loop on every throttled call.
            # BeginInvoke queues the update and returns immediately - but
            # because it's deferred, this function's local scope (and its
            # $sync/$Status/$PercentComplete variables) can be gone by the
            # time the queued action actually runs on the UI thread later.
            # PowerShell scriptblocks resolve variables against the scope
            # chain AT EXECUTION TIME, not at creation time, so without
            # .GetNewClosure() the deferred action can end up resolving
            # $sync to nothing valid - exactly the "property 'Text' cannot
            # be found" error this caused. GetNewClosure() bakes an
            # independent, stable snapshot of these variables into the
            # scriptblock right now, before it's queued.
            $updateAction = {
                $sync.StatusLabel.Text = $Status
                if ($PercentComplete -ge 0) {
                    $sync.ProgressBar.Value = [Math]::Min(100, [Math]::Max(0, $PercentComplete))
                }
            }.GetNewClosure()
            $sync.Form.BeginInvoke([Action]$updateAction) | Out-Null
        }
    }
    catch {
        # Non-fatal - the window is cosmetic, never let an update failure
        # affect the actual install.
    }
}

function Close-ProgressWindow {
    param([Parameter()]$Handle)
    if (-not $Handle) { return }
    try {
        $sync = $Handle.SyncHash
        if ($sync.Form -and -not $sync.Form.IsDisposed) {
            $sync.Form.Invoke([Action]{ $sync.Form.Close() })
        }
        $Handle.PowerShell.Stop()
        $Handle.PowerShell.Dispose()
    }
    catch {
        # Non-fatal cleanup - nothing to do if this fails.
    }
}

function Dismount-BootUsbMedia {
    # This media boots via ramdisk (device: ramdisk=[boot]\sources\boot.wim
    # in the BCD - confirmed earlier), meaning the entire WinPE OS is loaded
    # into RAM at boot time and does not need continued access to the
    # physical USB stick afterward. It's safe to eject it programmatically
    # here, right before reboot - this also makes it less likely the
    # firmware re-selects the same USB stick as a boot device on restart,
    # complementing the {fwbootmgr} displayorder fix already in place.
    #
    # Best-effort only: wrapped so a failure here can never block the actual
    # reboot from happening.
    try {
        $usbDisks = Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.BusType -eq 'USB' }
        if (-not $usbDisks) {
            Write-Log "No USB disk found to eject (nothing to do)."
            return
        }
        foreach ($usbDisk in $usbDisks) {
            $usbPartitions = Get-Partition -DiskNumber $usbDisk.Number -ErrorAction SilentlyContinue |
                Where-Object { $_.DriveLetter }
            foreach ($partition in $usbPartitions) {
                $driveLetter = $partition.DriveLetter
                Write-Log "Ejecting USB boot media at ${driveLetter}: (disk $($usbDisk.Number))..."
                $shell = New-Object -ComObject Shell.Application
                $shell.Namespace(17).ParseName("${driveLetter}:").InvokeVerb("Eject")
                Start-Sleep -Seconds 2
            }
        }
    }
    catch {
        Write-Log "WARNING: Failed to eject USB boot media: $($_.Exception.Message) (non-fatal, continuing)."
    }
}

function Invoke-DownloadWithProgress {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [Parameter()]$ProgressWindow
    )

    # Invoke-WebRequest gives no useful visual feedback for a multi-GB download -
    # this reads the response stream manually in chunks and reports real progress
    # via Write-Progress, which renders as a proper loading bar in WinPE's console
    # (this is an interactive session on the machine being provisioned, unlike a
    # headless CI pipeline, so Write-Progress rendering is exactly what we want
    # here rather than something to suppress).
    $request = [System.Net.HttpWebRequest]::Create($Uri)
    # HttpWebRequest's defaults are built for small/fast requests, not a
    # multi-GB ISO download: Timeout defaults to 100 seconds for the ENTIRE
    # request (not per-chunk), and ReadWriteTimeout defaults to 5 minutes per
    # individual stream read. Both would kill this download on perfectly fine
    # hardware/network just because it legitimately takes longer than that.
    $request.Timeout = [System.Threading.Timeout]::Infinite
    $request.ReadWriteTimeout = [System.Threading.Timeout]::Infinite
    $response = $request.GetResponse()
    $totalBytes = $response.ContentLength
    Write-Log "Server reported Content-Length: $totalBytes bytes $(if ($totalBytes -le 0) { '(unknown/chunked - progress will show MB downloaded without a percentage)' })"
    $responseStream = $response.GetResponseStream()
    $targetStream = New-Object System.IO.FileStream($OutFile, [System.IO.FileMode]::Create)
    $buffer = New-Object byte[] 1MB
    $totalRead = 0
    $lastReportedMB = -1
    $lastReportTime = Get-Date

    try {
        do {
            $read = $responseStream.Read($buffer, 0, $buffer.Length)
            if ($read -gt 0) {
                $targetStream.Write($buffer, 0, $read)
                $totalRead += $read

                # Throttle updates to a few times a second - Write-Progress on
                # every 1MB chunk of a multi-GB file would otherwise flood the
                # console with redraws.
                if (((Get-Date) - $lastReportTime).TotalMilliseconds -gt 200) {
                    $lastReportTime = Get-Date
                    $mbRead = [math]::Round($totalRead / 1MB, 0)

                    if ($totalBytes -gt 0) {
                        # Known size - show a real percentage.
                        $percent = [math]::Min(100, [math]::Floor(($totalRead / $totalBytes) * 100))
                        $mbTotal = [math]::Round($totalBytes / 1MB, 0)
                        Write-Progress -Activity "Downloading Windows ISO" `
                            -Status "$mbRead MB / $mbTotal MB ($percent%)" `
                            -PercentComplete $percent
                        Set-ProgressStatus -Handle $ProgressWindow `
                            -Status "Downloading Windows image... $mbRead MB / $mbTotal MB" `
                            -PercentComplete $percent
                    }
                    elseif ($mbRead -ne $lastReportedMB) {
                        # Unknown size (no Content-Length / chunked response) -
                        # still show something moving rather than nothing at
                        # all. -PercentComplete is required by Write-Progress,
                        # so cycle it to at least visibly animate.
                        $lastReportedMB = $mbRead
                        $spinPercent = $mbRead % 100
                        Write-Progress -Activity "Downloading Windows ISO" `
                            -Status "$mbRead MB downloaded (server didn't report a total size)" `
                            -PercentComplete $spinPercent
                        Set-ProgressStatus -Handle $ProgressWindow `
                            -Status "Downloading Windows image... $mbRead MB" `
                            -PercentComplete $spinPercent
                    }
                }
            }
        } while ($read -gt 0)
    }
    finally {
        $targetStream.Close()
        $responseStream.Close()
        $response.Close()
        Write-Progress -Activity "Downloading Windows ISO" -Completed
    }
}

# --- Main -------------------------------------------------------------------

$progressWindow = Start-ProgressWindow -Title "Windows Setup"

try {
    Write-Log "=== Automated Windows install starting ==="
    Set-ProgressStatus -Handle $progressWindow -Status "Starting..." -PercentComplete 0

    Wait-ForNetwork
    Set-ProgressStatus -Handle $progressWindow -Status "Network connected." -PercentComplete 5

    $disk = Select-TargetDisk -RequestedDiskNumber $TargetDiskNumber
    Set-ProgressStatus -Handle $progressWindow -Status "Preparing disk..." -PercentComplete 10
    $layout = Initialize-TargetDisk -Disk $disk
    Set-ProgressStatus -Handle $progressWindow -Status "Disk prepared." -PercentComplete 15

    $isoDestPath = Get-DownloadTempPath -WinDriveLetter $layout.WinDriveLetter
    Write-Log "Downloading Windows ISO from $IsoUrl to $isoDestPath ..."
    Set-ProgressStatus -Handle $progressWindow -Status "Downloading Windows image..." -PercentComplete 15
    # The download's own progress reporting drives this window from 15-70%
    # internally via the -ProgressWindow parameter below.
    Invoke-DownloadWithProgress -Uri $IsoUrl -OutFile $isoDestPath -ProgressWindow $progressWindow

    Write-Log "Mounting downloaded ISO..."
    Set-ProgressStatus -Handle $progressWindow -Status "Mounting downloaded image..." -PercentComplete 70
    $mountResult = Mount-DiskImage -ImagePath $isoDestPath -PassThru
    $isoVolume = $mountResult | Get-Volume
    $isoDriveLetter = $isoVolume.DriveLetter

    $wimPath = "$($isoDriveLetter):\sources\install.wim"
    if (-not (Test-Path $wimPath)) {
        $wimPath = "$($isoDriveLetter):\sources\install.esd"
    }
    if (-not (Test-Path $wimPath)) {
        throw "Neither install.wim nor install.esd found on the downloaded ISO."
    }

    $applyTarget = "$($layout.WinDriveLetter):\"
    Write-Log "Applying image index $ImageIndex from $wimPath to $applyTarget (this takes a while)..."
    Set-ProgressStatus -Handle $progressWindow -Status "Applying Windows image (this takes a while)..." -PercentComplete 75
    & dism.exe /Apply-Image /ImageFile:"$wimPath" /Index:$ImageIndex /ApplyDir:"$applyTarget"
    if ($LASTEXITCODE -ne 0) {
        throw "dism.exe /Apply-Image failed with exit code $LASTEXITCODE."
    }
    Set-ProgressStatus -Handle $progressWindow -Status "Windows image applied." -PercentComplete 90

    Write-Log "Dismounting source ISO and removing staged copy..."
    Dismount-DiskImage -ImagePath $isoDestPath | Out-Null
    Remove-Item -Path $isoDestPath -Force -ErrorAction SilentlyContinue

    Write-Log "Setting up boot files with bcdboot..."
    Set-ProgressStatus -Handle $progressWindow -Status "Configuring boot files..." -PercentComplete 92
    $windowsDir = "$($layout.WinDriveLetter):\Windows"
    & bcdboot.exe $windowsDir /s "$($layout.EspDriveLetter):" /f UEFI
    if ($LASTEXITCODE -ne 0) {
        throw "bcdboot.exe failed with exit code $LASTEXITCODE."
    }

    # bcdboot creates/repairs the target OS's own boot files and BCD store,
    # but does NOT reliably reorder the FIRMWARE's own NVRAM boot priority
    # list. If this machine's firmware already has PXE/network (or USB) boot
    # ranked ahead of the local disk, the newly installed OS is technically
    # bootable but the firmware tries network boot first anyway on next
    # restart - looking like "the install just boots to network" even though
    # the install itself succeeded. Explicitly push the Windows Boot Manager
    # entry to the front of the firmware's own boot order to fix this.
    Write-Log "Setting Windows Boot Manager as the first firmware boot option..."
    & bcdedit.exe /set '{fwbootmgr}' displayorder '{bootmgr}' /addfirst
    if ($LASTEXITCODE -ne 0) {
        Write-Log ("WARNING: bcdedit /set {fwbootmgr} displayorder failed (exit code $LASTEXITCODE) - " +
                    "the OS install itself succeeded, but this machine's firmware may still try " +
                    "network/USB boot first on next restart. This may need a manual one-time boot " +
                    "order fix in firmware settings, or a persistent firmware policy override outside " +
                    "the OS's control.")
    }

    if ($UnattendXmlUrl -and $UnattendXmlUrl.Trim().Length -gt 0) {
        Write-Log "Downloading unattend.xml from $UnattendXmlUrl for first-boot specialize/oobe..."
        Set-ProgressStatus -Handle $progressWindow -Status "Configuring first-boot settings..." -PercentComplete 96
        $pantherDir = Join-Path $windowsDir "Panther"
        New-Item -ItemType Directory -Path $pantherDir -Force | Out-Null
        $unattendDest = Join-Path $pantherDir "unattend.xml"
        Invoke-WebRequest -Uri $UnattendXmlUrl -OutFile $unattendDest -UseBasicParsing
        Write-Log "unattend.xml placed at $unattendDest"
    }
    else {
        Write-Log "No unattend.xml URL provided - skipping (first boot will go through normal OOBE)."
    }

    # X:\ is WinPE's RAM disk - this log disappears the moment the machine
    # reboots into the installed OS. Copy it onto the target disk first so
    # there's something to inspect afterward if anything (including the
    # firmware boot order fix above) doesn't fully resolve on first boot.
    try {
        Copy-Item -Path $LogPath -Destination (Join-Path $windowsDir "Temp\init-install.log") -Force -ErrorAction SilentlyContinue
    }
    catch {
        # Non-fatal - this is a courtesy copy, not required for the install itself.
    }

    Set-ProgressStatus -Handle $progressWindow -Status "Install complete. Restarting..." -PercentComplete 100
    Write-Log "=== Install complete. Restarting into the new installation in 10 seconds. ==="
    Start-Sleep -Seconds 10
    Dismount-BootUsbMedia
    Close-ProgressWindow -Handle $progressWindow
    wpeutil reboot
}
catch {
    Write-Log "FATAL: $($_.Exception.Message)"
    Write-Log "Dropping to a command prompt for troubleshooting (log at $LogPath)."
    Set-ProgressStatus -Handle $progressWindow -Status "ERROR: $($_.Exception.Message)" -PercentComplete 100
    Start-Sleep -Seconds 5
    Close-ProgressWindow -Handle $progressWindow
    # Deliberately do NOT reboot on failure - leave the operator a shell to inspect.
    cmd.exe
}
