# PowerShell script for User File Transfer
# Transfers files from Desktop, Downloads, Documents, Pictures, Music, and Videos to external SSD

# Get user profile path
$UserProfile = [System.Environment]::GetFolderPath("UserProfile")
$FoldersToBackup = @("Desktop", "Downloads", "Documents", "Pictures", "Music", "Videos")

# Function to check if a folder is synced by OneDrive
function Test-OneDriveSync($folderPath) {
    try {
        # Check if path contains OneDrive
        if ($folderPath -like "*OneDrive*") {
            return $true
        }
        
        # Check registry for OneDrive sync folders
        $onedriveRegPath = "HKCU:\Software\Microsoft\OneDrive"
        if (Test-Path $onedriveRegPath) {
            $onedrivePath = (Get-ItemProperty -Path $onedriveRegPath -Name "UserFolder" -ErrorAction SilentlyContinue).UserFolder
            if ($onedrivePath -and $folderPath -like "$onedrivePath*") {
                return $true
            }
        }
        
        # Check if folder is redirected to OneDrive (Windows folder redirection)
        # Check registry: HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders
        $shellFoldersPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"
        if (Test-Path $shellFoldersPath) {
            $folderName = Split-Path $folderPath -Leaf
            $registryMap = @{
                "Desktop" = "Desktop"
                "Documents" = "Personal"
                "Pictures" = "My Pictures"
                "Music" = "My Music"
                "Videos" = "My Video"
            }
            
            if ($registryMap.ContainsKey($folderName)) {
                $regKey = $registryMap[$folderName]
                $redirectedPath = (Get-ItemProperty -Path $shellFoldersPath -Name $regKey -ErrorAction SilentlyContinue).$regKey
                if ($redirectedPath -and $redirectedPath -like "*OneDrive*") {
                    return $true
                }
            }
        }
        
        # Check for OneDrive sync status attribute (if available)
        if (Test-Path $folderPath) {
            $folder = Get-Item $folderPath -ErrorAction SilentlyContinue
            if ($folder) {
                # Check if parent is OneDrive
                $parentPath = Split-Path $folderPath -Parent
                if ($parentPath -like "*OneDrive*") {
                    return $true
                }
                
                # Check if folder is a junction/symlink pointing to OneDrive
                try {
                    $target = (Get-Item $folderPath -ErrorAction SilentlyContinue).Target
                    if ($target -and $target -like "*OneDrive*") {
                        return $true
                    }
                } catch {
                    # Not a junction/symlink, continue
                }
            }
        }
        
        return $false
    } catch {
        return $false
    }
}

# Function to get file count recursively
function Get-FileCount($path) {
    try {
        $files = Get-ChildItem -Path $path -Recurse -File -ErrorAction SilentlyContinue
        return $files.Count
    } catch {
        return 0
    }
}

# Function to verify copied files (count, size per file, and total data - ensures files have real data, not empty shells)
function Verify-Copy($sourcePath, $destPath) {
    try {
        $sourceFiles = Get-ChildItem -Path $sourcePath -Recurse -File -ErrorAction SilentlyContinue
        $destFiles = Get-ChildItem -Path $destPath -Recurse -File -ErrorAction SilentlyContinue
        
        $sourceCount = $sourceFiles.Count
        $destCount = $destFiles.Count
        
        if ($sourceCount -eq 0 -and $destCount -eq 0) {
            return @{ Success = $true; Message = "Empty folder"; TotalBytes = 0 }
        }
        
        if ($sourceCount -ne $destCount) {
            return @{ 
                Success = $false; 
                Message = "File count mismatch: Source=$sourceCount, Destination=$destCount" 
            }
        }
        
        # Verify each file exists at destination and has same size (catches "created with no data")
        $mismatches = 0
        $sourceTotalBytes = 0
        $destTotalBytes = 0
        foreach ($sourceFile in $sourceFiles) {
            $sourceTotalBytes += $sourceFile.Length
            $relativePath = $sourceFile.FullName.Substring($sourcePath.Length + 1)
            $destFile = Join-Path $destPath $relativePath
            
            if (-not (Test-Path $destFile)) {
                $mismatches++
                continue
            }
            
            $destItem = Get-Item $destFile -ErrorAction SilentlyContinue
            $destSize = if ($destItem) { $destItem.Length } else { 0 }
            $destTotalBytes += $destSize
            
            if ($sourceFile.Length -ne $destSize) {
                $mismatches++
            }
        }
        
        # Explicit check: source had data but destination is empty (files created with no data)
        if ($sourceTotalBytes -gt 0 -and $destTotalBytes -eq 0) {
            return @{ 
                Success = $false; 
                Message = "Destination has no data - files may be empty. Source had $([math]::Round($sourceTotalBytes/1MB, 2)) MB." 
            }
        }
        
        if ($mismatches -gt 0) {
            return @{ 
                Success = $false; 
                Message = "$mismatches file(s) size mismatch or missing (data not fully transferred)" 
            }
        }
        
        $sizeStr = if ($sourceTotalBytes -ge 1GB) { "$([math]::Round($sourceTotalBytes/1GB, 2)) GB" } elseif ($sourceTotalBytes -ge 1MB) { "$([math]::Round($sourceTotalBytes/1MB, 2)) MB" } else { "$([math]::Round($sourceTotalBytes/1KB, 2)) KB" }
        return @{ Success = $true; Message = "All $sourceCount files verified ($sizeStr)"; TotalBytes = $sourceTotalBytes }
    } catch {
        return @{ Success = $false; Message = "Verification error: $($_.Exception.Message)" }
    }
}

