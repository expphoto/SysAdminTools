function Repair-ShellFolderRegistry {
    $explorerPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer"
    $shellFoldersPath = "$explorerPath\Shell Folders"
    $userShellFoldersPath = "$explorerPath\User Shell Folders"

    Write-Host "Checking registry paths..." -ForegroundColor Cyan
    Write-Host "Explorer Path: $explorerPath"
    Write-Host "Shell Folders Path: $shellFoldersPath"
    Write-Host "User Shell Folders Path: $userShellFoldersPath"

    # Ensure parent path exists
    if (-not (Test-Path $explorerPath)) {
        Write-Host "Creating missing Explorer registry path..." -ForegroundColor Yellow
        New-Item -Path $explorerPath -Force | Out-Null
    }

    # Recreate Shell Folders key
    if (-not (Test-Path $shellFoldersPath)) {
        Write-Host "Creating missing Shell Folders key..." -ForegroundColor Yellow
        New-Item -Path $shellFoldersPath -Force | Out-Null
    }

    # Recreate User Shell Folders key
    if (-not (Test-Path $userShellFoldersPath)) {
        Write-Host "Creating missing User Shell Folders key..." -ForegroundColor Yellow
        New-Item -Path $userShellFoldersPath -Force | Out-Null
    }

    # Set default values with proper backslashes
    $defaultFolders = @{
        "Desktop" = "%USERPROFILE%\Desktop"
        "Personal" = "%USERPROFILE%\Documents"
        "My Pictures" = "%USERPROFILE%\Pictures"
        "My Videos" = "%USERPROFILE%\Videos"
        "My Music" = "%USERPROFILE%\Music"
        "Favorites" = "%USERPROFILE%\Favorites"
    }

    Write-Host ""
    Write-Host "Setting User Shell Folders..." -ForegroundColor Green
    foreach ($folder in $defaultFolders.GetEnumerator()) {
        try {
            New-ItemProperty -Path $userShellFoldersPath -Name $folder.Key -Value $folder.Value -PropertyType String -Force | Out-Null
            Write-Host "✓ Set $($folder.Key) = $($folder.Value)" -ForegroundColor Green
        } catch {
            Write-Host "✗ Failed to set $($folder.Key): $_" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host "Registry repair completed!" -ForegroundColor Cyan
}

Repair-ShellFolderRegistry
