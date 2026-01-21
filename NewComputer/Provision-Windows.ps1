#requires -RunAsAdministrator
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error 'This script must be run in an elevated PowerShell session.'
    exit 1
}

function Ensure-Tls12 {
    $currentProtocols = [System.Net.ServicePointManager]::SecurityProtocol
    if (($currentProtocols -band [System.Net.SecurityProtocolType]::Tls12) -ne [System.Net.SecurityProtocolType]::Tls12) {
        [System.Net.ServicePointManager]::SecurityProtocol = $currentProtocols -bor [System.Net.SecurityProtocolType]::Tls12
    }
}

function Install-Chocolatey {
    if (Get-Command choco.exe -ErrorAction SilentlyContinue) {
        Write-Host 'Chocolatey already installed.' -ForegroundColor Green
        return
    }

    Write-Host 'Installing Chocolatey...' -ForegroundColor Cyan
    Ensure-Tls12
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
    $installScript = 'https://community.chocolatey.org/install.ps1'
    $scriptContent = (New-Object System.Net.WebClient).DownloadString($installScript)
    Invoke-Expression $scriptContent

    $chocoPath = 'C:\\ProgramData\\chocolatey\\bin'
    if (-not $env:Path.Split(';') -contains $chocoPath) {
        $env:Path = ($env:Path + ';' + $chocoPath).Trim(';')
    }
}

function Install-ChocoPackages {
    $packages = @(
        'googlechrome',
        '7zip.install',
        'vlc',
        'foxitreader',
        'adobereader',
        'office365business'
    )

    choco upgrade chocolatey -y --no-progress | Out-Null
    foreach ($package in $packages) {
        Write-Host "Installing $package via Chocolatey..." -ForegroundColor Cyan
        choco install $package -y --no-progress
    }
}

function Run-DebloatManual {
    try {
        Write-Host 'Launching Windows debloat script in manual mode...' -ForegroundColor Cyan
        Ensure-Tls12
        $debloatScript = [scriptblock]::Create((Invoke-RestMethod -Uri 'https://debloat.raphi.re/' -UseBasicParsing))
        & $debloatScript -mode manual
    }
    catch {
        Write-Warning "Debloat script failed: $($_.Exception.Message)"
    }
}

function Prompt-NonEmptyValue {
    param(
        [Parameter(Mandatory)]
        [string] $Prompt
    )

    do {
        $value = Read-Host -Prompt $Prompt
        $value = $value.Trim()
    } while ([string]::IsNullOrEmpty($value))

    return $value
}

function Ensure-LocalUser {
    param(
        [Parameter(Mandatory)]
        [string] $UserName
    )

    $existingUser = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
    if ($existingUser) {
        Write-Warning "Local user '$UserName' already exists. Skipping creation."
        return
    }

    Write-Host "Creating local user '$UserName' with default password..." -ForegroundColor Cyan
    $password = ConvertTo-SecureString '1234' -AsPlainText -Force
    $null = New-LocalUser -Name $UserName -Password $password -UserMayNotChangePassword:$true -PasswordNeverExpires:$true
    try {
        Add-LocalGroupMember -Group 'Administrators' -Member $UserName -ErrorAction Stop
        Write-Host "Added '$UserName' to Administrators group." -ForegroundColor Green
    }
    catch {
        Write-Warning "Failed to add '$UserName' to Administrators: $($_.Exception.Message)"
    }
}

function Rename-ComputerIfNeeded {
    param(
        [Parameter(Mandatory)]
        [string] $NewName
    )

    $currentName = (Get-CimInstance -ClassName Win32_ComputerSystem).Name
    if ($currentName -ieq $NewName) {
        Write-Host "Computer name already '$NewName'." -ForegroundColor Green
        return $false
    }

    Write-Host "Renaming computer from '$currentName' to '$NewName'..." -ForegroundColor Cyan
    Rename-Computer -NewName $NewName -Force -PassThru | Out-Null
    return $true
}

function Install-WindowsUpdates {
    Write-Host 'Checking for Windows updates...' -ForegroundColor Cyan
    $moduleName = 'PSWindowsUpdate'
    if (-not (Get-Module -ListAvailable -Name $moduleName)) {
        Ensure-Tls12
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
        Install-Module -Name $moduleName -Force -Confirm:$false -Scope AllUsers
    }

    Import-Module $moduleName
    Get-WUServiceManager | Out-Null

    Write-Host 'Installing available updates (this may take a while)...' -ForegroundColor Cyan
    Get-WindowsUpdate -AcceptAll -Install -IgnoreReboot
}

Install-Chocolatey
Install-ChocoPackages
Run-DebloatManual

$desiredComputerName = Prompt-NonEmptyValue -Prompt 'Enter the new computer name'
$desiredUserName = Prompt-NonEmptyValue -Prompt 'Enter the local user name to create'

Ensure-LocalUser -UserName $desiredUserName
$renameRequired = Rename-ComputerIfNeeded -NewName $desiredComputerName

Install-WindowsUpdates

if ($renameRequired) {
    Write-Host 'System restart required to complete computer rename.' -ForegroundColor Yellow
}
Write-Host 'All tasks completed. Restart recommended if pending.' -ForegroundColor Green
