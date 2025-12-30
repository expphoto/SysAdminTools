<#
.SYNOPSIS
    Automox Rescue Script: Zscaler Fix & Install
    1. Copies Zscaler Root CA to target.
    2. Imports CA to Trusted Root Store.
    3. Runs Official Cleanup.
    4. Installs Agent v2.4.42.
#>

# ---------------- CONFIGURATION ----------------
$accessKey = "YOUR_ZONE_ACCESS_KEY_HERE" 
$localMsiPath = "C:\Installers\Automox_Installer-2.4.42.msi"
$zscalerCertPath = "C:\Installers\ZscalerRoot.crt" # <--- UPDATE THIS PATH

$computers = @(
    "NAME1", "NAME2"
)
# -----------------------------------------------

# Validate Files
if (-not (Test-Path $localMsiPath)) { Write-Error "MSI not found"; Exit }
if (-not (Test-Path $zscalerCertPath)) { Write-Error "Certificate not found"; Exit }

Write-Host "Starting Rescue Mission (Zscaler Fix)..." -ForegroundColor Cyan

foreach ($computer in $computers) {
    Write-Host "Processing $computer..." -NoNewline
    
    try {
        $session = New-PSSession -ComputerName $computer -ErrorAction Stop
        
        # 1. Copy Files (MSI + Cert)
        Copy-Item -Path $localMsiPath -Destination "C:\Windows\Temp\Automox.msi" -ToSession $session -Force
        Copy-Item -Path $zscalerCertPath -Destination "C:\Windows\Temp\ZscalerRoot.crt" -ToSession $session -Force
        
        Invoke-Command -Session $session -ScriptBlock {
            param($key)
            
            # --- STEP 1: IMPORT ZSCALER CERT ---
            Write-Output "Importing Zscaler Root Certificate..."
            try {
                Import-Certificate -FilePath "C:\Windows\Temp\ZscalerRoot.crt" -CertStoreLocation "Cert:\LocalMachine\Root" -Verbose | Out-Null
                Write-Output "Certificate Import Successful."
            } catch {
                Write-Error "Certificate Import Failed: $($_.Exception.Message)"
                return "Failed: Cert Import Error"
            }
            
            # --- STEP 2: CLEANUP ---
            function CleanUp-AxAgent {
                Write-Output "Running Cleanup..."
                # Uninstall MSI
                $uninstReg = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
                $installed = @(Get-ChildItem $uninstReg -ErrorAction SilentlyContinue | Get-ItemProperty | Where-Object { ($_.DisplayName -match 'Automox Agent') })
                if ($installed) { Start-Process msiexec.exe -ArgumentList "/x $( $installed.PSChildName ) /qn REBOOT=ReallySuppress" -Wait -PassThru | Out-Null }
                
                # Nuke Processes/Services/Files
                Stop-Process -Name "amagent", "automox", "remotecontrold", "msiexec" -Force -ErrorAction SilentlyContinue
                Remove-Item "C:\ProgramData\amagent", "${env:ProgramFiles}\Automox", "${env:ProgramFiles(x86)}\Automox" -Recurse -Force -ErrorAction SilentlyContinue
                
                # Nuke Registry
                Remove-Item "HKCR:\Installer\Products\*" -Recurse -ErrorAction SilentlyContinue | Where-Object { (Get-ItemProperty $_.PSPath).ProductName -match "Automox Agent" } | Remove-Item -Recurse -Force
                Remove-Item "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\*" -Recurse -ErrorAction SilentlyContinue | Where-Object { (Get-ItemProperty $_.PSPath).DisplayName -match "Automox Agent" } | Remove-Item -Recurse -Force
            }
            CleanUp-AxAgent
            
            # --- STEP 3: INSTALL AGENT ---
            Start-Sleep 2
            Write-Output "Installing New Agent..."
            
            $msiPath = "C:\Windows\Temp\Automox.msi"
            $logPath = "C:\Windows\Temp\am_upgrade.log"
            
            # Arguments: Quiet, Link Key, Force Overwrite
            # Removed SKIP_SELF_TEST to verify cert works. If it fails again, add it back.
            $args = "/i `"$msiPath`" /qn ACCESSKEY=`"$key`" /norestart /log `"$logPath`""
            
            $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $args -Wait -PassThru
            
            if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
                Start-Sleep 5
                if ((Get-Service "automox" -ErrorAction SilentlyContinue).Status -eq "Running") {
                    return "SUCCESS: Installed & Running (Cert Verified)"
                } else {
                    Start-Service "automox" -ErrorAction SilentlyContinue
                    return "SUCCESS: Installed (Service Started)"
                }
            } else {
                return "FAILURE: Exit Code $($proc.ExitCode)"
            }
            
        } -ArgumentList $accessKey
        
        Remove-PSSession -Session $session
        Write-Host " Done." -ForegroundColor Green
        
    } catch {
        Write-Host " ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
}
