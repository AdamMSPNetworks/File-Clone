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
            $registryKeys = @("Desktop", "Personal", "My Pictures", "My Music", "My Video")
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

# Function to verify copied files
function Verify-Copy($sourcePath, $destPath) {
    try {
        $sourceFiles = Get-ChildItem -Path $sourcePath -Recurse -File -ErrorAction SilentlyContinue
        $destFiles = Get-ChildItem -Path $destPath -Recurse -File -ErrorAction SilentlyContinue
        
        $sourceCount = $sourceFiles.Count
        $destCount = $destFiles.Count
        
        if ($sourceCount -eq 0 -and $destCount -eq 0) {
            return @{ Success = $true; Message = "Empty folder" }
        }
        
        if ($sourceCount -ne $destCount) {
            return @{ 
                Success = $false; 
                Message = "File count mismatch: Source=$sourceCount, Destination=$destCount" 
            }
        }
        
        # Verify file sizes match
        $mismatches = 0
        foreach ($sourceFile in $sourceFiles) {
            $relativePath = $sourceFile.FullName.Substring($sourcePath.Length + 1)
            $destFile = Join-Path $destPath $relativePath
            
            if (-not (Test-Path $destFile)) {
                $mismatches++
                continue
            }
            
            $sourceSize = $sourceFile.Length
            $destSize = (Get-Item $destFile).Length
            
            if ($sourceSize -ne $destSize) {
                $mismatches++
            }
        }
        
        if ($mismatches -gt 0) {
            return @{ 
                Success = $false; 
                Message = "$mismatches file(s) have size mismatches" 
            }
        }
        
        return @{ Success = $true; Message = "All $sourceCount files verified" }
    } catch {
        return @{ Success = $false; Message = "Verification error: $($_.Exception.Message)" }
    }
}

# Function to copy files with progress bar using robocopy
function Copy-FilesWithProgress($sourcePath, $destPath, $folderName) {
    try {
        # Get all files to copy
        $allFiles = Get-ChildItem -Path $sourcePath -Recurse -File -ErrorAction SilentlyContinue
        $totalFiles = $allFiles.Count
        $copiedFiles = 0
        $failedFiles = 0
        
        if ($totalFiles -eq 0) {
            return @{ Success = $true; Copied = 0; Failed = 0 }
        }
        
        # Calculate total size
        Write-Host "  Calculating total size..." -ForegroundColor Gray
        $totalSize = 0
        foreach ($file in $allFiles) {
            $totalSize += $file.Length
        }
        $totalSizeGB = [math]::Round($totalSize / 1GB, 2)
        $copiedSize = 0
        
        # Create destination directory structure
        New-Item -ItemType Directory -Path $destPath -Force | Out-Null
        
        Write-Host "  Starting robocopy of $totalFiles files ($totalSizeGB GB total)..." -ForegroundColor Gray
        Write-Host "  Press [C] to Cancel" -ForegroundColor Cyan
        Write-Host ""
        
        # Control flags
        $isCancelled = $false
        
        # Set up keyboard input monitoring for cancel
        $cancelRequested = $false
        
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
                } catch {}
                Start-Sleep -Milliseconds 100
            }
        } -ArgumentList $inputFile
        
        # Use robocopy with multi-threading and optimized settings for maximum speed
        # /MT:4 = 4 threads (can increase to 8 if needed, but 4 is usually optimal)
        # /R:1 = retry 1 time (faster than default 1 million retries)
        # /W:1 = wait 1 second between retries (faster)
        # /J = use unbuffered I/O (faster for large files, bypasses cache)
        # /FFT = assume FAT file times (2 second precision, faster than NTFS precision checks)
        # /256 = use 256KB buffer size (larger buffer = faster transfers)
        # /NP = no progress percentage (reduces overhead)
        # /NDL = no directory list (reduces output overhead)
        # /NFL = no file list (reduces output overhead)
        # /NJH = no job header (reduces output overhead)
        # /NJS = no job summary (reduces output overhead)
        
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
        # Get all removable and external drives (USB, External SSD, etc.)
        $drives = Get-WmiObject Win32_LogicalDisk -ErrorAction SilentlyContinue | Where-Object { 
            $_.DriveType -eq 2 -or  # Removable (USB)
            ($_.DriveType -eq 3 -and $_.Size -lt 500GB)  # Fixed disk but likely external SSD
        } | Where-Object { $_.DeviceID -ne $env:SystemDrive }
        
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

# Function to create restore script in backup folder
function Create-RestoreScript($backupFolder) {
    $restoreScript = @"
# PowerShell Restore Script
# Run this script on the new computer to restore files to the current user profile

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   FILE CLONE RESTORE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

`$UserProfile = [System.Environment]::GetFolderPath("UserProfile")
`$FoldersToRestore = @("Desktop", "Downloads", "Documents", "Pictures", "Music", "Videos")
`$backupPath = Split-Path -Parent `$PSScriptRoot

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
        
        # Calculate total size
        `$totalSize = 0
        foreach (`$file in `$files) {
            `$totalSize += `$file.Length
        }
        `$totalSizeGB = [math]::Round(`$totalSize / 1GB, 2)
        
        Write-Host "  Found `$totalFiles files (`$totalSizeGB GB)..." -ForegroundColor Gray
        
        try {
            # Create destination directory if needed
            if (-not (Test-Path `$dest)) {
                New-Item -ItemType Directory -Path `$dest -Force | Out-Null
            }
            
            # Use robocopy for fast, reliable copying
            `$robocopyArgs = @(
                "`"`$src`"",
                "`"`$dest`"",
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
        
        # Copy files with progress
        $copyResult = Copy-FilesWithProgress -sourcePath $sourcePath -destPath $destPath -folderName $folder
        
        if ($copyResult.Success) {
            Write-Host "  Copy completed: $($copyResult.Copied) files" -ForegroundColor Green
            
            # Verify the copy
            Write-Host "  Verifying copy..." -ForegroundColor Gray
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
Write-Host "Folders to backup: Desktop, Downloads, Documents, Pictures, Music, Videos" -ForegroundColor Gray
Write-Host "OneDrive synced folders will be automatically skipped." -ForegroundColor Gray
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