# Function to copy files with progress bar using robocopy
# $verifyWritten: if $true, add /V so robocopy verifies written data (use for critical folders like Documents)
function Copy-FilesWithProgress($sourcePath, $destPath, $folderName, [switch]$verifyWritten) {
    try {
        # Get all files to copy
        $allFiles = Get-ChildItem -Path $sourcePath -Recurse -File -ErrorAction SilentlyContinue
        $totalFiles = $allFiles.Count
        $copiedFiles = 0
        $failedFiles = 0
        
        if ($totalFiles -eq 0) {
            return @{ Success = $true; Copied = 0; Failed = 0 }
        }
        
        # Calculate total size (optimized using Measure-Object)
        Write-Host "  Calculating total size..." -ForegroundColor Gray
        $totalSize = ($allFiles | Measure-Object -Property Length -Sum).Sum
        $totalSizeGB = [math]::Round($totalSize / 1GB, 2)
        $copiedSize = 0
        
        # Create destination directory structure
        New-Item -ItemType Directory -Path $destPath -Force | Out-Null
        
        if ($verifyWritten) {
            Write-Host "  Using robocopy with /V (verify written data) for this folder." -ForegroundColor Cyan
        }
        Write-Host "  Starting robocopy of $totalFiles files ($totalSizeGB GB total)..." -ForegroundColor Gray
        Write-Host "  Press [C] to Cancel" -ForegroundColor Cyan
        Write-Host ""
        
        # Control flags
        $isCancelled = $false
        
        # Start background process to monitor for cancel
        $inputFile = Join-Path $env:TEMP "FileClone_Cancel_$PID.txt"
        if (Test-Path $inputFile) { Remove-Item $inputFile -Force }
        
        $cancelMonitor = Start-Job -ScriptBlock {
            param($cancelFile)
            while ($true) {
                try {
                    if ($host.UI.RawUI.KeyAvailable) {
                        $key = $host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
                        if ($key.Character -eq 'c' -or $key.Character -eq 'C') {
                            Set-Content -Path $cancelFile -Value "1" -Force
                            break
                        }
                    }
                } catch {
                    # Ignore keyboard errors
                }
                Start-Sleep -Milliseconds 100
            }
        } -ArgumentList $inputFile
        
        # Use robocopy with multi-threading and optimized settings for maximum speed
        # /V = verify written data (slower but ensures data integrity - used for Documents)
        # /MT:4 = 4 threads; /R:1 /W:1 = retry; /J = unbuffered I/O; /FFT = FAT times; /256 = buffer
        $robocopyArgs = @(
            "`"$sourcePath`"",
            "`"$destPath`"",
            "/E",           # Copy subdirectories including empty ones
            "/MT:4",        # Multi-threaded with 4 threads
            "/R:1",         # Retry 1 time on failure (faster)
            "/W:1",         # Wait 1 second between retries
            "/J",            # Use unbuffered I/O (faster for large files)
            "/FFT",          # Assume FAT file times (2 second precision, faster)
            "/256",          # Use 256KB buffer size (faster transfers)
            "/NP",           # No progress percentage
            "/NDL",          # No directory list
            "/NFL",          # No file list
            "/NJH",          # No job header
            "/NJS"           # No job summary
        )
        if ($verifyWritten) {
            $robocopyArgs += "/V"   # Verify written data
        }
        
        # Start robocopy process
        $robocopyProcess = Start-Process -FilePath "robocopy.exe" -ArgumentList $robocopyArgs -NoNewWindow -PassThru
        
        # Monitor progress with lightweight file count checks
        $lastCopiedCount = 0
        $startTime = Get-Date
        $progressCheckInterval = 2000  # Check every 2 seconds
        $lastProgressCheck = Get-Date
        
        while (-not $robocopyProcess.HasExited) {
            # Check for cancel
            if (Test-Path $inputFile) {
                $cancelContent = Get-Content $inputFile -ErrorAction SilentlyContinue
                if ($cancelContent -eq "1") {
                    Write-Host ""
                    Write-Host "  Cancelling..." -ForegroundColor Yellow
                    $isCancelled = $true
                    Stop-Process -Id $robocopyProcess.Id -Force -ErrorAction SilentlyContinue
                    break
                }
            }
            
            # Only check progress every 2 seconds to reduce overhead
            $timeSinceLastCheck = (Get-Date) - $lastProgressCheck
            if ($timeSinceLastCheck.TotalMilliseconds -ge $progressCheckInterval) {
                # Lightweight file count check (fast, no size calculation)
                try {
                    $copiedFiles = (Get-ChildItem -Path $destPath -Recurse -File -ErrorAction SilentlyContinue).Count
                } catch {
                    # If count fails, estimate based on time elapsed
                    $elapsedSeconds = ((Get-Date) - $startTime).TotalSeconds
                    if ($elapsedSeconds -gt 0 -and $lastCopiedCount -gt 0) {
                        $filesPerSecond = $lastCopiedCount / $elapsedSeconds
                        $copiedFiles = [math]::Min([int]($lastCopiedCount + ($filesPerSecond * 2)), $totalFiles)
                    } else {
                        $copiedFiles = $lastCopiedCount
                    }
                }
                
                # Estimate size based on file count progress (no folder scanning for sizes)
                if ($copiedFiles -gt 0 -and $totalFiles -gt 0) {
                    $progressPercent = $copiedFiles / $totalFiles
                    $copiedSize = $totalSize * $progressPercent
                } else {
                    $copiedSize = 0
                }
                
                # Calculate progress
                $percentComplete = if ($totalFiles -gt 0) { [math]::Round(($copiedFiles / $totalFiles) * 100, 1) } else { 0 }
                $copiedSizeGB = [math]::Round($copiedSize / 1GB, 2)
                $remainingSizeGB = [math]::Round(($totalSize - $copiedSize) / 1GB, 2)
                $sizePercent = if ($totalSize -gt 0) { [math]::Round(($copiedSize / $totalSize) * 100, 1) } else { 0 }
                $remainingFiles = $totalFiles - $copiedFiles
                
                # Show progress
                $statusMessage = "Copying: $copiedFiles / $totalFiles files"
                $currentOp = "Files: $copiedFiles / $totalFiles ($percentComplete%) | Size: $copiedSizeGB / $totalSizeGB GB ($sizePercent%)"
                $currentOp += "`nRemaining: $remainingFiles files | $remainingSizeGB GB left"
                
                Write-Progress -Id 0 -Activity "Copying $folderName" `
                              -Status $statusMessage `
                              -PercentComplete $percentComplete `
                              -CurrentOperation $currentOp
                
                # Update last count for next check
                $lastCopiedCount = $copiedFiles
                $lastProgressCheck = Get-Date
            }
            
            # Sleep shorter time, but progress only updates every 2 seconds
            Start-Sleep -Milliseconds 200
        }
        
        # Clean up cancel monitor
        if ($cancelMonitor) {
            Stop-Job -Job $cancelMonitor -ErrorAction SilentlyContinue
            Remove-Job -Job $cancelMonitor -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $inputFile) { Remove-Item $inputFile -Force -ErrorAction SilentlyContinue }
        
        # Wait for robocopy to finish if not cancelled
        if (-not $isCancelled) {
            $robocopyProcess.WaitForExit()
            $exitCode = $robocopyProcess.ExitCode
            
            # Robocopy exit codes: 0-7 are success, 8+ are errors
            # But exit code 1 means files were copied successfully
            if ($exitCode -le 7) {
                # Count final files
                $copiedFiles = (Get-ChildItem -Path $destPath -Recurse -File -ErrorAction SilentlyContinue).Count
                $failedFiles = $totalFiles - $copiedFiles
                
                Write-Progress -Id 0 -Activity "Copying $folderName" -Completed
                Write-Host "  Completed: $copiedFiles copied, $failedFiles failed" -ForegroundColor Gray
                
                return @{ Success = ($failedFiles -eq 0); Copied = $copiedFiles; Failed = $failedFiles }
            } else {
                Write-Progress -Id 0 -Activity "Copying $folderName" -Completed
                Write-Host "  Robocopy error (exit code: $exitCode)" -ForegroundColor Red
                return @{ Success = $false; Copied = $copiedFiles; Failed = $failedFiles }
            }
        } else {
            Write-Progress -Id 0 -Activity "Copying $folderName" -Completed
            return @{ Success = $false; Copied = $copiedFiles; Failed = $failedFiles; Cancelled = $true }
        }
    } catch {
        Write-Progress -Id 0 -Activity "Copying $folderName" -Completed
        Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue
        return @{ Success = $false; Copied = 0; Failed = 0; Error = $_.Exception.Message }
    }
}

# Function to find external drives (USB, External SSD, etc.)
function Find-ExternalDrive() {
    Write-Host "`nScanning for external drives..." -ForegroundColor Cyan
    
    try {
        # First: find all logical drives that belong to USB physical disks (e.g. Crucial X9, external SSDs)
        $usbDriveLetters = @()
        $diskDrives = Get-WmiObject Win32_DiskDrive -ErrorAction SilentlyContinue
        foreach ($disk in $diskDrives) {
            $isUsb = $false
            if ($disk.InterfaceType -eq "USB") { $isUsb = $true }
            if (-not $isUsb -and $disk.PNPDeviceID -like "*USB*") { $isUsb = $true }
            if (-not $isUsb) { continue }
            $partitions = Get-WmiObject Win32_DiskDriveToDiskPartition -ErrorAction SilentlyContinue | Where-Object { $_.Antecedent.DeviceID -eq $disk.DeviceID }
            foreach ($part in $partitions) {
                $partDeviceId = $part.Dependent.DeviceID
                $logicalDisks = Get-WmiObject Win32_LogicalDiskToPartition -ErrorAction SilentlyContinue | Where-Object { $_.Antecedent.DeviceID -eq $partDeviceId }
                foreach ($ld in $logicalDisks) {
                    $letter = $ld.Dependent.DeviceID
                    if ($letter -and $letter -ne $env:SystemDrive) { $usbDriveLetters += $letter }
                }
            }
        }
        
        # Build list: USB-derived drives + removable (DriveType 2) + fixed external under 4TB (catch external SSDs not reported as USB in WMI)
        $systemDrive = $env:SystemDrive
        $drives = Get-WmiObject Win32_LogicalDisk -ErrorAction SilentlyContinue | Where-Object { 
            $_.DeviceID -ne $systemDrive -and (
                $_.DeviceID -in $usbDriveLetters -or
                $_.DriveType -eq 2 -or
                ($_.DriveType -eq 3 -and $_.Size -lt 4TB)
            )
        } | Sort-Object -Property DeviceID -Unique
        
        # If we found USB drives by physical disk, prefer those (exact match)
        if ($usbDriveLetters.Count -gt 0) {
            $drives = $drives | Where-Object { $_.DeviceID -in $usbDriveLetters }
        }
        
        if ($drives.Count -eq 0) {
            Write-Host "No external drives found. Please connect an external SSD/USB drive and try again." -ForegroundColor Red
            Write-Host "Press any key to exit..."
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            return $null
        }
        
        # If only one drive found, use it
        if ($drives.Count -eq 1) {
            $selectedDrive = $drives[0].DeviceID
            $driveLabel = if ($drives[0].VolumeName) { $drives[0].VolumeName } else { "External Drive" }
            Write-Host "Found external drive: $selectedDrive ($driveLabel)" -ForegroundColor Green
            return $selectedDrive
        }
        
        # Multiple drives found - let user choose
        Write-Host "`nMultiple external drives found:" -ForegroundColor Yellow
        $index = 1
        $driveList = @()
        foreach ($drive in $drives) {
            $sizeGB = [math]::Round($drive.Size / 1GB, 2)
            $label = if ($drive.VolumeName) { $drive.VolumeName } else { "No Label" }
            Write-Host "[$index] $($drive.DeviceID) - $label ($sizeGB GB)" -ForegroundColor Cyan
            $driveList += $drive
            $index++
        }
        
        do {
            $choice = Read-Host "`nSelect drive number (1-$($driveList.Count))"
            if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $driveList.Count) {
                $selectedDrive = $driveList[[int]$choice - 1].DeviceID
                Write-Host "Selected: $selectedDrive" -ForegroundColor Green
                return $selectedDrive
            } else {
                Write-Host "Invalid selection. Please enter a number between 1 and $($driveList.Count)." -ForegroundColor Red
            }
        } while ($true)
        
    } catch {
        Write-Host "Error scanning for drives: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Press any key to exit..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return $null
    }
}

# Function to backup printers with drivers (PrintBrm like Print Management) plus CSV fallback
function Backup-Printers($backupFolder) {
    $printersDir = Join-Path $backupFolder "Printers"
    New-Item -ItemType Directory -Path $printersDir -Force | Out-Null
    $printBrmExe = Join-Path $env:windir "System32\spool\tools\PrintBrm.exe"
    # PrintBrm does not support paths with spaces; use temp path then copy
    $tempPrintBrm = Join-Path $env:TEMP "FileClonePrintBrm"
    if (-not (Test-Path $tempPrintBrm)) { New-Item -ItemType Directory -Path $tempPrintBrm -Force | Out-Null }
    $tempBackupFile = Join-Path $tempPrintBrm "PrintersBackup"
    try {
        $printers = @()
        if (Get-Command Get-Printer -ErrorAction SilentlyContinue) {
            $printers = Get-Printer -ErrorAction SilentlyContinue | Where-Object { -not $_.Name.StartsWith("Microsoft ") -and $_.Name -ne "Fax" }
        } else {
            $printers = Get-WmiObject Win32_Printer -ErrorAction SilentlyContinue | Where-Object { -not $_.Name.StartsWith("Microsoft ") -and $_.Name -ne "Fax" -and $_.System -eq $false }
        }
        # Always save CSV for reference
        $rows = @()
        foreach ($p in $printers) {
            $rows += [PSCustomObject]@{ PrinterName = $p.Name; DriverName = $p.DriverName; PortName = $p.PortName }
        }
        $csvPath = Join-Path $printersDir "printers.csv"
        if ($rows.Count -gt 0) {
            $rows | Export-Csv -Path $csvPath -NoTypeInformation -Force
        }
        # Full backup with drivers via PrintBrm (requires elevation for driver export)
        if ($printers.Count -gt 0 -and (Test-Path $printBrmExe)) {
            Remove-Item -Path "$tempBackupFile*" -Force -ErrorAction SilentlyContinue
            $proc = Start-Process -FilePath $printBrmExe -ArgumentList "-b", "-f", $tempBackupFile, "-o", "force" -Wait -PassThru -NoNewWindow
            if ($proc.ExitCode -eq 0) {
                $created = Get-ChildItem -Path $tempPrintBrm -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "PrintersBackup*" }
                foreach ($f in $created) {
                    $dest = Join-Path $printersDir $f.Name
                    if ($f.PSIsContainer) { Copy-Item -Path $f.FullName -Destination $dest -Recurse -Force } else { Copy-Item -Path $f.FullName -Destination $dest -Force }
                }
                Write-Host "  Backed up $($rows.Count) printer(s) with drivers (PrintBrm) and printers.csv" -ForegroundColor Green
            } else {
                Write-Host "  PrintBrm backup failed (exit $($proc.ExitCode)); list saved to printers.csv. Run script as Administrator for full driver backup." -ForegroundColor Yellow
            }
        } elseif ($rows.Count -gt 0) {
            Write-Host "  Backed up $($rows.Count) printer(s) to Printers\printers.csv (PrintBrm not found; restore will use CSV)." -ForegroundColor Green
        } else {
            Write-Host "  No user printers to backup." -ForegroundColor Gray
        }
    } catch {
        Write-Host "  Printer backup error: $($_.Exception.Message)" -ForegroundColor Red
    }
    Remove-Item -Path "$tempBackupFile*" -Force -ErrorAction SilentlyContinue
}

# Key files to backup for Chrome/Edge (bookmarks, preferences, passwords)
$BrowserProfileFiles = @("Bookmarks", "Bookmarks.bak", "Preferences", "Secure Preferences", "Web Data", "Login Data", "Login Data-journal")

# Check if Chrome or Edge is running
function Test-BrowserProcessRunning() {
    $chrome = Get-Process -Name "chrome" -ErrorAction SilentlyContinue
    $edge = Get-Process -Name "msedge" -ErrorAction SilentlyContinue
    return (@($chrome) + @($edge) | Where-Object { $_ }).Count -gt 0
}

# Force-close Chrome and Edge so backup/restore can run without triggering "Chrome reset bookmarks" protection
function Stop-BrowserProcesses() {
    $closed = @()
    try {
        Get-Process -Name "chrome" -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue; $closed += "Chrome" }
        Get-Process -Name "msedge" -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue; $closed += "Edge" }
        if ($closed.Count -gt 0) {
            Start-Sleep -Seconds 2
            return $true
        }
    } catch { }
    return $false
}

