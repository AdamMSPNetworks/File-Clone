# PowerShell script for Backup & Restore with Progress Bar and Error Handling

# Get user profile path
$UserProfile = [System.Environment]::GetFolderPath("UserProfile")
$FoldersToBackup = @("Desktop", "Downloads", "Documents", "Pictures", "Music", "Videos")

# Function to check if a folder is DFS or OneDrive managed
function Test-DFSOrOneDrive($folderPath) {
    if (-not (Test-Path $folderPath)) {
        return $true
    }
    $attributes = (Get-Item $folderPath).Attributes
    if ($attributes -match "ReparsePoint" -or $folderPath -match "OneDrive") {
        return $true
    }
    return $false
}

# Function to get total size of backup
function Get-TotalSize($folders) {
    $totalSize = 0
    foreach ($folder in $folders) {
        $fullPath = "$UserProfile\$folder"
        if (Test-Path $fullPath) {
            if (-not (Test-DFSOrOneDrive $fullPath)) {
                $totalSize += (Get-ChildItem -Path $fullPath -Recurse -File | Measure-Object -Property Length -Sum).Sum
            }
        }
    }
    return $totalSize
}

# Function to list available drives
function Get-AllDrives() {
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match "^[A-Z]:\\$" }
    return $drives
}

# Function to select a drive
function Select-Drive() {
    $drives = Get-AllDrives
    if (-not $drives) {
        Write-Host "No drives detected." -ForegroundColor Red
        return $null
    }

    Write-Host "Available Drives:"
    for ($i = 0; $i -lt $drives.Count; $i++) {
        Write-Host "[$($i+1)] $($drives[$i].Root) - $($drives[$i].Description)"
    }

    $choice = Read-Host "Select a drive (number)"
    if ($choice -match "^\d+$" -and [int]$choice -gt 0 -and [int]$choice -le $drives.Count) {
        return $drives[[int]$choice - 1].Root
    } else {
        Write-Host "Invalid selection." -ForegroundColor Red
        return $null
    }
}

# Function to copy files with a progress bar and error handling
function Copy-Files($sourceFolders, $destination) {
    $totalFolders = $sourceFolders.Count
    $currentFolder = 0

    foreach ($folder in $sourceFolders) {
        $sourcePath = "$UserProfile\$folder"
        $destPath = "$destination\$folder"

        if ((Test-Path $sourcePath) -and (-not (Test-DFSOrOneDrive $sourcePath))) {
            Write-Host "Copying $folder..."
            try {
                Copy-Item -Path $sourcePath -Destination $destPath -Recurse -Force -ErrorAction Stop
            } catch {
                Write-Host ("Error copying $folder " + $_) -ForegroundColor Yellow
            }
        } else {
            Write-Host "Skipping $folder (DFS or OneDrive detected or does not exist)"
        }
        $currentFolder++
        Write-Progress -Activity "Backing up files" -Status "$folder" -PercentComplete (($currentFolder / $totalFolders) * 100)
    }
}

# Function for Backup
function Backup() {
    $drive = Select-Drive
    if (-not $drive) {
        return
    }

    $deviceName = $env:COMPUTERNAME
    $backupFolder = "$drive\File-Clone\$deviceName"
    New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null

    $totalSize = Get-TotalSize $FoldersToBackup
    $driveLetter = $drive.Substring(0,1)
    $driveFreeSpace = (Get-PSDrive -Name $driveLetter).Free

    if ($totalSize -gt $driveFreeSpace) {
        Write-Host "Not enough space on the selected drive!" -ForegroundColor Red
        return
    }

    Copy-Files $FoldersToBackup $backupFolder
    Write-Host "Backup completed successfully!" -ForegroundColor Green

    # Create restore script in the backup folder
    $restoreScript = @"
`$backupRoot = '$backupFolder'
`$userProfile = [System.Environment]::GetFolderPath("UserProfile")
`$folders = @("Desktop", "Downloads", "Documents", "Pictures", "Music", "Videos")

foreach (`$folder in `$folders) {
    `$src = Join-Path `$backupRoot `$folder
    `$dest = Join-Path `$userProfile `$folder
    if (Test-Path `$src) {
        Remove-Item -Path `$dest -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Item -Path `$src -Destination `$dest -Recurse -Force
        Write-Host "Restored `$folder to `$dest"
    }
}

Write-Host "Restore completed successfully!" -ForegroundColor Green
"@

    Set-Content -Path "$backupFolder\restore.ps1" -Value $restoreScript
    Write-Host "Restore script created: $backupFolder\restore.ps1" -ForegroundColor Cyan
}

# Function for Restore
function Restore() {
    $drive = Select-Drive
    if (-not $drive) {
        return
    }

    $deviceName = $env:COMPUTERNAME
    $backupFolder = "$drive\File-Clone\$deviceName"

    if (-not (Test-Path $backupFolder)) {
        Write-Host "No backup found for this device on the selected drive!" -ForegroundColor Red
        return
    }

    foreach ($folder in $FoldersToBackup) {
        $src = "$backupFolder\$folder"
        $dest = "$UserProfile\$folder"

        if (Test-Path $src) {
            Write-Host "Restoring $folder..."
            Remove-Item -Path $dest -Recurse -Force -ErrorAction SilentlyContinue
            Copy-Item -Path $src -Destination $dest -Recurse -Force
        }
    }

    Write-Host "Restore completed successfully!" -ForegroundColor Green
}

# Main Menu
$action = Read-Host "Do you want to (B)ackup or (R)restore?"
if ($action -eq 'B') {
    Backup
} elseif ($action -eq 'R') {
    Restore
} else {
    Write-Host "Invalid choice." -ForegroundColor Red
}
