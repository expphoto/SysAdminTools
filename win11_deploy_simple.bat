@echo off
echo Downloading and running Windows 11 upgrade script...
echo Please wait...

powershell -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri 'https://f001.backblazeb2.com/file/NinjaWebMedia/Windows11_Upgrade_Script_Fixed.ps1' -OutFile '%TEMP%\win11_upgrade.ps1'; & '%TEMP%\win11_upgrade.ps1'"

pause