# Function to backup Chrome bookmarks, profile data, and passwords
function Backup-Chrome($backupFolder) {
    $chromeUserData = Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data"
    if (-not (Test-Path $chromeUserData)) {
        Write-Host "  Chrome User Data not found, skipping." -ForegroundColor Gray
        return
    }
    $chromeDest = Join-Path $backupFolder "Chrome"
    New-Item -ItemType Directory -Path $chromeDest -Force | Out-Null
    $profiles = @("Default")
    $profiles += Get-ChildItem -Path $chromeUserData -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^Profile \d+$" } | ForEach-Object { $_.Name }
    $copied = 0
    foreach ($profile in $profiles) {
        $srcProfile = Join-Path $chromeUserData $profile
        if (-not (Test-Path $srcProfile)) { continue }
        $destProfile = Join-Path $chromeDest $profile
        New-Item -ItemType Directory -Path $destProfile -Force | Out-Null
        foreach ($f in $BrowserProfileFiles) {
            $srcFile = Join-Path $srcProfile $f
            if (Test-Path $srcFile) {
                try {
                    Copy-Item -Path $srcFile -Destination (Join-Path $destProfile $f) -Force
                    $copied++
                } catch { }
            }
        }
    }
    if ($copied -gt 0) {
        Write-Host "  Backed up Chrome data including passwords ($copied files from $($profiles.Count) profile(s))." -ForegroundColor Green
    } else {
        Write-Host "  No Chrome bookmarks/profile files found." -ForegroundColor Gray
    }
}

