#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidateSet("start", "run", "status", "stop")]
    [string]$Action = "start",
    [string]$LocalRoot = "C:\ProgramData\AD-Comprehensive-Backup",
    [int]$LocalRetentionDays = 14,
    [int]$RemoteRetentionDays = 30,
    [ValidateSet("true", "false")]
    [string]$EnableUpload = "true"
)

$ErrorActionPreference = "Stop"
$EnableUploadBool = $EnableUpload -eq "true"

# ==========================
# Storage Box configuration
# ==========================
$StorageHost = "u317918.your-storagebox.de"
$StoragePort = 23
$StorageUser = "u317918-sub6"
$StoragePassword = "S7#qP@%WQZ§WFPZ"
$BackupEncryptionPassword = "o.!76u3LUFWUpfRKzedbN!p9orPX*aWN2*dotcvv!uJYMfwxW6k2ry2DJE_KohprtVh-kCqYVEnaN2rmbrohTAWT.qiHVqtKs.QU"
$StorageAuthMode = "password" # password | key
$StorageRemoteBase = "backups/server2022ad"
$SshKeyPath = "C:\ProgramData\ssh\storagebox_backup_ed25519"

# Optional local shares to include (customize for this server)
$ExtraPaths = @(
    "C:\Shares",
    "D:\Data"
)

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $Message"
    Write-Output $line
    Add-Content -Path $script:LogFile -Value $line
}

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Test-Command {
    param([string]$Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Invoke-Safe {
    param(
        [scriptblock]$Script,
        [string]$Label
    )
    try {
        & $Script
        Write-Log "OK: $Label"
    }
    catch {
        Write-Log "WARN: $Label failed: $($_.Exception.Message)"
    }
}

function New-VssShadow {
    param([string]$Volume = "C:\")
    $shadowClass = Get-WmiObject -List Win32_ShadowCopy
    $create = $shadowClass.Create($Volume, "ClientAccessible")
    if ($create.ReturnValue -ne 0) {
        throw "VSS snapshot create failed with code $($create.ReturnValue)"
    }

    $shadow = Get-WmiObject Win32_ShadowCopy | Where-Object { $_.ID -eq $create.ShadowID }
    if (-not $shadow) {
        throw "VSS snapshot created but could not be queried"
    }
    return $shadow
}

function Remove-VssShadow {
    param([string]$Id)
    try {
        $s = Get-WmiObject Win32_ShadowCopy | Where-Object { $_.ID -eq $Id }
        if ($s) { [void]$s.Delete() }
    }
    catch {
        Write-Log "WARN: Failed to remove VSS shadow $Id"
    }
}

function Copy-Tree {
    param(
        [string]$Source,
        [string]$Destination
    )
    Ensure-Dir -Path $Destination
    $null = robocopy $Source $Destination /E /R:2 /W:2 /NFL /NDL /NP /XJ
    $rc = $LASTEXITCODE
    if ($rc -ge 8) {
        throw "robocopy failed (code $rc) for $Source"
    }
}

$runtimeDir = Join-Path $LocalRoot "runtime"
$pidFile = Join-Path $runtimeDir "backup.pid"
$stateFile = Join-Path $runtimeDir "backup.state"
$runnerLog = Join-Path $runtimeDir "runner.log"
$runnerErrLog = Join-Path $runtimeDir "runner.err.log"

function Set-State {
    param([string]$State)
    Ensure-Dir -Path $runtimeDir
    Set-Content -Path $stateFile -Value $State -Encoding ASCII
}

function Get-RunningPid {
    if (-not (Test-Path -LiteralPath $pidFile)) { return $null }
    $pidValue = (Get-Content -Path $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if (-not $pidValue) { return $null }
    $p = Get-Process -Id ([int]$pidValue) -ErrorAction SilentlyContinue
    if ($p) { return [int]$pidValue }
    return $null
}

switch ($Action) {
    "start" {
        Ensure-Dir -Path $runtimeDir
        $existing = Get-RunningPid
        if ($existing) {
            Write-Output "Backup already running (PID: $existing)"
            exit 0
        }

        Set-State "starting"
        $self = $PSCommandPath
        $enableUploadArg = if ($EnableUploadBool) { 'true' } else { 'false' }
        $args = @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$self`"",
            "-Action", "run",
            "-LocalRoot", "`"$LocalRoot`"",
            "-LocalRetentionDays", "$LocalRetentionDays",
            "-RemoteRetentionDays", "$RemoteRetentionDays",
            "-EnableUpload", $enableUploadArg
        )

        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList ($args -join " ") -WindowStyle Hidden -RedirectStandardOutput $runnerLog -RedirectStandardError $runnerErrLog -PassThru
        Set-Content -Path $pidFile -Value $proc.Id -Encoding ASCII
        Write-Output "Started AD backup in background"
        Write-Output "PID: $($proc.Id)"
        Write-Output "Runner log: $runnerLog"
        Write-Output "Runner err log: $runnerErrLog"
        exit 0
    }
    "status" {
        Ensure-Dir -Path $runtimeDir
        $running = Get-RunningPid
        Write-Output "=== AD Backup Status ==="
        Write-Output "State: $((Get-Content -Path $stateFile -ErrorAction SilentlyContinue | Select-Object -First 1) -as [string])"
        if ($running) {
            Write-Output "Process: running (PID: $running)"
            exit 0
        }
        Write-Output "Process: not running"
        if (Test-Path -LiteralPath $runnerLog) {
            Write-Output "--- Runner log tail ---"
            Get-Content -Path $runnerLog -Tail 80 -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $runnerErrLog) {
            Write-Output "--- Runner err log tail ---"
            Get-Content -Path $runnerErrLog -Tail 80 -ErrorAction SilentlyContinue
        }
        exit 1
    }
    "stop" {
        $running = Get-RunningPid
        if ($running) {
            Stop-Process -Id $running -Force -ErrorAction SilentlyContinue
            Write-Output "Stopped backup process PID $running"
        }
        Remove-Item -Path $pidFile -Force -ErrorAction SilentlyContinue
        Set-State "stopped"
        exit 0
    }
    "run" {
        trap {
            Set-State "failed"
            Remove-Item -Path $pidFile -Force -ErrorAction SilentlyContinue
            throw
        }
        Set-State "running"
    }
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$runRoot = Join-Path $LocalRoot "run-$timestamp"
$dataRoot = Join-Path $runRoot "data"
$metaRoot = Join-Path $runRoot "meta"
$exportsRoot = Join-Path $runRoot "exports"
$archiveRoot = Join-Path $LocalRoot "archives"

Ensure-Dir -Path $runRoot
Ensure-Dir -Path $dataRoot
Ensure-Dir -Path $metaRoot
Ensure-Dir -Path $exportsRoot
Ensure-Dir -Path $archiveRoot

$script:LogFile = Join-Path $runRoot "backup.log"
Write-Log "Starting comprehensive AD backup"
Write-Log "Run root: $runRoot"

# --- System metadata for fast recovery docs ---
Invoke-Safe -Label "Capture systeminfo" -Script {
    systeminfo | Out-File -FilePath (Join-Path $metaRoot "systeminfo.txt") -Encoding UTF8
}
Invoke-Safe -Label "Capture IP config" -Script {
    ipconfig /all | Out-File -FilePath (Join-Path $metaRoot "ipconfig-all.txt") -Encoding UTF8
}
Invoke-Safe -Label "Capture route table" -Script {
    route print | Out-File -FilePath (Join-Path $metaRoot "route-print.txt") -Encoding UTF8
}
Invoke-Safe -Label "Capture disks" -Script {
    Get-Volume | Format-Table -AutoSize | Out-File -FilePath (Join-Path $metaRoot "volumes.txt") -Encoding UTF8
}
Invoke-Safe -Label "Capture services" -Script {
    Get-Service | Sort-Object Status,Name | Format-Table -AutoSize | Out-File -FilePath (Join-Path $metaRoot "services.txt") -Encoding UTF8
}
Invoke-Safe -Label "Capture installed features" -Script {
    Get-WindowsFeature | Where-Object Installed | Format-Table Name,DisplayName -AutoSize | Out-File -FilePath (Join-Path $metaRoot "installed-features.txt") -Encoding UTF8
}
Invoke-Safe -Label "Capture shares" -Script {
    Get-SmbShare | Format-Table Name,Path,Description -AutoSize | Out-File -FilePath (Join-Path $metaRoot "shares.txt") -Encoding UTF8
}

# --- AD / DNS / DHCP / GPO exports ---
Invoke-Safe -Label "Backup all GPOs" -Script {
    Import-Module GroupPolicy -ErrorAction Stop
    $gpoOut = Join-Path $exportsRoot "gpo"
    Ensure-Dir -Path $gpoOut
    Backup-GPO -All -Path $gpoOut | Out-Null
}

Invoke-Safe -Label "Export AD users/computers/groups" -Script {
    Import-Module ActiveDirectory -ErrorAction Stop
    Get-ADUser -Filter * -Properties * | Select-Object SamAccountName,Enabled,DistinguishedName,LastLogonDate,PasswordLastSet |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $exportsRoot "ad-users.csv")
    Get-ADComputer -Filter * -Properties * | Select-Object Name,Enabled,DistinguishedName,LastLogonDate,OperatingSystem |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $exportsRoot "ad-computers.csv")
    Get-ADGroup -Filter * -Properties * | Select-Object Name,GroupScope,GroupCategory,DistinguishedName |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $exportsRoot "ad-groups.csv")
}

Invoke-Safe -Label "Export DNS zones" -Script {
    if (Get-Module -ListAvailable -Name DnsServer) {
        Import-Module DnsServer -ErrorAction Stop
        $dnsOut = Join-Path $exportsRoot "dns"
        Ensure-Dir -Path $dnsOut
        Get-DnsServerZone | ForEach-Object {
            $zone = $_.ZoneName
            try {
                Export-DnsServerZone -Name $zone -FileName "$zone.dns" -ErrorAction Stop
                Move-Item -Path (Join-Path $env:SystemRoot "System32\dns\$zone.dns") -Destination (Join-Path $dnsOut "$zone.dns") -Force
            }
            catch {
                Write-Log "WARN: DNS zone export failed for $zone"
            }
        }
    }
}

Invoke-Safe -Label "Export DHCP" -Script {
    if (Get-Module -ListAvailable -Name DhcpServer) {
        Import-Module DhcpServer -ErrorAction Stop
        $dhcpOut = Join-Path $exportsRoot "dhcp"
        Ensure-Dir -Path $dhcpOut
        Export-DhcpServer -ComputerName localhost -File (Join-Path $dhcpOut "dhcp-export.xml") -Leases -Force
    }
}

# --- VSS copy for locked AD files + SYSVOL ---
$shadow = $null
try {
    $shadow = New-VssShadow -Volume "C:\"
    $shadowRoot = $shadow.DeviceObject + "\"
    Write-Log "Created VSS shadow: $($shadow.ID) at $shadowRoot"

    Invoke-Safe -Label "Copy NTDS from shadow" -Script {
        $src = Join-Path $shadowRoot "Windows\NTDS"
        if (Test-Path -LiteralPath $src) {
            Copy-Tree -Source $src -Destination (Join-Path $dataRoot "NTDS")
        }
    }

    Invoke-Safe -Label "Copy SYSVOL from shadow" -Script {
        $src = Join-Path $shadowRoot "Windows\SYSVOL"
        if (Test-Path -LiteralPath $src) {
            Copy-Tree -Source $src -Destination (Join-Path $dataRoot "SYSVOL")
        }
    }
}
catch {
    Write-Log "WARN: VSS snapshot workflow failed: $($_.Exception.Message)"
}
finally {
    if ($shadow) {
        Remove-VssShadow -Id $shadow.ID
        Write-Log "Removed VSS shadow: $($shadow.ID)"
    }
}

# --- Extra shared paths ---
foreach ($path in $ExtraPaths) {
    if (Test-Path -LiteralPath $path) {
        $name = ($path -replace '[:\\ ]', '_').Trim('_')
        Invoke-Safe -Label "Copy $path" -Script {
            Copy-Tree -Source $path -Destination (Join-Path $dataRoot "extra-$name")
        }
    }
}

# --- System State Backup (best effort) ---
Invoke-Safe -Label "Run System State backup" -Script {
    $ssDir = Join-Path $runRoot "systemstate"
    Ensure-Dir -Path $ssDir
    wbadmin start systemstatebackup -backuptarget:$ssDir -quiet | Out-File -FilePath (Join-Path $metaRoot "wbadmin-systemstate.txt") -Encoding UTF8
}

# --- Package output ---
$zipPath = Join-Path $archiveRoot "Server2022AD-$timestamp.zip"
Write-Log "Creating archive: $zipPath"
Compress-Archive -Path (Join-Path $runRoot "*") -DestinationPath $zipPath -CompressionLevel Optimal -Force

# --- Upload to Storage Box over SFTP using key ---
if ($EnableUploadBool) {
    Write-Log "Uploading archive to Storage Box"
    $uploadLog = Join-Path $metaRoot "upload-output.txt"
    $remoteFile = [IO.Path]::GetFileName($zipPath)
    $remoteUrl = "sftp://$StorageHost`:$StoragePort/$StorageRemoteBase/$remoteFile"

    if ($StorageAuthMode -eq "password") {
        if (-not (Test-Command -Name "curl.exe")) {
            throw "curl.exe not found; required for password-based SFTP upload"
        }

        & curl.exe --silent --show-error --fail --insecure --ftp-create-dirs `
            --user "$StorageUser`:$StoragePassword" `
            --upload-file "$zipPath" "$remoteUrl" *>&1 |
            Out-File -FilePath $uploadLog -Encoding UTF8

        if ($LASTEXITCODE -ne 0) {
            throw "Password-based SFTP upload failed with exit code $LASTEXITCODE"
        }
    }
    else {
        if (-not (Test-Path -LiteralPath $SshKeyPath)) {
            throw "SSH key not found at $SshKeyPath"
        }

        $sftpBatch = Join-Path $runRoot "sftp-batch.txt"
        @(
            "mkdir $StorageRemoteBase"
            "put $zipPath $StorageRemoteBase/"
            "bye"
        ) | Set-Content -Path $sftpBatch -Encoding ASCII

        & sftp.exe -b $sftpBatch -P $StoragePort -i $SshKeyPath -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$StorageUser@$StorageHost" *>&1 |
            Out-File -FilePath $uploadLog -Encoding UTF8
        if ($LASTEXITCODE -ne 0) {
            throw "Key-based SFTP upload failed with exit code $LASTEXITCODE"
        }
    }

    Write-Log "Upload completed"
}

# --- Local retention ---
Write-Log "Applying local retention"
Get-ChildItem -Path $archiveRoot -Filter "Server2022AD-*.zip" -File |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LocalRetentionDays) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

Get-ChildItem -Path $LocalRoot -Directory -Filter "run-*" |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LocalRetentionDays) } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

Write-Log "Backup workflow complete"
Write-Output "SUCCESS: Comprehensive AD backup completed. Archive: $zipPath"

Set-State "completed"
Remove-Item -Path $pidFile -Force -ErrorAction SilentlyContinue
