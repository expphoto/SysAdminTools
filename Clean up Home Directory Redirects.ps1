 function Clean-Up-AllShellFoldersUNC {
    # List of keys to process
    $regPaths = @(
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"
    )
    $folderMap = @{
        'Desktop'     = 'Desktop'
        'Personal'    = 'Documents'
        'My Pictures' = 'Pictures'
        'My Videos'   = 'Videos'
        'My Video'    = 'Videos'
        'My Music'    = 'Music'
        '{F42EE2D3-909F-4907-8871-4C22FC0BF756}' = 'Documents'
        '{0DDD015D-B06C-45D5-8C4C-F59713854639}' = 'Pictures'
        '{374DE290-123F-4565-9164-39C4925E467B}' = 'Downloads'
        '{18989B1D-99B5-455B-841C-AB7C74E4DDFC}' = 'Videos'
        '{35286A68-3C57-41A1-BBB1-0EAE73D76C95}' = 'Videos'
    }
    foreach ($regPath in $regPaths) {
        Write-Host "`n--- Scanning $regPath ---`n" -ForegroundColor Cyan
        $shellFolders = Get-ItemProperty -Path $regPath
        foreach ($property in $shellFolders.PSObject.Properties) {
            $name  = $property.Name
            $value = $property.Value
            $shouldFix =
                ($value -like '\\*') -or
                ($name -match '^{[A-F0-9\-]+}$' -and ($value -like "$env:USERPROFILE\{*" -or $value -eq $name))
            if ($shouldFix) {
                $localName = $folderMap[$name]
                if (-not $localName) { $localName = $name }
                $localDefault = "$env:USERPROFILE\$localName"
                Set-ItemProperty -Path $regPath -Name $name -Value $localDefault -Force
                Write-Host "Reset [$name] in $regPath from $value to: $localDefault" -ForegroundColor Yellow
            }
        }
    }
}
Clean-Up-AllShellFoldersUNC