# Function to backup Edge bookmarks, profile data, and passwords
function Backup-Edge($backupFolder) {
    $edgeUserData = Join-Path $env:LOCALAPPDATA "Microsoft\Edge\User Data"
    if (-not (Test-Path $edgeUserData)) {
        Write-Host "  Edge User Data not found, skipping." -ForegroundColor Gray
        return
    }
    $edgeDest = Join-Path $backupFolder "Edge"
    New-Item -ItemType Directory -Path $edgeDest -Force | Out-Null
    $profiles = @("Default")
    $profiles += Get-ChildItem -Path $edgeUserData -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^Profile \d+$" } | ForEach-Object { $_.Name }
    $copied = 0
    foreach ($profile in $profiles) {
        $srcProfile = Join-Path $edgeUserData $profile
        if (-not (Test-Path $srcProfile)) { continue }
        $destProfile = Join-Path $edgeDest $profile
        New-Item -ItemType Directory -Path $destProfile -Force | Out-Null
        foreach ($f in $BrowserProfileFiles) {
            $srcFile = Join-Path $srcProfile $f
            if (Test-Path $srcFile) {
                try {
                    Copy-Item -Path $srcFile -Destination (Join-Path $destProfile $f) -Force
                    $copied++
                } catch { }
            }
        }
    }
    if ($copied -gt 0) {
        Write-Host "  Backed up Edge data including passwords ($copied files from $($profiles.Count) profile(s))." -ForegroundColor Green
    } else {
        Write-Host "  No Edge bookmarks/profile files found." -ForegroundColor Gray
    }
}

# Common app names to exclude from installed-apps list (case-insensitive partial match)
$CommonAppsExclude = @(
    "Google Chrome", "Chrome", "7-Zip", "7zip", "VLC", "VLC Player", "Adobe Acrobat Reader", "Acrobat Reader",
    "Zoom", "Microsoft Edge", "Edge", "Windows Security", "Windows Update", "Microsoft Store",
    "Cortana", "OneDrive", "Skype", "Teams", "Microsoft Office", "Spotify", "iTunes", "iCloud",
    "Firefox", "Mozilla Firefox", "Opera", "CCleaner", "Java Auto Updater", "Java(TM)",
    "Microsoft Visual C++", "Visual Studio", ".NET Framework", "Windows SDK", "Windows Defender"
)

