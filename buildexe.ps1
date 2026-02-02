# Auto-build script to create FileClone.exe from FileClone.ps1

Write-Host "Building FileClone.exe..." -ForegroundColor Cyan

# Check if ps2exe module is installed
$ps2exeInstalled = Get-Module -ListAvailable -Name ps2exe
if (-not $ps2exeInstalled) {
    Write-Host "Installing ps2exe module..." -ForegroundColor Yellow
    try {
        Install-Module -Name ps2exe -Scope CurrentUser -Force -ErrorAction Stop
        Write-Host "ps2exe module installed successfully." -ForegroundColor Green
    } catch {
        Write-Host "Error installing ps2exe module: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Please run PowerShell as Administrator and try again." -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-Host "ps2exe module found." -ForegroundColor Green
}

# Check if FileClone.ps1 exists
if (-not (Test-Path "FileClone.ps1")) {
    Write-Host "Error: FileClone.ps1 not found in current directory." -ForegroundColor Red
    exit 1
}

# Remove old exe if it exists
if (Test-Path "FileClone.exe") {
    Write-Host "Removing old FileClone.exe..." -ForegroundColor Yellow
    Remove-Item "FileClone.exe" -Force -ErrorAction SilentlyContinue
}

# Build the exe
Write-Host "Creating FileClone.exe..." -ForegroundColor Cyan
try {
    Import-Module ps2exe -Force
    ps2exe -inputFile "FileClone.ps1" -outputFile "FileClone.exe"
    
    if (Test-Path "FileClone.exe") {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "Build completed successfully!" -ForegroundColor Green
        Write-Host "File: FileClone.exe" -ForegroundColor White
        Write-Host "========================================" -ForegroundColor Green
    } else {
        Write-Host "Error: FileClone.exe was not created." -ForegroundColor Red
        exit 1
    }
} catch {
    Write-Host "Error building exe: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
