Install-Module -Name ps2exe -Scope CurrentUser -Force
Remove-Item .\FileClone.exe
ps2exe -inputFile "File Clone.ps1" -outputFile "FileClone.exe"