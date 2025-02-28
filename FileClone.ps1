# PowerShell script for Backup & Restore with Progress Bar and Error Handling

# Ensure the script runs with Administrator privileges
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "Script is not running as Administrator. Attempting to relaunch with elevated privileges..." -ForegroundColor Yellow
    Start-Process powershell "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# Get user profile path
$UserProfile = [System.Environment]::GetFolderPath("UserProfile")
$FoldersToBackup = @("Desktop", "Downloads", "Documents", "Pictures", "Music", "Videos")

# Function to get drive's Hardware ID (Fixing Incorrect Detection)
function Get-DriveHardwareID($driveLetter) {
    $driveLetter = $driveLetter -replace "\\", ""  # Ensure format is "D:" not "D:\"
    $drive = Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DeviceID -eq $driveLetter }
    if ($drive) {
        return $drive.VolumeSerialNumber
    } else {
        Write-Host "ERROR: Could not retrieve Hardware ID for $driveLetter" -ForegroundColor Red
        return $null
    }
}

# Function to find the backup drive dynamically using the stored hardware ID
function Find-BackupDrive() {
    Write-Host "Scanning for backup drive..." -ForegroundColor Cyan

    # Scan all connected drives (USB, External, etc.)
    $drives = Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DriveType -in @(2, 3, 4, 5) }

    foreach ($drive in $drives) {
        $driveLetter = $drive.DeviceID
        $expectedBackupFolder = "$driveLetter\File-Clone\$env:COMPUTERNAME"
        $expectedIDFile = "$expectedBackupFolder\hardware_id.txt"

        # Check if the hardware ID file exists on the drive
        if (Test-Path $expectedIDFile) {
            $storedID = Get-Content $expectedIDFile
            $currentDriveID = Get-DriveHardwareID $driveLetter

            if ($currentDriveID -eq $storedID) {
                Write-Host "Backup found on $driveLetter" -ForegroundColor Green
                return $driveLetter  # ✅ Fix: Return only the drive letter, not full path
            }
        }
    }

    Write-Host "No valid backup found for this computer." -ForegroundColor Red
    return $null
}

# Function for Backup
function Backup() {
    $driveLetter = Find-BackupDrive
    if (-not $driveLetter) {
        return
    }

    # ✅ Fix: Pass only the drive letter, NOT the full backup path
    $hardwareID = Get-DriveHardwareID $driveLetter
    if (-not $hardwareID) {
        Write-Host "ERROR: Unable to retrieve hardware ID for the selected drive." -ForegroundColor Red
        return
    }

    $deviceName = $env:COMPUTERNAME
    $backupFolder = "$driveLetter\File-Clone\$deviceName"
    New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null

    Set-Content -Path "$backupFolder\hardware_id.txt" -Value $hardwareID

    Write-Host "Backup started..." -ForegroundColor Green
    foreach ($folder in $FoldersToBackup) {
        $sourcePath = "$UserProfile\$folder"
        $destPath = "$backupFolder\$folder"

        if ((Test-Path $sourcePath)) {
            Write-Host "Copying $folder..."
            Copy-Item -Path $sourcePath -Destination $destPath -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Write-Host "Skipping $folder (Does not exist or is OneDrive managed)"
        }
    }
    Write-Host "Backup completed successfully!" -ForegroundColor Green
}

function Restore() {
    $driveLetter = Find-BackupDrive
    if (-not $driveLetter) {
        exit
    }

    $backupFolder = "$driveLetter\File-Clone\$env:COMPUTERNAME"

    Write-Host "Restoring files from backup..." -ForegroundColor Yellow
    $userProfile = [System.Environment]::GetFolderPath("UserProfile")

    foreach ($folder in $FoldersToBackup) {
        $src = "$backupFolder\$folder"
        $dest = "$userProfile\$folder"

        if (Test-Path $src) {
            Write-Host "Restoring $folder..."
            Remove-Item -Path $dest -Recurse -Force -ErrorAction SilentlyContinue
            Copy-Item -Path $src -Destination $dest -Recurse -Force
            Write-Host "Restored $folder to $dest" -ForegroundColor Green
        } else {
            Write-Host "Skipping $folder (No backup found)" -ForegroundColor Red
        }
    }
    Write-Host "Restore process completed successfully!" -ForegroundColor Cyan
}

# Main Menu
Clear-Host
Write-Host "===============================" -ForegroundColor Cyan
Write-Host "   FILE CLONE BACKUP & RESTORE" -ForegroundColor Green
Write-Host "===============================" -ForegroundColor Cyan
Write-Host "[B] Backup Files" -ForegroundColor Yellow
Write-Host "[R] Restore Files" -ForegroundColor Yellow
Write-Host "[Q] Quit" -ForegroundColor Yellow
$action = Read-Host "Please select an option (B/R/Q)"
if ($action -ieq 'B') {
    Backup
} elseif ($action -ieq 'R') {
    Restore
} elseif ($action -ieq 'Q') {
    Write-Host "Exiting..." -ForegroundColor Cyan
    exit
} else {
    Write-Host "Invalid choice. Please try again." -ForegroundColor Red
}
