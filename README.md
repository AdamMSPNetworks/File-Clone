# File-Clone

A PowerShell script for backing up and restoring user files, printers, browser profiles, and system configurations when migrating between Windows computers or creating backups to external drives.

## Features

### 📁 **User Folder Backup**
- Automatically backs up Desktop, Downloads, Documents, Pictures, Music, and Videos
- Intelligently skips OneDrive-synced folders to avoid duplicates
- Progress tracking with file count and size estimates
- Verification after copy to ensure data integrity

### 🖨️ **Printer Backup & Restore**
- **Full printer backup** using Windows PrintBrm (same as Print Management / printmanagement.msc) - includes **drivers and driver files**
- Saves `Printers.printerExport` when PrintBrm is available; always saves `Printers.json` (manifest) as fallback
- Restore uses PrintBrm when `.printerExport` exists (installs drivers + printers), or JSON when only manifest is present
- Supports network printers and TCP/IP ports; handles paths with spaces via temp copy

### 🌐 **Browser Profile Backup**
- **Chrome**: Bookmarks, preferences, saved passwords (Login Data), and profile data
- **Edge**: Bookmarks, preferences, saved passwords (Login Data), and profile data
- Backs up all profiles (Default, Profile 1, Profile 2, etc.)
- Restores to the same locations on the new computer

### 📂 **Additional Backups**
- **C:\Scans** – folder backed up if `C:\Scans` or `C:\scans` exists
- **C:\Boardmaker** – folder backed up if `C:\Boardmaker` or `C:\boardmaker` exists
- **Installed Apps List** – exports list of installed applications (excludes common apps like Chrome, 7-Zip, VLC, etc.)

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
├── RESTORE-FILES.ps1
├── Desktop\
├── Downloads\
├── Documents\
├── Pictures\
├── Music\
├── Videos\
├── Printers.printerExport   (full backup with drivers, when PrintBrm available)
├── Printers.json            (printer/driver/port manifest, always)
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
├── Scans\                   (if C:\Scans or C:\scans existed)
├── Boardmaker\              (if C:\Boardmaker or C:\boardmaker existed)
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
- Restore printers and drivers (using PrintBrm when `Printers.printerExport` exists, else JSON manifest)
- Restore Chrome and Edge bookmarks, preferences, and passwords
- Restore **C:\Scans** folder (if backed up)
- Restore **C:\Boardmaker** folder (if backed up)
- Handle usernames and paths with spaces correctly

## How It Works

### Backup Process

1. **Drive Detection**: Scans for USB/external drives (WMI)
2. **Folder Backup**: Robocopy with multi-threading for user folders (Desktop, Documents, etc.)
3. **Printer Backup**: PrintBrm.exe for full backup (drivers + printers); always writes Printers.json manifest
4. **Browser Backup**: Copies Chrome/Edge User Data (bookmarks, Login Data, preferences)
5. **Extra Folders**: Backs up C:\Scans and C:\Boardmaker if present (robocopy)
6. **Verification**: Verifies copied user folders (count and size)

### Restore Process

1. **Path Detection**: Backup path = folder containing RESTORE-FILES.ps1
2. **File Restoration**: Robocopy to restore user folders to current profile
3. **Printer Restoration**: PrintBrm when Printers.printerExport exists; else Add-Printer from Printers.json
4. **Browser Restoration**: Copies Chrome/Edge profile files back to User Data folders
5. **Extra Folders**: Restores C:\Scans and C:\Boardmaker to C:\ if backed up

## Important Notes

### OneDrive Integration
- Folders synced with OneDrive are **automatically skipped** during backup
- The script detects OneDrive sync status via registry and path analysis

### Printer Backup
- **Full driver backup** (PrintBrm) works best when run as Administrator
- `Printers.printerExport` includes driver files (like Print Management); `Printers.json` is always written as a manifest/fallback
- On restore: if `.printerExport` exists, PrintBrm installs drivers and printers; if only JSON exists, drivers must already be on the new PC

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
- Run `RESTORE-FILES.ps1` as **Administrator**
- If using JSON-only restore, install the required printer drivers on the new PC first
- Ensure `Printers.printerExport` or `Printers.json` exists in the backup folder (same folder as `RESTORE-FILES.ps1`)

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