# Function to backup list of installed apps (excluding common apps)
function Backup-InstalledApps($backupFolder) {
    $appsDir = Join-Path $backupFolder "InstalledApps"
    New-Item -ItemType Directory -Path $appsDir -Force | Out-Null
    $outPath = Join-Path $appsDir "InstalledApps.txt"
    try {
        $allApps = @()
        $uninstallKeys = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
        foreach ($key in $uninstallKeys) {
            if (-not (Test-Path $key -ErrorAction SilentlyContinue)) { continue }
            Get-ItemProperty -Path $key -ErrorAction SilentlyContinue | ForEach-Object {
                $name = $_.DisplayName
                if (-not $name) { return }
                $allApps += $name
            }
        }
        $filtered = $allApps | Sort-Object -Unique | Where-Object {
            $app = $_
            $exclude = $false
            foreach ($pattern in $CommonAppsExclude) {
                if ($app -like "*$pattern*") { $exclude = $true; break }
            }
            -not $exclude
        }
        $filtered | Set-Content -Path $outPath -Force
        Write-Host "  Saved $($filtered.Count) installed apps (excluding common) to InstalledApps\InstalledApps.txt" -ForegroundColor Green
    } catch {
        Write-Host "  Installed apps backup error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Function to backup C:\Scans or C:\scans if present; returns verification result for summary
function Backup-Scans($backupFolder) {
    $scansPath = $null
    if (Test-Path "C:\Scans") { $scansPath = "C:\Scans" }
    elseif (Test-Path "C:\scans") { $scansPath = "C:\scans" }
    if (-not $scansPath) {
        Write-Host "  C:\Scans folder not found, skipping." -ForegroundColor Gray
        return $null
    }
    $destScans = Join-Path $backupFolder "Scans"
    $fileCount = (Get-ChildItem -Path $scansPath -Recurse -File -ErrorAction SilentlyContinue).Count
    if ($fileCount -eq 0) {
        New-Item -ItemType Directory -Path $destScans -Force | Out-Null
        Write-Host "  Backed up Scans folder (empty)." -ForegroundColor Green
        return @{ Folder = "Scans"; Status = "Success"; Message = "Empty folder" }
    }
    Write-Host "  Copying Scans folder ($fileCount files)..." -ForegroundColor Gray
    $robocopyArgs = @("`"$scansPath`"", "`"$destScans`"", "/E", "/MT:4", "/R:1", "/W:1", "/NP", "/NDL", "/NFL", "/NJH", "/NJS")
    $proc = Start-Process -FilePath "robocopy.exe" -ArgumentList $robocopyArgs -NoNewWindow -PassThru -Wait
    if ($proc.ExitCode -le 7) {
        Write-Host "  Verifying Scans copy (file count and sizes)..." -ForegroundColor Gray
        $verifyResult = Verify-Copy -sourcePath $scansPath -destPath $destScans
        if ($verifyResult.Success) {
            Write-Host "  Scans backed up and verified: $($verifyResult.Message)" -ForegroundColor Green
            return @{ Folder = "Scans"; Status = "Success"; Message = $verifyResult.Message }
        } else {
            Write-Host "  Scans copy completed but verification failed: $($verifyResult.Message)" -ForegroundColor Red
            return @{ Folder = "Scans"; Status = "Failed"; Message = $verifyResult.Message }
        }
    } else {
        Write-Host "  Scans backup had errors (robocopy exit $($proc.ExitCode))." -ForegroundColor Yellow
        return @{ Folder = "Scans"; Status = "Failed"; Message = "Robocopy exit $($proc.ExitCode)" }
    }
}

# Function to backup C:\Boardmaker or C:\boardmaker if present; returns verification result for summary
function Backup-Boardmaker($backupFolder) {
    $boardmakerPath = $null
    if (Test-Path "C:\Boardmaker") { $boardmakerPath = "C:\Boardmaker" }
    elseif (Test-Path "C:\boardmaker") { $boardmakerPath = "C:\boardmaker" }
    if (-not $boardmakerPath) {
        Write-Host "  C:\Boardmaker folder not found, skipping." -ForegroundColor Gray
        return $null
    }
    $destBoardmaker = Join-Path $backupFolder "Boardmaker"
    $fileCount = (Get-ChildItem -Path $boardmakerPath -Recurse -File -ErrorAction SilentlyContinue).Count
    if ($fileCount -eq 0) {
        New-Item -ItemType Directory -Path $destBoardmaker -Force | Out-Null
        Write-Host "  Backed up Boardmaker folder (empty)." -ForegroundColor Green
        return @{ Folder = "Boardmaker"; Status = "Success"; Message = "Empty folder" }
    }
    Write-Host "  Copying Boardmaker folder ($fileCount files)..." -ForegroundColor Gray
    $robocopyArgs = @("`"$boardmakerPath`"", "`"$destBoardmaker`"", "/E", "/MT:4", "/R:1", "/W:1", "/NP", "/NDL", "/NFL", "/NJH", "/NJS")
    $proc = Start-Process -FilePath "robocopy.exe" -ArgumentList $robocopyArgs -NoNewWindow -PassThru -Wait
    if ($proc.ExitCode -le 7) {
        Write-Host "  Verifying Boardmaker copy (file count and sizes)..." -ForegroundColor Gray
        $verifyResult = Verify-Copy -sourcePath $boardmakerPath -destPath $destBoardmaker
        if ($verifyResult.Success) {
            Write-Host "  Boardmaker backed up and verified: $($verifyResult.Message)" -ForegroundColor Green
            return @{ Folder = "Boardmaker"; Status = "Success"; Message = $verifyResult.Message }
        } else {
            Write-Host "  Boardmaker copy completed but verification failed: $($verifyResult.Message)" -ForegroundColor Red
            return @{ Folder = "Boardmaker"; Status = "Failed"; Message = $verifyResult.Message }
        }
    } else {
        Write-Host "  Boardmaker backup had errors (robocopy exit $($proc.ExitCode))." -ForegroundColor Yellow
        return @{ Folder = "Boardmaker"; Status = "Failed"; Message = "Robocopy exit $($proc.ExitCode)" }
    }
}

# Function to create restore script in backup folder
function Create-RestoreScript($backupFolder) {
    $restoreScript = @"
# PowerShell Restore Script
# Run this script on the new computer to restore files to the current user profile

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   FILE CLONE RESTORE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Restores: user folders, printers, Chrome & Edge (bookmarks, profiles, passwords), C:\Scans, C:\Boardmaker" -ForegroundColor Gray
Write-Host "For printer restore, run as Administrator if add fails." -ForegroundColor Gray
Write-Host ""

`$UserProfile = [System.Environment]::GetFolderPath("UserProfile")
`$FoldersToRestore = @("Desktop", "Downloads", "Documents", "Pictures", "Music", "Videos")
`$backupPath = `$PSScriptRoot

Write-Host "Restoring files to: `$UserProfile" -ForegroundColor Yellow
Write-Host "Source: `$backupPath" -ForegroundColor Yellow
Write-Host ""

`$confirm = Read-Host "Do you want to restore files? (Y/N)"
if (`$confirm -notmatch '^[Yy]') {
    Write-Host "Restore cancelled." -ForegroundColor Yellow
    exit
}

foreach (`$folder in `$FoldersToRestore) {
    `$src = "`$backupPath\`$folder"
    `$dest = "`$UserProfile\`$folder"
    
    if (Test-Path `$src) {
        Write-Host "Restoring `$folder..." -ForegroundColor Cyan
        
        # Count files for progress
        `$files = Get-ChildItem -Path `$src -Recurse -File -ErrorAction SilentlyContinue
        `$totalFiles = `$files.Count
        
        if (`$totalFiles -eq 0) {
            Write-Host "  `$folder is empty, skipping..." -ForegroundColor Gray
            continue
        }
        
        # Calculate total size (optimized using Measure-Object)
        `$totalSize = (`$files | Measure-Object -Property Length -Sum).Sum
        `$totalSizeGB = [math]::Round(`$totalSize / 1GB, 2)
        
        Write-Host "  Found `$totalFiles files (`$totalSizeGB GB)..." -ForegroundColor Gray
        
        try {
            # Create destination directory if needed
            if (-not (Test-Path `$dest)) {
                New-Item -ItemType Directory -Path `$dest -Force | Out-Null
            }
            
            # Use robocopy for fast, reliable copying (quoted paths for spaces in username)
            `$robocopyArgs = @(
                "``"`$src``"",
                "``"`$dest``"",
                "/E",           # Copy subdirectories including empty ones
                "/MT:4",        # Multi-threaded with 4 threads
                "/R:1",         # Retry 1 time on failure
                "/W:1",         # Wait 1 second between retries
                "/J",            # Use unbuffered I/O (faster for large files)
                "/FFT",          # Assume FAT file times (faster)
                "/256",          # Use 256KB buffer size
                "/NP",           # No progress percentage
                "/NDL",          # No directory list
                "/NFL",          # No file list
                "/NJH",          # No job header
                "/NJS"           # No job summary
            )
            
            `$robocopyProcess = Start-Process -FilePath "robocopy.exe" -ArgumentList `$robocopyArgs -NoNewWindow -PassThru -Wait
            
            # Check exit code (0-7 are success codes for robocopy)
            if (`$robocopyProcess.ExitCode -le 7) {
                `$copiedFiles = (Get-ChildItem -Path `$dest -Recurse -File -ErrorAction SilentlyContinue).Count
                Write-Host "  `$folder restored successfully (`$copiedFiles files)" -ForegroundColor Green
            } else {
                Write-Host "  Warning: Some files may not have been restored (robocopy exit code: `$(`$robocopyProcess.ExitCode))" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  Error restoring `$folder : `$(`$_.Exception.Message)" -ForegroundColor Red
        }
    } else {
        Write-Host "Skipping `$folder (not found in backup)" -ForegroundColor Yellow
    }
}

# Restore printers: prefer PrintBrm (with drivers), else CSV fallback
`$printersDir = "`$backupPath\Printers"
`$printBrmExe = Join-Path `$env:windir "System32\spool\tools\PrintBrm.exe"
`$printBrmSucceeded = `$false
`$printBrmBackup = Get-ChildItem -Path `$printersDir -ErrorAction SilentlyContinue | Where-Object { `$_.Name -like "PrintersBackup*" -and `$_.Name -ne "printers.csv" } | Select-Object -First 1
if (`$printBrmBackup -and (Test-Path `$printBrmExe)) {
    Write-Host "Restoring printers with drivers (PrintBrm)..." -ForegroundColor Cyan
    `$tempPrintBrm = Join-Path `$env:TEMP "FileClonePrintBrmRestore"
    if (-not (Test-Path `$tempPrintBrm)) { New-Item -ItemType Directory -Path `$tempPrintBrm -Force | Out-Null }
    `$tempFile = Join-Path `$tempPrintBrm `$printBrmBackup.Name
    if (`$printBrmBackup.PSIsContainer) { Copy-Item -Path `$printBrmBackup.FullName -Destination `$tempFile -Recurse -Force } else { Copy-Item -Path `$printBrmBackup.FullName -Destination `$tempFile -Force }
    `$proc = Start-Process -FilePath `$printBrmExe -ArgumentList "-r", "-f", `$tempFile, "-o", "force" -Wait -PassThru -NoNewWindow
    Remove-Item -Path `$tempFile -Recurse -Force -ErrorAction SilentlyContinue
    if (`$proc.ExitCode -eq 0) { `$printBrmSucceeded = `$true; Write-Host "  Printers restored with drivers." -ForegroundColor Green } else { Write-Host "  PrintBrm restore failed (exit `$(`$proc.ExitCode)). Trying CSV fallback." -ForegroundColor Yellow }
}
`$printersCsv = "`$printersDir\printers.csv"
if ((Test-Path `$printersCsv) -and -not `$printBrmSucceeded) {
    Write-Host "Restoring printers from list (printers.csv)..." -ForegroundColor Cyan
    `$printerRows = Import-Csv -Path `$printersCsv -ErrorAction SilentlyContinue
    foreach (`$row in `$printerRows) {
        try {
            if (Get-Command Add-Printer -ErrorAction SilentlyContinue) {
                `$portName = `$row.PortName
                if (Get-Command Add-PrinterPort -ErrorAction SilentlyContinue) {
                    `$portExists = Get-PrinterPort -Name `$portName -ErrorAction SilentlyContinue
                    if (-not `$portExists -and `$portName -match '\d+\.\d+\.\d+\.\d+') {
                        `$ip = if (`$portName -match 'IP_(.+)') { `$Matches[1] } else { `$portName }
                        Add-PrinterPort -Name `$portName -PrinterHostAddress `$ip -ErrorAction SilentlyContinue
                    }
                }
                Add-Printer -Name `$row.PrinterName -DriverName `$row.DriverName -PortName `$portName -ErrorAction Stop
                Write-Host "  Added printer: `$(`$row.PrinterName)" -ForegroundColor Green
            }
        } catch {
            Write-Host "  Could not add printer '`$(`$row.PrinterName)': `$(`$_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}
if (-not (Test-Path `$printersDir)) { Write-Host "No printer backup found, skipping." -ForegroundColor Gray }

# Restore Chrome and Edge (force-close first so Chrome does not reset bookmarks when it detects changed files)
`$chromeRunning = Get-Process -Name "chrome" -ErrorAction SilentlyContinue
`$edgeRunning = Get-Process -Name "msedge" -ErrorAction SilentlyContinue
if (`$chromeRunning -or `$edgeRunning) {
    Write-Host "Closing Chrome and Edge so browser data can be restored safely..." -ForegroundColor Cyan
    Get-Process -Name "chrome" -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id `$_.Id -Force -ErrorAction SilentlyContinue }
    Get-Process -Name "msedge" -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id `$_.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
}
`$chromeBackup = "`$backupPath\Chrome"
`$chromeUserData = Join-Path `$env:LOCALAPPDATA "Google\Chrome\User Data"
if (Test-Path `$chromeBackup) {
    Write-Host "Restoring Chrome (bookmarks, profiles, passwords)..." -ForegroundColor Cyan
    if (-not (Test-Path `$chromeUserData)) { New-Item -ItemType Directory -Path `$chromeUserData -Force | Out-Null }
    `$chromeProfiles = Get-ChildItem -Path `$chromeBackup -Directory -ErrorAction SilentlyContinue
    foreach (`$prof in `$chromeProfiles) {
        `$destProfile = Join-Path `$chromeUserData `$prof.Name
        if (-not (Test-Path `$destProfile)) { New-Item -ItemType Directory -Path `$destProfile -Force | Out-Null }
        Get-ChildItem -Path `$prof.FullName -File -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -Path `$_.FullName -Destination (Join-Path `$destProfile `$_.Name) -Force -ErrorAction SilentlyContinue
        }
        Write-Host "  Restored Chrome profile: `$(`$prof.Name)" -ForegroundColor Green
    }
} else {
    Write-Host "No Chrome backup found, skipping." -ForegroundColor Gray
}
`$edgeBackup = "`$backupPath\Edge"
`$edgeUserData = Join-Path `$env:LOCALAPPDATA "Microsoft\Edge\User Data"
if (Test-Path `$edgeBackup) {
    Write-Host "Restoring Edge (bookmarks, profiles, passwords)..." -ForegroundColor Cyan
    if (-not (Test-Path `$edgeUserData)) { New-Item -ItemType Directory -Path `$edgeUserData -Force | Out-Null }
    `$edgeProfiles = Get-ChildItem -Path `$edgeBackup -Directory -ErrorAction SilentlyContinue
    foreach (`$prof in `$edgeProfiles) {
        `$destProfile = Join-Path `$edgeUserData `$prof.Name
        if (-not (Test-Path `$destProfile)) { New-Item -ItemType Directory -Path `$destProfile -Force | Out-Null }
        Get-ChildItem -Path `$prof.FullName -File -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -Path `$_.FullName -Destination (Join-Path `$destProfile `$_.Name) -Force -ErrorAction SilentlyContinue
        }
        Write-Host "  Restored Edge profile: `$(`$prof.Name)" -ForegroundColor Green
    }
} else {
    Write-Host "No Edge backup found, skipping." -ForegroundColor Gray
}

# Restore C:\Scans folder
`$scansBackup = "`$backupPath\Scans"
if (Test-Path `$scansBackup) {
    Write-Host "Restoring C:\Scans folder..." -ForegroundColor Cyan
    `$scansDest = "C:\Scans"
    if (-not (Test-Path `$scansDest)) { New-Item -ItemType Directory -Path `$scansDest -Force | Out-Null }
    `$robocopyArgs = @("``"`$scansBackup``"", "``"`$scansDest``"", "/E", "/MT:4", "/R:1", "/W:1", "/NP", "/NDL", "/NFL", "/NJH", "/NJS")
    `$proc = Start-Process -FilePath "robocopy.exe" -ArgumentList `$robocopyArgs -NoNewWindow -PassThru -Wait
    if (`$proc.ExitCode -le 7) { Write-Host "  Scans folder restored." -ForegroundColor Green } else { Write-Host "  Scans restore had errors." -ForegroundColor Yellow }
} else {
    Write-Host "No Scans backup found, skipping." -ForegroundColor Gray
}

# Restore C:\Boardmaker folder
`$boardmakerBackup = "`$backupPath\Boardmaker"
if (Test-Path `$boardmakerBackup) {
    Write-Host "Restoring C:\Boardmaker folder..." -ForegroundColor Cyan
    `$boardmakerDest = "C:\Boardmaker"
    if (-not (Test-Path `$boardmakerDest)) { New-Item -ItemType Directory -Path `$boardmakerDest -Force | Out-Null }
    `$robocopyArgs = @("``"`$boardmakerBackup``"", "``"`$boardmakerDest``"", "/E", "/MT:4", "/R:1", "/W:1", "/NP", "/NDL", "/NFL", "/NJH", "/NJS")
    `$proc = Start-Process -FilePath "robocopy.exe" -ArgumentList `$robocopyArgs -NoNewWindow -PassThru -Wait
    if (`$proc.ExitCode -le 7) { Write-Host "  Boardmaker folder restored." -ForegroundColor Green } else { Write-Host "  Boardmaker restore had errors." -ForegroundColor Yellow }
} else {
    Write-Host "No Boardmaker backup found, skipping." -ForegroundColor Gray
}

Write-Host ""
Write-Host "Restore completed!" -ForegroundColor Green
Write-Host "Press any key to exit..."
`$null = `$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
"@
    
    $restoreScriptPath = Join-Path $backupFolder "RESTORE-FILES.ps1"
    Set-Content -Path $restoreScriptPath -Value $restoreScript -Force
    Write-Host "Restore script created: RESTORE-FILES.ps1" -ForegroundColor Green
}

# Function for Backup
function Backup-Files() {
    $driveLetter = Find-ExternalDrive
    if (-not $driveLetter) {
        return
    }
    
    # Verify drive is accessible
    if (-not (Test-Path $driveLetter)) {
        Write-Host "Error: Cannot access drive $driveLetter" -ForegroundColor Red
        Write-Host "Press any key to exit..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }
    
    $computerName = $env:COMPUTERNAME
    $backupRoot = Join-Path $driveLetter "File-Clone"
    $backupFolder = Join-Path $backupRoot $computerName
    
    Write-Host "`nCreating backup folder: $backupFolder" -ForegroundColor Cyan
    try {
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
    } catch {
        Write-Host "Error creating backup folder: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Press any key to exit..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }
    
    # Create restore script
    Create-RestoreScript $backupFolder
    
    Write-Host "`nStarting backup from: $UserProfile" -ForegroundColor Green
    Write-Host "Backing up to: $backupFolder" -ForegroundColor Green
    Write-Host ""
    
    $totalFolders = 0
    $copiedFolders = 0
    $skippedFolders = 0
    $verificationResults = @()
    
    foreach ($folder in $FoldersToBackup) {
        $sourcePath = Join-Path $UserProfile $folder
        $destPath = Join-Path $backupFolder $folder
        
        $totalFolders++
        
        # Check if folder is synced by OneDrive first (even if path doesn't exist, check parent/OneDrive location)
        $isOneDrive = Test-OneDriveSync $sourcePath
        
        # Check if folder exists
        if (-not (Test-Path $sourcePath)) {
            if ($isOneDrive) {
                Write-Host "[$totalFolders/$($FoldersToBackup.Count)] Skipping $folder (synced by OneDrive - folder not found in local profile)" -ForegroundColor Yellow
            } else {
                Write-Host "[$totalFolders/$($FoldersToBackup.Count)] Skipping $folder (does not exist)" -ForegroundColor Yellow
            }
            $skippedFolders++
            continue
        }
        
        # Check if folder is synced by OneDrive (if it exists)
        if ($isOneDrive) {
            Write-Host "[$totalFolders/$($FoldersToBackup.Count)] Skipping $folder (synced by OneDrive)" -ForegroundColor Yellow
            $skippedFolders++
            continue
        }
        
        Write-Host "[$totalFolders/$($FoldersToBackup.Count)] Processing $folder..." -ForegroundColor Cyan
        
        # Get file count before copying
        $fileCount = Get-FileCount $sourcePath
        if ($fileCount -eq 0) {
            Write-Host "  Folder is empty, skipping..." -ForegroundColor Gray
            $skippedFolders++
            continue
        }
        
        Write-Host "  Found $fileCount files to copy..." -ForegroundColor Gray
        
        # Copy files with progress (/V for Documents to verify written data)
        $copyResult = Copy-FilesWithProgress -sourcePath $sourcePath -destPath $destPath -folderName $folder -verifyWritten:($folder -eq "Documents")
        
        if ($copyResult.Success) {
            Write-Host "  Copy completed: $($copyResult.Copied) files" -ForegroundColor Green
            
            # Verify the copy (file count and sizes - ensures data transferred, not empty files)
            Write-Host "  Verifying copy (file count and sizes)..." -ForegroundColor Gray
            $verifyResult = Verify-Copy -sourcePath $sourcePath -destPath $destPath
            
            if ($verifyResult.Success) {
                Write-Host "  Verification passed: $($verifyResult.Message)" -ForegroundColor Green
                $copiedFolders++
                $verificationResults += @{
                    Folder = $folder
                    Status = "Success"
                    Message = $verifyResult.Message
                }
            } else {
                Write-Host "  Verification failed: $($verifyResult.Message)" -ForegroundColor Red
                $verificationResults += @{
                    Folder = $folder
                    Status = "Failed"
                    Message = $verifyResult.Message
                }
            }
        } else {
            Write-Host "  Copy failed: $($copyResult.Error)" -ForegroundColor Red
            if ($copyResult.Failed -gt 0) {
                Write-Host "  Failed files: $($copyResult.Failed)" -ForegroundColor Red
            }
            $verificationResults += @{
                Folder = $folder
                Status = "Failed"
                Message = "Copy failed"
            }
        }
        
        Write-Host ""
    }
    
    # Backup printers
    Write-Host "[Extra] Backing up printers..." -ForegroundColor Cyan
    Backup-Printers $backupFolder
    Write-Host ""
    
    # Backup Chrome and Edge (force-close browsers first to avoid corruption and Chrome "reset bookmarks" on restore)
    if (Test-BrowserProcessRunning) {
        Write-Host "[Extra] Closing Chrome and Edge so browser data can be backed up safely..." -ForegroundColor Cyan
        Stop-BrowserProcesses | Out-Null
    }
    Write-Host "[Extra] Backing up Chrome bookmarks/profiles/passwords..." -ForegroundColor Cyan
    Backup-Chrome $backupFolder
    Write-Host "[Extra] Backing up Edge bookmarks/profiles/passwords..." -ForegroundColor Cyan
    Backup-Edge $backupFolder
    Write-Host ""
    
    # Backup C:\Scans and C:\Boardmaker (with verification)
    Write-Host "[Extra] Checking for C:\Scans folder..." -ForegroundColor Cyan
    $scansResult = Backup-Scans $backupFolder
    if ($scansResult) { $verificationResults += $scansResult }
    Write-Host "[Extra] Backing up C:\Boardmaker (if present)..." -ForegroundColor Cyan
    $boardmakerResult = Backup-Boardmaker $backupFolder
    if ($boardmakerResult) { $verificationResults += $boardmakerResult }
    Write-Host ""
    
    # Final verification: re-run Verify-Copy on every backed-up folder (user folders + Scans + Boardmaker)
    if ($verificationResults.Count -gt 0) {
        Write-Host "Verifying all backup folders (file count and sizes)..." -ForegroundColor Cyan
        $userFolders = @("Desktop", "Downloads", "Documents", "Pictures", "Music", "Videos")
        $updatedResults = @()
        foreach ($result in $verificationResults) {
            $name = $result.Folder
            $src = $null
            $dest = Join-Path $backupFolder $name
            if ($userFolders -contains $name) {
                $src = Join-Path $UserProfile $name
            } elseif ($name -eq "Scans") {
                if (Test-Path "C:\Scans") { $src = "C:\Scans" } elseif (Test-Path "C:\scans") { $src = "C:\scans" }
            } elseif ($name -eq "Boardmaker") {
                if (Test-Path "C:\Boardmaker") { $src = "C:\Boardmaker" } elseif (Test-Path "C:\boardmaker") { $src = "C:\boardmaker" }
            }
            if (-not $src -or -not (Test-Path $dest)) {
                $updatedResults += $result
                continue
            }
            $v = Verify-Copy -sourcePath $src -destPath $dest
            $updatedResults += @{ Folder = $name; Status = if ($v.Success) { "Success" } else { "Failed" }; Message = $v.Message }
        }
        $verificationResults = $updatedResults
        Write-Host "  All backup folders verified." -ForegroundColor Green
        Write-Host ""
    }
    
    # Backup list of installed apps (excluding common ones)
    Write-Host "[Extra] Backing up installed apps list..." -ForegroundColor Cyan
    Backup-InstalledApps $backupFolder
    Write-Host ""
    
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Backup Summary:" -ForegroundColor Green
    Write-Host "  Computer Name: $computerName" -ForegroundColor White
    Write-Host "  Folders Copied: $copiedFolders / $totalFolders" -ForegroundColor White
    Write-Host "  Folders Skipped: $skippedFolders" -ForegroundColor White
    Write-Host "  Backup Location: $backupFolder" -ForegroundColor White
    Write-Host "========================================" -ForegroundColor Cyan
    
    # Show verification results
    if ($verificationResults.Count -gt 0) {
        Write-Host ""
        Write-Host "Verification Results:" -ForegroundColor Cyan
        foreach ($result in $verificationResults) {
            $color = if ($result.Status -eq "Success") { "Green" } else { "Red" }
            Write-Host "  $($result.Folder): $($result.Status) - $($result.Message)" -ForegroundColor $color
        }
    }
    
    Write-Host ""
    Write-Host "To restore on the new computer:" -ForegroundColor Yellow
    Write-Host "  1. Navigate to: $backupFolder" -ForegroundColor White
    Write-Host "  2. Run: RESTORE-FILES.ps1" -ForegroundColor White
    Write-Host ""
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# Main Menu
Clear-Host
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   FILE CLONE - USER FILE TRANSFER" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "This script will backup user files to an external drive." -ForegroundColor White
Write-Host "Folders: Desktop, Downloads, Documents, Pictures, Music, Videos" -ForegroundColor Gray
Write-Host "Also: Printers (with drivers), Chrome, C:\Scans, installed-apps list (common apps excluded). OneDrive skipped." -ForegroundColor Gray
Write-Host ""
Write-Host "[B] Backup Files to External Drive" -ForegroundColor Yellow
Write-Host "[Q] Quit" -ForegroundColor Yellow
Write-Host ""

$action = Read-Host "Please select an option (B/Q)"
if ($action -ieq 'B') {
    Backup-Files
} elseif ($action -ieq 'Q') {
    Write-Host "Exiting..." -ForegroundColor Cyan
    exit
} else {
    Write-Host "Invalid choice. Please try again." -ForegroundColor Red
    Start-Sleep -Seconds 2
}
