# Complete-OneDrive-Migration.ps1 - Comprehensive H Drive to OneDrive Migration
# Combines: Folder redirection cleanup, OneDrive setup, data migration, and validation
# Handles: AD home path removal, UNC cleanup, Known Folder Move, data transfer

param(
    [switch]$WhatIf,
    [string]$LogPath = "$env:TEMP\OneDriveMigration.log",
    [string]$TenantID = "", # Will be populated on work machine
    [switch]$CleanupOnly, # Only perform folder redirection cleanup
    [switch]$SkipDataMigration # Skip copying H drive data
)

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Write-Host $logEntry
    if (-not $WhatIf) {
        Add-Content -Path $LogPath -Value $logEntry -ErrorAction SilentlyContinue
    }
}

function Test-OneDriveInstalled {
    try {
        # Multiple ways to check OneDrive installation
        $oneDriveExe = "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe"
        $oneDriveProcess = Get-Process -Name "OneDrive" -ErrorAction SilentlyContinue
        $oneDriveRegistry = Get-ItemProperty "HKCU:\SOFTWARE\Microsoft\OneDrive" -ErrorAction SilentlyContinue
        $oneDriveService = Get-Service -Name "OneDrive Updater Service" -ErrorAction SilentlyContinue
        
        # Check if executable exists OR process is running OR registry key exists OR service exists
        $isInstalled = (Test-Path $oneDriveExe) -or 
                      ($oneDriveProcess -ne $null) -or 
                      ($oneDriveRegistry -ne $null) -or 
                      ($oneDriveService -ne $null)
        
        if ($isInstalled) {
            Write-Log "OneDrive installation detected via: $(if (Test-Path $oneDriveExe) {'executable '})$(if ($oneDriveProcess) {'process '})$(if ($oneDriveRegistry) {'registry '})$(if ($oneDriveService) {'service'})"
        }
        
        return $isInstalled
    } catch {
        Write-Log "Error checking OneDrive installation: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

function Remove-AllFolderRedirections {
    Write-Log "Comprehensive folder redirection cleanup - removing all UNC and malformed paths"
    
    try {
        # Registry paths to process (from both scripts)
        $regPaths = @(
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders",
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"
        )
        
        # Combined folder mappings from both scripts
        $folderMap = @{
            'Desktop'     = 'Desktop'
            'Personal'    = 'Documents'
            'My Pictures' = 'Pictures'
            'My Videos'   = 'Videos'
            'My Video'    = 'Videos'
            'My Music'    = 'Music'
            'Favorites'   = 'Favorites'
            # GUID mappings
            '{F42EE2D3-909F-4907-8871-4C22FC0BF756}' = 'Documents'
            '{0DDD015D-B06C-45D5-8C4C-F59713854639}' = 'Pictures'
            '{374DE290-123F-4565-9164-39C4925E467B}' = 'Downloads'
            '{18989B1D-99B5-455B-841C-AB7C74E4DDFC}' = 'Videos'
            '{35286A68-3C57-41A1-BBB1-0EAE73D76C95}' = 'Videos'
        }
        
        $changesMode = 0
        
        foreach ($regPath in $regPaths) {
            Write-Log "Processing registry path: $regPath"
            
            if (-not (Test-Path $regPath)) {
                Write-Log "Registry path does not exist: $regPath" -Level "WARN"
                continue
            }
            
            $shellFolders = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
            if (-not $shellFolders) {
                Write-Log "Could not read registry path: $regPath" -Level "WARN"
                continue
            }
            
            foreach ($property in $shellFolders.PSObject.Properties) {
                $name = $property.Name
                $value = $property.Value
                
                # Skip system properties
                if ($name -in @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')) {
                    continue
                }
                
                # Determine if this needs fixing (UNC paths, malformed GUIDs, etc.)
                $shouldFix = ($value -like '\\*') -or  # UNC paths
                           ($name -match '^{[A-F0-9\-]+}$' -and ($value -like "$env:USERPROFILE\{*" -or $value -eq $name)) -or  # Malformed GUID paths
                           ($value -like '*H:*') -or  # H drive references
                           ($value -like '*\\server\*')  # Any server references
                
                if ($shouldFix) {
                    $localName = $folderMap[$name]
                    if (-not $localName) { 
                        # If not in map, try to derive from the name
                        $localName = $name -replace '^My ', '' -replace 'Personal', 'Documents'
                    }
                    
                    $localDefault = "$env:USERPROFILE\$localName"
                    
                    if ($WhatIf) {
                        Write-Log "WHATIF: Would reset [$name] from '$value' to '$localDefault'" -Level "INFO"
                    } else {
                        try {
                            Set-ItemProperty -Path $regPath -Name $name -Value $localDefault -Force -ErrorAction Stop
                            Write-Log "Reset [$name] from '$value' to '$localDefault'"
                            $changesMode++
                        } catch {
                            Write-Log "Failed to reset [$name]: $($_.Exception.Message)" -Level "WARN"
                        }
                    }
                }
            }
        }
        
        Write-Log "Folder redirection cleanup completed. $changesMode changes made."
        
        # Refresh Explorer shell
        if ($changesMode -gt 0 -and -not $WhatIf) {
            try {
                $signature = @'
[DllImport("shell32.dll")]
public static extern void SHChangeNotify(uint wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);
'@
                $type = Add-Type -MemberDefinition $signature -Name Win32Utils -Namespace SHChangeNotify -PassThru -ErrorAction SilentlyContinue
                if ($type) {
                    $type::SHChangeNotify(0x8000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
                    Write-Log "Explorer shell refreshed via API"
                } else {
                    throw "Failed to load Win32 API"
                }
            } catch {
                Write-Log "Could not refresh shell via API, attempting Explorer restart: $($_.Exception.Message)" -Level "WARN"
                try {
                    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 3
                    Start-Process explorer.exe -ErrorAction Stop
                    Write-Log "Explorer restarted successfully"
                } catch {
                    Write-Log "Failed to restart Explorer: $($_.Exception.Message)" -Level "ERROR"
                }
            }
        }
        
        return $true
    } catch {
        Write-Log "Error in Remove-AllFolderRedirections: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

function Enable-OneDriveKnownFolderMove {
    param([string]$TenantID)
    Write-Log "Configuring OneDrive Known Folder Move with TenantID: $TenantID"
    
    try {
        $OneDrivePolicyKey = "HKCU:\SOFTWARE\Policies\Microsoft\OneDrive"
        if (-not (Test-Path $OneDrivePolicyKey)) { 
            if ($WhatIf) {
                Write-Log "WHATIF: Would create OneDrive policy registry key" -Level "INFO"
            } else {
                New-Item -Path $OneDrivePolicyKey -Force | Out-Null 
            }
        }
        
        if ($WhatIf) {
            Write-Log "WHATIF: Would configure KFM policies for tenant $TenantID" -Level "INFO"
            return $true
        }
        
        # Set KFM policies with proper tenant ID
        Set-ItemProperty -Path $OneDrivePolicyKey -Name "KFMOptInWithWizard" -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $OneDrivePolicyKey -Name "KFMSilentOptIn" -Value $TenantID -Type String -Force
        Set-ItemProperty -Path $OneDrivePolicyKey -Name "KFMSilentOptInDesktop" -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $OneDrivePolicyKey -Name "KFMSilentOptInDocuments" -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $OneDrivePolicyKey -Name "KFMSilentOptInPictures" -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $OneDrivePolicyKey -Name "KFMBlockOptOut" -Value 1 -Type DWord -Force
        
        Write-Log "OneDrive Known Folder Move policy configured successfully"
        return $true
    } catch {
        Write-Log "Failed to configure OneDrive KFM: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

function Copy-HdriveData {
    param([string]$SourcePath, [string]$DestinationPath)
    if (-not (Test-Path $SourcePath)) {
        Write-Log "Source path does not exist: $SourcePath" -Level "WARN"
        return $false
    }
    Write-Log "Copying data from $SourcePath to $DestinationPath (using Robocopy)"
    
    if (-not (Test-Path $DestinationPath)) {
        if ($WhatIf) {
            Write-Log "WHATIF: Would create destination directory $DestinationPath" -Level "INFO"
        } else {
            New-Item -Path $DestinationPath -ItemType Directory -Force | Out-Null
        }
    }

    if ($WhatIf) {
        Write-Log "WHATIF: Would copy files from $SourcePath to $DestinationPath using Robocopy" -Level "INFO"
        return $true
    }

    $logfile = Join-Path $env:TEMP "robocopy-$(Get-Date -Format 'yyyyMMddHHmmss').log"

    $args = @(
        """$SourcePath""", """$DestinationPath""",
        '/E', '/Z', '/V',
        '/R:3', '/W:5',
        '/TEE', "/LOG+:$logfile"
    )

    $proc = Start-Process -FilePath 'robocopy.exe' -ArgumentList $args -Wait -NoNewWindow -PassThru
    $exitCode = $proc.ExitCode

    if ($exitCode -lt 8) {
        Write-Log "Robocopy completed successfully from $SourcePath to $DestinationPath. Log: $logfile"
        return $true
    } else {
        Write-Log "Robocopy encountered errors (exit code $exitCode). See log: $logfile" -Level "ERROR"
        return $false
    }
}

function Start-OneDriveProcess {
    Write-Log "Starting OneDrive process"
    
    try {
        $oneDrivePath = "${env:LOCALAPPDATA}\Microsoft\OneDrive\OneDrive.exe"
        
        if (-not (Test-Path $oneDrivePath)) {
            Write-Log "OneDrive executable not found at $oneDrivePath" -Level "ERROR"
            return $false
        }
        
        if ($WhatIf) {
            Write-Log "WHATIF: Would start OneDrive process" -Level "INFO"
            return $true
        }
        
        # Check if OneDrive is already running
        $existingProcess = Get-Process -Name "OneDrive" -ErrorAction SilentlyContinue
        if ($existingProcess) {
            Write-Log "OneDrive is already running (PID: $($existingProcess.Id))"
            return $true
        }
        
        Start-Process -FilePath $oneDrivePath -WindowStyle Hidden -ErrorAction Stop
        Write-Log "OneDrive process started successfully"
        Start-Sleep -Seconds 10  # Allow OneDrive to initialize
        
        # Verify process started
        $newProcess = Get-Process -Name "OneDrive" -ErrorAction SilentlyContinue
        if ($newProcess) {
            Write-Log "OneDrive process confirmed running (PID: $($newProcess.Id))"
            return $true
        } else {
            Write-Log "OneDrive process may not have started properly" -Level "WARN"
            return $false
        }
    } catch {
        Write-Log "Error starting OneDrive process: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

function Validate-OneDriveKFMRegistry {
    param([string]$ExpectedTenantID)

    try {
        $regPath = "HKCU:\SOFTWARE\Policies\Microsoft\OneDrive"
        if (-not (Test-Path $regPath)) {
            Write-Log "OneDrive policy registry path does not exist" -Level "WARN"
            return $false
        }
        
        $expected = @{
            "KFMSilentOptIn"          = $ExpectedTenantID
            "KFMSilentOptInDocuments" = 1
            "KFMSilentOptInPictures"  = 1
            "KFMSilentOptInDesktop"   = 1
            "KFMBlockOptOut"          = 1
        }
        
        $allGood = $true
        Write-Log "Validating OneDrive KFM Registry settings..."
        
        foreach ($key in $expected.Keys) {
            $actual = (Get-ItemProperty -Path $regPath -Name $key -ErrorAction SilentlyContinue).$key
            if ($actual -ne $expected[$key]) {
                Write-Log "Registry mismatch: $key should be '$($expected[$key])', found '$actual'" -Level "WARN"
                $allGood = $false
            } else {
                Write-Log "Registry OK: $key = $actual"
            }
        }
        
        if ($allGood) {
            Write-Log "All OneDrive KFM registry values validated successfully"
        } else {
            Write-Log "One or more KFM registry values are incorrect or missing" -Level "WARN"
        }
        return $allGood
    } catch {
        Write-Log "Error validating OneDrive KFM registry: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

# ===== MAIN EXECUTION =====

Write-Log "=== Complete OneDrive Migration Script Started ===" -Level "INFO"
Write-Log "Parameters: WhatIf=$WhatIf, LogPath=$LogPath, TenantID=$TenantID, CleanupOnly=$CleanupOnly, SkipDataMigration=$SkipDataMigration"

# Parameter validation - only validate if TenantID is provided
if ([string]::IsNullOrWhiteSpace($TenantID)) {
    Write-Log "No TenantID provided - OneDrive KFM configuration will be skipped" -Level "WARN"
    $SkipKFM = $true
} elseif ($TenantID -match "^<.*>$" -or $TenantID -eq "00000000-0000-0000-0000-000000000000") {
    Write-Error "Invalid TenantID provided. Please specify a valid Office 365 Tenant GUID."
    Write-Error "Example: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    exit 1
} elseif (-not ($TenantID -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')) {
    Write-Error "TenantID format is invalid. Must be a valid GUID format."
    exit 1
} else {
    $SkipKFM = $false
}

# Check current user environment
$currentUser = $env:USERNAME
$homeShare = $env:HOMESHARE
$homePath = $env:HOMEPATH
Write-Log "Current user: $currentUser"
Write-Log "Home share: $homeShare"
Write-Log "Home path: $homePath"

# Step 1: Comprehensive folder redirection cleanup
Write-Log "=== Step 1: Folder Redirection Cleanup ===" -Level "INFO"
$redirectionResult = Remove-AllFolderRedirections
if (-not $redirectionResult) {
    Write-Log "Folder redirection removal failed - continuing with migration" -Level "WARN"
}

# If CleanupOnly mode, stop here
if ($CleanupOnly) {
    Write-Log "=== Cleanup Only Mode - Migration Complete ===" -Level "INFO"
    if (-not $WhatIf) {
        Write-Log "Cleanup completed. Log saved to: $LogPath"
        Write-Host "`nFolder redirection cleanup completed!" -ForegroundColor Green
        Write-Host "Log file: $LogPath" -ForegroundColor Yellow
    }
    exit 0
}

# Pre-flight checks for OneDrive
if (-not (Test-OneDriveInstalled)) {
    Write-Log "OneDrive is not properly installed on this system" -Level "ERROR"
    Write-Log "Please install OneDrive before running this migration script" -Level "ERROR"
    exit 1
}

# Step 2: Configure OneDrive Known Folder Move (if TenantID provided)
Write-Log "=== Step 2: OneDrive Configuration ===" -Level "INFO"
if (-not $SkipKFM) {
    $kfmResult = Enable-OneDriveKnownFolderMove -TenantID $TenantID
    if (-not $kfmResult) {
        Write-Log "Failed to configure OneDrive KFM - continuing with migration" -Level "WARN"
    }
} else {
    Write-Log "Skipping OneDrive KFM configuration - no TenantID provided" -Level "INFO"
}

# Step 3: Start OneDrive if not running
Write-Log "=== Step 3: OneDrive Process Management ===" -Level "INFO"
$oneDriveRunning = Get-Process -Name "OneDrive" -ErrorAction SilentlyContinue
if (-not $oneDriveRunning) {
    $started = Start-OneDriveProcess
    if (-not $started) {
        Write-Log "Failed to start OneDrive - user may need to sign in manually" -Level "WARN"
    }
} else {
    Write-Log "OneDrive already running"
}

# Step 4: Copy H drive data to local folders (if H drive exists and not skipped)
Write-Log "=== Step 4: Data Migration ===" -Level "INFO"
if (-not $SkipDataMigration -and $homeShare -and $homePath) {
    $hDrivePath = "$homeShare$homePath"
    if (Test-Path $hDrivePath) {
        Write-Log "H drive detected at: $hDrivePath"
        
        # Copy Documents
        $sourceDocuments = $hDrivePath
        $destDocuments = "${env:USERPROFILE}\Documents"
        Copy-HdriveData -SourcePath $sourceDocuments -DestinationPath $destDocuments
        
        # Copy other folders if they exist
        $foldersToCopy = @{
            "Pictures" = "${env:USERPROFILE}\Pictures"
            "Videos" = "${env:USERPROFILE}\Videos"  
            "Music" = "${env:USERPROFILE}\Music"
            "Favorites" = "${env:USERPROFILE}\Favorites"
        }
        
        foreach ($folder in $foldersToCopy.GetEnumerator()) {
            $sourceFolder = Join-Path $hDrivePath $folder.Key
            if (Test-Path $sourceFolder) {
                Copy-HdriveData -SourcePath $sourceFolder -DestinationPath $folder.Value
            }
        }
    } else {
        Write-Log "H drive path not accessible: $hDrivePath" -Level "WARN"
    }
} elseif ($SkipDataMigration) {
    Write-Log "Skipping data migration as requested" -Level "INFO"
} else {
    Write-Log "No H drive environment variables detected" -Level "INFO"
}

# Step 5: Validate configuration and restart OneDrive (if KFM was configured)
Write-Log "=== Step 5: Validation and Final Setup ===" -Level "INFO"
if (-not $SkipKFM) {
    $validationResult = Validate-OneDriveKFMRegistry -ExpectedTenantID $TenantID
} else {
    $validationResult = $true
    Write-Log "Skipping KFM registry validation - no TenantID provided" -Level "INFO"
}

if ($validationResult) {
    Write-Log "Registry validation passed - restarting OneDrive to apply policies"
    
    if (-not $WhatIf) {
        try {
            Get-Process "OneDrive" -ErrorAction SilentlyContinue | Stop-Process -Force
            Start-Sleep -Seconds 5
            $oneDriveExe = "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe"
            if (Test-Path $oneDriveExe) { 
                Start-Process $oneDriveExe 
                Write-Log "OneDrive restarted successfully"
            }
        } catch {
            Write-Log "Failed to restart OneDrive: $($_.Exception.Message)" -Level "WARN"
        }
    }
} else {
    Write-Log "Registry validation failed - manual intervention may be required" -Level "WARN"
}

# Final status
Write-Log "=== Migration Steps Completed ===" -Level "INFO"
Write-Log "Next manual steps for user:"
Write-Log "1. Sign into OneDrive if not already signed in"  
Write-Log "2. Verify Known Folder Move is working (check OneDrive settings)"
Write-Log "3. Wait for initial sync to complete"
Write-Log "4. Verify all data is accessible through OneDrive"

if (-not $WhatIf) {
    Write-Log "Migration completed. Log saved to: $LogPath"
    Write-Host "`nComplete OneDrive migration finished successfully!" -ForegroundColor Green
    Write-Host "Log file: $LogPath" -ForegroundColor Yellow
    Write-Host "`nPlease ensure user signs into OneDrive and verifies sync is working." -ForegroundColor Cyan
}