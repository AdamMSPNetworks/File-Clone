# File-Clone

A PowerShell script for backing up and restoring user files, printers, browser profiles, and system configurations when migrating between Windows computers or creating backups to external drives.

## Features

### 📁 **User Folder Backup**
- Automatically backs up Desktop, Downloads, Documents, Pictures, Music, and Videos
- Intelligently skips OneDrive-synced folders to avoid duplicates
- Progress tracking with file count and size estimates
- Verification after copy to ensure data integrity

### 🖨️ **Printer Backup & Restore**
- **Full printer backup** using Windows PrintBrm (like Print Management) - includes drivers and configurations
- Falls back to CSV export if PrintBrm is unavailable
- Automatically restores printers with drivers on the new computer
- Supports network printers and TCP/IP ports

### 🌐 **Browser Profile Backup**
- **Chrome**: Bookmarks, preferences, saved passwords (Login Data), and profile data
- **Edge**: Bookmarks, preferences, saved passwords (Login Data), and profile data
- Backs up all profiles (Default, Profile 1, Profile 2, etc.)
- Restores to the same locations on the new computer

### 📂 **Additional Backups**
- **C:\Scans** folder (if present) - automatically detected and backed up
- **Installed Apps List** - exports list of installed applications (excludes common apps like Chrome, 7-Zip, VLC, etc.)

### 🔍 **Smart Drive Detection**
- Automatically detects USB drives and external SSDs (including modern drives like Crucial X9)
- Uses USB interface detection for accurate drive identification
- Supports drives up to 4TB
- Interactive selection if multiple external drives are found

## Requirements

- **Windows** 7 or later (Windows 10/11 recommended)
- **PowerShell** 5.1 or later (included with Windows)
- **External drive** (USB drive, external SSD, etc.) with sufficient space
- **Administrator privileges** (recommended for printer backup with drivers)

## Installation

1. Clone or download this repository
2. No installation required - just run `FileClone.ps1`

### Building Executable (Optional)

To create a standalone `.exe` file:

```powershell
.\buildexe.ps1
```

This requires the `ps2exe` PowerShell module, which will be installed automatically if missing.

## Usage

### Backup Files

1. Connect your external drive (USB drive or external SSD)
2. Run `FileClone.ps1`:
   ```powershell
   .\FileClone.ps1
   ```
3. Select **`[B] Backup Files to External Drive`**
4. Choose your external drive if multiple are detected
5. Wait for backup to complete

The script will create a folder structure on your drive:
```
[Drive]:\File-Clone\[COMPUTER-NAME]\
├── Desktop\
├── Downloads\
├── Documents\
├── Pictures\
├── Music\
├── Videos\
├── Printers\
│   ├── PrintersBackup (PrintBrm backup with drivers)
│   └── printers.csv
├── Chrome\
│   └── Default\ (and Profile N folders)
│       ├── Bookmarks
│       ├── Login Data (passwords)
│       └── Preferences
├── Edge\
│   └── Default\ (and Profile N folders)
│       ├── Bookmarks
│       ├── Login Data (passwords)
│       └── Preferences
├── Scans\ (if C:\Scans exists)
└── InstalledApps\
    └── InstalledApps.txt
```

### Restore Files

1. Connect the external drive with your backup
2. Navigate to your computer's backup folder (e.g., `D:\File-Clone\NANDYS-WORLD\`)
3. Run `RESTORE-FILES.ps1`:
   ```powershell
   .\RESTORE-FILES.ps1
   ```
4. Confirm restoration when prompted
5. **For printer restore**: Run as Administrator if printer installation fails

The restore script will:
- Restore all user folders to the current user profile
- Restore printers with drivers (using PrintBrm if available)
- Restore Chrome and Edge bookmarks, preferences, and passwords
- Restore C:\Scans folder (if backed up)
- Handle usernames with spaces correctly

## How It Works

### Backup Process

1. **Drive Detection**: Scans for USB/external drives using WMI and USB interface detection
2. **Folder Backup**: Uses robocopy with multi-threading for fast, reliable copying
3. **Printer Backup**: Uses Windows PrintBrm.exe for full driver backup (requires admin)
4. **Browser Backup**: Copies key profile files from Chrome/Edge User Data folders
5. **Verification**: Verifies copied files match source (count and size)

### Restore Process

1. **Path Detection**: Automatically detects backup location from script folder
2. **File Restoration**: Uses robocopy to restore files with progress tracking
3. **Printer Restoration**: Uses PrintBrm to restore printers with drivers, or CSV fallback
4. **Browser Restoration**: Copies profile files back to Chrome/Edge User Data folders

## Important Notes

### OneDrive Integration
- Folders synced with OneDrive are **automatically skipped** during backup
- The script detects OneDrive sync status via registry and path analysis

### Printer Backup
- **Full driver backup** requires running as Administrator
- If PrintBrm backup fails, a CSV list is saved as fallback
- On restore, drivers must be available on the new PC (or installed separately)

### Browser Passwords
- Passwords are encrypted with Windows DPAPI (per-computer encryption)
- Restoring to the **same computer** (after reinstall) works perfectly
- Restoring to a **different computer** may not decrypt passwords (Windows security feature)
- For best results across different PCs, use Chrome/Edge sign-in sync

### Paths with Spaces
- The script correctly handles usernames and paths with spaces (e.g., `C:\Users\John Smith\Desktop`)

## Troubleshooting

### "No external drives found"
- Ensure your USB drive is connected and recognized by Windows
- Try a different USB port
- Check Disk Management to verify the drive is accessible

### Printer restore fails
- Run `RESTORE-FILES.ps1` as Administrator
- Ensure printer drivers are installed on the new PC
- Check PrintBrm backup file exists in `Printers\` folder

### Chrome/Edge restore doesn't work
- **Close Chrome and Edge** before running restore
- Ensure the backup contains Chrome/Edge folders
- Passwords may not decrypt on a different computer (expected behavior)

### "Invalid Parameter" errors during restore
- Ensure you're running the latest version of the restore script
- Check that paths don't have invalid characters

## File Structure

```
File-Clone/
├── FileClone.ps1          # Main backup script
├── buildexe.ps1          # Build script for creating .exe
├── LICENSE                # MIT License
├── README.md             # This file
└── .gitattributes        # Git configuration
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contributing

Contributions, issues, and feature requests are welcome! Feel free to check the issues page.

## Author

**AdamNMSP**

---

## Quick Reference

### Backup Command
```powershell
.\FileClone.ps1
# Then select [B] Backup Files to External Drive
```

### Restore Command
```powershell
cd D:\File-Clone\[YOUR-COMPUTER-NAME]
.\RESTORE-FILES.ps1
```

### Build Executable
```powershell
.\buildexe.ps1
```

---

**Note**: Always test backups before deleting original files. This script is provided as-is without warranty.
