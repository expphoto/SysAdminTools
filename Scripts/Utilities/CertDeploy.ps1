#Requires -Version 5.1
#Requires -Modules WebAdministration

<#
.SYNOPSIS
CertDeploy - SSL Certificate Renewal and IIS Deployment Automation Tool

.DESCRIPTION
Automates SSL certificate renewal packaging and IIS deployment across domain-joined Windows servers.
Supports GoDaddy certificates, audit/report-only mode, test mode, and deploy mode with rollback.

.PARAMETER ConfigPath
Path to the JSON configuration file. Default: .\CertDeploy-config.json

.PARAMETER Command
Command to execute: audit, package, deploy, verify, report

.PARAMETER FriendlyName
Friendly name of the certificate to process (optional for audit)

.PARAMETER Server
Target server name (optional for single-server operations)

.PARAMETER TestMode
Run in test mode - imports cert but does NOT change bindings (except on TestModeServers)

.PARAMETER WhatIf
Show what would happen without making changes

.PARAMETER LogPath
Override default logging path from config

.PARAMETER PFXPassword
PFX export/import password (will prompt if not provided)

.PARAMETER StagingPath
Override default staging path

.PARAMETER ExportJson
Export results to JSON file

.EXAMPLE
.\CertDeploy.ps1 -Command audit
Audit all certificates and report expirations

.EXAMPLE
.\CertDeploy.ps1 -Command package -FriendlyName webapp-frontend
Package the webapp-frontend certificate to the share

.EXAMPLE
.\CertDeploy.ps1 -Command deploy -FriendlyName webapp-frontend -TestMode
Deploy certificate in test mode (no binding changes on prod servers)

.EXAMPLE
.\CertDeploy.ps1 -Command deploy -FriendlyName webapp-frontend -WhatIf
Preview deployment changes

.EXAMPLE
.\CertDeploy.ps1 -Command verify -FriendlyName webapp-frontend
Verify certificate deployment across all targets

.EXAMPLE
.\CertDeploy.ps1 -Command report -ExportJson .\report.json
Generate deployment report and export to JSON

.NOTES
Requires: Windows PowerShell 5.1+, WebAdministration module, WinRM enabled on targets
Author: CertDeploy Team
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateScript({ Test-Path $_ })]
    [string]$ConfigPath = ".\CertDeploy-config.json",

    [Parameter(Mandatory = $true)]
    [ValidateSet("audit", "package", "deploy", "verify", "report")]
    [string]$Command,

    [Parameter(Mandatory = $false)]
    [string]$FriendlyName,

    [Parameter(Mandatory = $false)]
    [string]$Server,

    [Parameter(Mandatory = $false)]
    [switch]$TestMode,

    [Parameter(Mandatory = $false)]
    [switch]$ExportJson,

    [Parameter(Mandatory = $false)]
    [string]$PFXPassword,

    [Parameter(Mandatory = $false)]
    [string]$StagingPath,

    [Parameter(Mandatory = $false)]
    [string]$LogPath,

    [Parameter(Mandatory = $false)]
    [switch]$SkipHealthCheck
)

#region Helper Functions

function Write-CertDeployLog {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARNING", "ERROR", "DEBUG", "AUDIT")]
        [string]$Level = "INFO",
        [bool]$ToConsole = $true
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = @{
        Timestamp = $timestamp
        Level = $Level
        Message = $Message
    }

    if ($ToConsole) {
        $color = switch ($Level) {
            "INFO" { "White" }
            "WARNING" { "Yellow" }
            "ERROR" { "Red" }
            "DEBUG" { "Gray" }
            "AUDIT" { "Cyan" }
            default { "White" }
        }
        Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
    }

    if ($script:LogFile) {
        $logDir = Split-Path -Parent $script:LogFile
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $logEntry | ConvertTo-Json -Compress | Add-Content -Path $script:LogFile
    }
}

function Get-CertDeployConfig {
    param([string]$Path)

    Write-CertDeployLog "Loading configuration from: $Path" -Level DEBUG

    if (-not (Test-Path $Path)) {
        throw "Configuration file not found: $Path"
    }

    $config = Get-Content -Path $Path -Raw | ConvertFrom-Json

    if ($LogPath) {
        $config.GlobalSettings.LoggingPath = $LogPath
    }

    if ($StagingPath) {
        $config.GlobalSettings.StagingPath = $StagingPath
    }

    $script:LogDir = $config.GlobalSettings.LoggingPath
    $logFileName = "CertDeploy_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    $script:LogFile = Join-Path -Path $script:LogDir -ChildPath $logFileName

    return $config
}

function Test-CertDeployPrerequisites {
    param([object]$Config)

    Write-CertDeployLog "Testing prerequisites..." -Level INFO

    $issues = @()

    if (-not (Get-Module -ListAvailable -Name WebAdministration)) {
        $issues += "WebAdministration module not available"
    }

    if (-not (Test-Path $Config.GlobalSettings.CertShareUNC)) {
        $issues += "Certificate share not accessible: $($Config.GlobalSettings.CertShareUNC)"
    }

    try {
        Test-WSMan -ComputerName $Config.GlobalSettings.CAServer -ErrorAction Stop | Out-Null
    } catch {
        $issues += "Cannot connect to CA server via WinRM: $($Config.GlobalSettings.CAServer)"
    }

    if ($issues.Count -gt 0) {
        $issues | ForEach-Object { Write-CertDeployLog $_ -Level ERROR }
        throw "Prerequisites check failed"
    }

    Write-CertDeployLog "Prerequisites check passed" -Level INFO
}

function Invoke-CertDeploySelfTest {
    Write-CertDeployLog "Running CertDeploy self-test..." -Level INFO

    $results = @{
        Success = $true
        Checks = @()
    }

    if (Get-Module -ListAvailable -Name WebAdministration) {
        $results.Checks += @{ Name = "WebAdministration Module"; Status = "Pass" }
    } else {
        $results.Checks += @{ Name = "WebAdministration Module"; Status = "Fail" }
        $results.Success = $false
    }

    try {
        Test-WSMan -ErrorAction Stop | Out-Null
        $results.Checks += @{ Name = "WinRM Local"; Status = "Pass" }
    } catch {
        $results.Checks += @{ Name = "WinRM Local"; Status = "Fail" }
        $results.Success = $false
    }

    try {
        Get-Command -Module PKI -ErrorAction Stop | Out-Null
        $results.Checks += @{ Name = "PKI Module"; Status = "Pass" }
    } catch {
        $results.Checks += @{ Name = "PKI Module"; Status = "Fail" }
        $results.Success = $false
    }

    $results.Checks | ForEach-Object {
        $statusColor = if ($_.Status -eq "Pass") { "Green" } else { "Red" }
        Write-CertDeployLog "  [$($_.Status)] $($_.Name)" -Level INFO
    }

    return $results
}

function Get-PFXPassword {
    param(
        [string]$Password,
        [string]$Mode
    )

    if ($Password) {
        return $Password
    }

    if ($Mode -eq "DPAPI") {
        $secure = Read-Host -Prompt "Enter PFX password (DPAPI encrypted)" -AsSecureString
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    } else {
        return (Read-Host -Prompt "Enter PFX password" -AsSecureString)
    }
}

function Test-GodaddyApi {
    param([object]$Config)

    return $Config.GoDaddy.Enabled -and
           $Config.GoDaddy.ApiKey -and
           $Config.GoDaddy.ApiSecret
}

function Invoke-GodaddyDownload {
    param(
        [object]$Config,
        [string]$CertificateId,
        [string]$OutputPath
    )

    Write-CertDeployLog "Downloading certificate from GoDaddy..." -Level INFO

    $baseUrl = if ($Config.GoDaddy.UseV2Api) {
        "https://api.godaddy.com/v2"
    } else {
        "https://api.godaddy.com/v1"
    }

    $headers = @{
        "Authorization" = "sso-key $($Config.GoDaddy.ApiKey):$($Config.GoDaddy.ApiSecret)"
        "Accept" = "application/json"
    }

    try {
        if ($CertificateId) {
            $url = "$baseUrl/certificates/$CertificateId/download"
            $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get

            if ($response.certificate) {
                $response.certificate | Set-Content -Path "$OutputPath.crt" -Encoding UTF8
            }
            if ($response.chain) {
                $response.chain | Set-Content -Path "$OutputPath-chain.crt" -Encoding UTF8
            }

            Write-CertDeployLog "Certificate downloaded from GoDaddy" -Level INFO
            return $true
        }
    } catch {
        Write-CertDeployLog "GoDaddy download failed: $_" -Level ERROR
    }

    return $false
}

#endregion

#region Certificate Operations

function Get-CACertificates {
    param(
        [string]$CAServer,
        [string]$FriendlyName
    )

    Write-CertDeployLog "Querying certificates on CA server: $CAServer" -Level DEBUG

    $query = if ($FriendlyName) {
        "SELECT * FROM System.Security.Cryptography.X509Certificates.X509Certificate2Store WHERE StoreName='MY' AND FriendlyName='$FriendlyName'"
    } else {
        "SELECT * FROM System.Security.Cryptography.X509Certificates.X509Certificate2Store WHERE StoreName='MY'"
    }

    try {
        $certs = Invoke-Command -ComputerName $CAServer -ScriptBlock {
            Get-ChildItem -Path "Cert:\LocalMachine\My" |
            Where-Object { $using:FriendlyName -eq $null -or $_.FriendlyName -eq $using:FriendlyName } |
            ForEach-Object {
                @{
                    Thumbprint = $_.Thumbprint
                    Subject = $_.Subject
                    FriendlyName = $_.FriendlyName
                    NotBefore = $_.NotBefore
                    NotAfter = $_.NotAfter
                    HasPrivateKey = $_.HasPrivateKey
                    Issuer = $_.Issuer
                    SANs = ($_.Extensions | Where-Object { $_.Oid.Value -eq "2.5.29.17" }).Format(0) -split ", "
                    DnsNameList = $_.DNSNameList.Unicode
                }
            }
        }

        return $certs
    } catch {
        Write-CertDeployLog "Failed to query CA certificates: $_" -Level ERROR
        throw
    }
}

function Export-CertificatePFX {
    param(
        [string]$CAServer,
        [string]$Thumbprint,
        [string]$OutputPath,
        [securestring]$Password
    )

    Write-CertDeployLog "Exporting PFX from CA server..." -Level INFO

    $tempPath = Invoke-Command -ComputerName $CAServer -ScriptBlock {
        $cert = Get-ChildItem -Path "Cert:\LocalMachine\My" -Thumbprint $using:Thumbprint
        $tempFile = "$env:TEMP\$($using:Thumbprint).pfx"
        $certBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $using:Password)
        [System.IO.File]::WriteAllBytes($tempFile, $certBytes)
        return $tempFile
    }

    try {
        Copy-Item -Path "\\$CAServer\$($tempPath.Replace(':', '$'))" -Destination $OutputPath -Force
        Invoke-Command -ComputerName $CAServer -ScriptBlock { Remove-Item -Path $using:tempPath -Force }
        Write-CertDeployLog "PFX exported to: $OutputPath" -Level INFO
        return $true
    } catch {
        Write-CertDeployLog "Failed to copy PFX: $_" -Level ERROR
        return $false
    }
}

function Test-CertificateValid {
    param(
        [object]$Cert,
        [string[]]$ExpectedDomains
    )

    $issues = @()

    if ($Cert.NotAfter -lt (Get-Date)) {
        $issues += "Certificate has expired: $($Cert.NotAfter)"
    }

    if (-not $Cert.HasPrivateKey) {
        $issues += "Certificate does not have private key"
    }

    if ($ExpectedDomains) {
        $certDomains = @($Cert.SANs) + $Cert.DnsNameList
        foreach ($domain in $ExpectedDomains) {
            if ($domain -notin $certDomains) {
                $issues += "Expected domain not found in certificate: $domain"
            }
        }
    }

    return @{
        Valid = $issues.Count -eq 0
        Issues = $issues
    }
}

function Copy-CertificateToShare {
    param(
        [string]$SourcePath,
        [string]$FriendlyName,
        [string]$ShareRoot,
        [bool]$WhatIf
    )

    $certPath = Join-Path -Path $ShareRoot -ChildPath $FriendlyName
    $currentPFX = Join-Path -Path $certPath -ChildPath "current.pfx"
    $archivePath = Join-Path -Path $certPath -ChildPath "archive"

    if (-not (Test-Path $certPath)) {
        if ($WhatIf) {
            Write-CertDeployLog "Would create directory: $certPath" -Level INFO
        } else {
            New-Item -ItemType Directory -Path $certPath -Force | Out-Null
            Write-CertDeployLog "Created directory: $certPath" -Level INFO
        }
    }

    if (Test-Path $currentPFX) {
        if (-not (Test-Path $archivePath)) {
            if ($WhatIf) {
                Write-CertDeployLog "Would create archive directory: $archivePath" -Level INFO
            } else {
                New-Item -ItemType Directory -Path $archivePath -Force | Out-Null
            }
        }

        $archivePFX = Join-Path -Path $archivePath -ChildPath "previous.pfx"
        if ($WhatIf) {
            Write-CertDeployLog "Would archive previous PFX to: $archivePFX" -Level INFO
        } else {
            Move-Item -Path $currentPFX -Destination $archivePFX -Force
            Write-CertDeployLog "Archived previous PFX to: $archivePFX" -Level INFO
        }
    }

    if ($WhatIf) {
        Write-CertDeployLog "Would copy PFX to: $currentPFX" -Level INFO
        return $true
    }

    Copy-Item -Path $SourcePath -Destination $currentPFX -Force
    Write-CertDeployLog "Copied PFX to share: $currentPFX" -Level INFO

    return $true
}

function Import-CertificateRemotely {
    param(
        [string]$Server,
        [string]$PFXPath,
        [securestring]$Password,
        [bool]$WhatIf
    )

    Write-CertDeployLog "Importing certificate on $Server..." -Level INFO

    $pfxContent = [System.IO.File]::ReadAllBytes($PFXPath)
    $certBase64 = [System.Convert]::ToBase64String($pfxContent)
    $passwordPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    )

    try {
        $result = Invoke-Command -ComputerName $Server -ScriptBlock {
            $pfxBytes = [System.Convert]::FromBase64String($using:certBase64)
            $cert = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Certificate2Collection
            $cert.Import($pfxBytes, $using:passwordPlain, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet -bor [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet)

            $store = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Store -ArgumentList "My", "LocalMachine"
            $store.Open("ReadWrite")
            $store.Add($cert)
            $store.Close()

            $certThumbprint = $cert | Select-Object -First 1 -ExpandProperty Thumbprint

            Write-Output @{
                Success = $true
                Thumbprint = $certThumbprint
            }
        }

        if ($result.Success) {
            Write-CertDeployLog "Certificate imported on $Server. Thumbprint: $($result.Thumbprint)" -Level INFO
            return $result
        }
    } catch {
        Write-CertDeployLog "Failed to import certificate on $Server: $_" -Level ERROR
    }

    return $null
}

function Get-RemoteIISBindings {
    param(
        [string]$Server,
        [string]$SiteName,
        [string]$HostHeader,
        [int]$Port,
        [string]$IPAddress = "*"
    )

    Write-CertDeployLog "Querying IIS bindings on $Server..." -Level DEBUG

    try {
        $bindings = Invoke-Command -ComputerName $Server -ScriptBlock {
            Import-Module WebAdministration
            Get-WebBinding -Name $using:SiteName |
            Where-Object {
                $_.Port -eq $using:Port -and
                $_.Protocol -eq "https"
            } |
            ForEach-Object {
                $bindingInfo = $_.bindingInformation -split ":"
                $bindingIP = $bindingInfo[0]
                $bindingPort = $bindingInfo[1]
                $bindingHost = $bindingInfo[2]

                $certHash = $_.certificateHash
                $cert = if ($certHash) {
                    Get-ChildItem -Path "Cert:\LocalMachine\My" -Thumbprint $certHash -ErrorAction SilentlyContinue
                }

                @{
                    Protocol = $_.Protocol
                    Port = $_.Port
                    IPAddress = $bindingIP
                    HostHeader = $bindingHost
                    SNI = $_.SniEnabled
                    Thumbprint = $certHash
                    CertificateSubject = if ($cert) { $cert.Subject } else { $null }
                    CertificateNotAfter = if ($cert) { $cert.NotAfter } else { $null }
                }
            }

            if ($using:IPAddress -and $using:HostHeader) {
                $bindings | Where-Object {
                    $_.IPAddress -eq $using:IPAddress -and
                    $_.HostHeader -eq $using:HostHeader
                }
            } elseif ($using:HostHeader) {
                $bindings | Where-Object { $_.HostHeader -eq $using:HostHeader }
            } else {
                $bindings
            }
        }

        return $bindings
    } catch {
        Write-CertDeployLog "Failed to query IIS bindings on $Server: $_" -Level ERROR
        return @()
    }
}

function Set-RemoteIISBinding {
    param(
        [string]$Server,
        [string]$SiteName,
        [string]$HostHeader,
        [int]$Port,
        [string]$IPAddress = "*",
        [string]$NewThumbprint,
        [bool]$SNI,
        [bool]$WhatIf
    )

    Write-CertDeployLog "Updating IIS binding on $Server..." -Level INFO

    if ($WhatIf) {
        Write-CertDeployLog "Would update binding: Site=$SiteName, Host=$HostHeader, Port=$Port, NewThumbprint=$NewThumbprint" -Level INFO
        return $true
    }

    try {
        Invoke-Command -ComputerName $Server -ScriptBlock {
            Import-Module WebAdministration

            $binding = Get-WebBinding -Name $using:SiteName -Protocol https |
                       Where-Object {
                           $bindingInfo = $_.bindingInformation -split ":"
                           $bindingInfo[0] -eq $using:IPAddress -and
                           $bindingInfo[1] -eq $using:Port.ToString() -and
                           $bindingInfo[2] -eq $using:HostHeader
                       } |
                       Select-Object -First 1

            if (-not $binding) {
                throw "Binding not found"
            }

            $binding.AddSslCertificate($using:NewThumbprint, "My")
        }

        Write-CertDeployLog "Binding updated on $Server" -Level INFO
        return $true
    } catch {
        Write-CertDeployLog "Failed to update binding on $Server: $_" -Level ERROR
        return $false
    }
}

function Test-HealthCheck {
    param(
        [string]$URL,
        [bool]$Skip
    )

    if ($Skip) {
        Write-CertDeployLog "Skipping health check" -Level INFO
        return @{ Success = $true; Response = "Skipped" }
    }

    Write-CertDeployLog "Running health check: $URL" -Level INFO

    try {
        $response = Invoke-WebRequest -Uri $URL -Method Get -TimeoutSec 30 -UseBasicParsing
        $statusCode = $response.StatusCode

        if ($statusCode -ge 200 -and $statusCode -lt 400) {
            Write-CertDeployLog "Health check passed: HTTP $statusCode" -Level INFO
            return @{ Success = $true; Response = "HTTP $statusCode" }
        } else {
            Write-CertDeployLog "Health check failed: HTTP $statusCode" -Level WARNING
            return @{ Success = $false; Response = "HTTP $statusCode" }
        }
    } catch {
        Write-CertDeployLog "Health check error: $_" -Level ERROR
        return @{ Success = $false; Response = $_.Exception.Message }
    }
}

#endregion

#region Command Implementations

function Invoke-AuditCommand {
    param([object]$Config)

    Write-CertDeployLog "Starting audit..." -Level AUDIT

    $results = @{
        Summary = @{
            TotalCerts = 0
            Expiring30Days = 0
            Expiring60Days = 0
            Expiring90Days = 0
            MismatchedBindings = 0
        }
        Certificates = @()
    }

    foreach ($certConfig in $Config.Certificates) {
        $certResult = @{
            FriendlyName = $certConfig.FriendlyName
            ExpectedDomains = $certConfig.ExpectedDomains
            Targets = @()
        }

        foreach ($target in $certConfig.Targets) {
            $targetResult = @{
                Server = $target.Server
                Sites = @()
            }

            if ($Server -and $target.Server -ne $Server) {
                continue
            }

            foreach ($site in $target.Sites) {
                $bindings = Get-RemoteIISBindings -Server $target.Server -SiteName $site.Name -HostHeader $site.HostHeader -Port $site.Port -IPAddress $site.IPAddress

                $siteResult = @{
                    Name = $site.Name
                    HostHeader = $site.HostHeader
                    Port = $site.Port
                    Bindings = $bindings
                    Expiring = @()
                    Mismatched = $false
                }

                foreach ($binding in $bindings) {
                    if ($binding.CertificateNotAfter) {
                        $daysUntilExpiry = ($binding.CertificateNotAfter - (Get-Date)).Days

                        if ($daysUntilExpiry -le 90) {
                            $siteResult.Expiring += @{
                                DaysRemaining = $daysUntilExpiry
                                Thumbprint = $binding.Thumbprint
                                NotAfter = $binding.CertificateNotAfter
                            }

                            switch ($daysUntilExpiry) {
                                { $_ -le 30 } { $results.Summary.Expiring30Days++ }
                                { $_ -le 60 } { $results.Summary.Expiring60Days++ }
                                { $_ -le 90 } { $results.Summary.Expiring90Days++ }
                            }
                        }

                        $certDomains = @($binding.CertificateSubject) + $certConfig.ExpectedDomains
                        $mismatch = $false
                        foreach ($expected in $certConfig.ExpectedDomains) {
                            if ($binding.CertificateSubject -notmatch [regex]::Escape($expected)) {
                                $mismatch = $true
                            }
                        }

                        if ($mismatch) {
                            $siteResult.Mismatched = $true
                            $results.Summary.MismatchedBindings++
                        }
                    }
                }

                $targetResult.Sites += $siteResult
            }

            $certResult.Targets += $targetResult
        }

        $results.Certificates += $certResult
        $results.Summary.TotalCerts++
    }

    return $results
}

function Invoke-PackageCommand {
    param(
        [object]$Config,
        [string]$FriendlyName,
        [bool]$WhatIf
    )

    Write-CertDeployLog "Starting package operation..." -Level AUDIT

    $certConfig = $Config.Certificates | Where-Object { $_.FriendlyName -eq $FriendlyName }

    if (-not $certConfig) {
        throw "Certificate configuration not found: $FriendlyName"
    }

    if (-not $WhatIf) {
        $pfxPassword = Get-PFXPassword -Password $PFXPassword -Mode $Config.GlobalSettings.DefaultPFXPasswordMode
    }

    $stagingDir = Join-Path -Path $Config.GlobalSettings.StagingPath -ChildPath $FriendlyName

    if (Test-GodaddyApi -Config $Config) {
        Write-CertDeployLog "Attempting GoDaddy API download..." -Level INFO

        if ($certConfig.GoDaddy.CertificateId -or $certConfig.GoDaddy.EntitlementId) {
            $certId = $certConfig.GoDaddy.CertificateId ?? $certConfig.GoDaddy.EntitlementId
            $downloaded = Invoke-GodaddyDownload -Config $Config -CertificateId $certId -OutputPath $stagingDir

            if (-not $downloaded) {
                Write-CertDeployLog "GoDaddy download failed, checking staging folder..." -Level WARNING
            } else {
                Write-CertDeployLog "Certificate downloaded from GoDaddy" -Level INFO
            }
        }
    }

    if (Test-Path $stagingDir) {
        Write-CertDeployLog "Using staging folder: $stagingDir" -Level INFO
    } else {
        Write-CertDeployLog "Querying CA server for certificate..." -Level INFO

        $certs = Get-CACertificates -CAServer $Config.GlobalSettings.CAServer -FriendlyName $FriendlyName

        if (-not $certs -or $certs.Count -eq 0) {
            throw "Certificate not found on CA server: $FriendlyName"
        }

        $cert = $certs | Sort-Object NotAfter -Descending | Select-Object -First 1

        Write-CertDeployLog "Found certificate: $($cert.Subject) - Expires: $($cert.NotAfter)" -Level INFO

        $validation = Test-CertificateValid -Cert $cert -ExpectedDomains $certConfig.ExpectedDomains

        if (-not $validation.Valid) {
            $validation.Issues | ForEach-Object { Write-CertDeployLog $_ -Level ERROR }
            throw "Certificate validation failed"
        }

        Write-CertDeployLog "Certificate validation passed" -Level INFO
    }

    if ($WhatIf) {
        Write-CertDeployLog "WhatIf: Would export and package certificate" -Level INFO
        return @{ Success = $true; WhatIf = $true }
    }

    $tempPFX = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.pfx'

    $exported = Export-CertificatePFX -CAServer $Config.GlobalSettings.CAServer -Thumbprint $cert.Thumbprint -OutputPath $tempPFX -Password $pfxPassword

    if (-not $exported) {
        throw "Failed to export PFX"
    }

    $copied = Copy-CertificateToShare -SourcePath $tempPFX -FriendlyName $FriendlyName -ShareRoot $Config.GlobalSettings.CertShareUNC -WhatIf $false

    Remove-Item -Path $tempPFX -Force -ErrorAction SilentlyContinue

    if (-not $copied) {
        throw "Failed to copy PFX to share"
    }

    return @{
        Success = $true
        FriendlyName = $FriendlyName
        Thumbprint = $cert.Thumbprint
        SharePath = Join-Path -Path $Config.GlobalSettings.CertShareUNC -ChildPath "$FriendlyName\current.pfx"
        ExpiryDate = $cert.NotAfter
    }
}

function Invoke-DeployCommand {
    param(
        [object]$Config,
        [string]$FriendlyName,
        [bool]$TestMode,
        [bool]$WhatIf
    )

    Write-CertDeployLog "Starting deploy operation..." -Level AUDIT

    $certConfig = $Config.Certificates | Where-Object { $_.FriendlyName -eq $FriendlyName }

    if (-not $certConfig) {
        throw "Certificate configuration not found: $FriendlyName"
    }

    $pfxPassword = Get-PFXPassword -Password $PFXPassword -Mode $Config.GlobalSettings.DefaultPFXPasswordMode

    $pfxPath = Join-Path -Path $Config.GlobalSettings.CertShareUNC -ChildPath "$FriendlyName\current.pfx"

    if (-not (Test-Path $pfxPath)) {
        throw "PFX file not found on share: $pfxPath"
    }

    Write-CertDeployLog "Loading PFX from share..." -Level INFO

    $pfx = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Certificate2
    $pfx.Import($pfxPath, $pfxPassword, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet)

    $newThumbprint = $pfx.Thumbprint
    Write-CertDeployLog "Certificate thumbprint: $newThumbprint" -Level INFO

    $results = @{
        FriendlyName = $FriendlyName
        NewThumbprint = $newThumbprint
        NewExpiryDate = $pfx.NotAfter
        Targets = @()
        Rollback = @()
    }

    foreach ($target in $certConfig.Targets) {
        if ($Server -and $target.Server -ne $Server) {
            continue
        }

        $targetResult = @{
            Server = $target.Server
            Status = "Pending"
            Sites = @()
            Errors = @()
        }

        Write-CertDeployLog "Processing server: $($target.Server)" -Level INFO

        $isTestServer = $target.Server -in $Config.GlobalSettings.TestModeServers

        if ($TestMode -and -not $isTestServer) {
            Write-CertDeployLog "Test mode: skipping binding changes on $($target.Server)" -Level INFO
            $targetResult.Status = "TestModeSkipped"
        }

        $imported = Import-CertificateRemotely -Server $target.Server -PFXPath $pfxPath -Password $pfxPassword -WhatIf $WhatIf

        if (-not $imported) {
            $targetResult.Status = "ImportFailed"
            $targetResult.Errors += "Certificate import failed"
            $results.Targets += $targetResult
            continue
        }

        $targetResult.ImportedThumbprint = $imported.Thumbprint

        foreach ($site in $target.Sites) {
            $siteResult = @{
                Name = $site.Name
                HostHeader = $site.HostHeader
                Port = $site.Port
                Status = "Pending"
                OldThumbprint = $null
                NewThumbprint = $newThumbprint
                HealthCheckResult = $null
                RolledBack = $false
            }

            $bindings = Get-RemoteIISBindings -Server $target.Server -SiteName $site.Name -HostHeader $site.HostHeader -Port $site.Port -IPAddress $site.IPAddress

            if ($bindings) {
                $siteResult.OldThumbprint = $bindings[0].Thumbprint
            }

            if (-not ($TestMode -and -not $isTestServer) -and -not $WhatIf) {
                $updated = Set-RemoteIISBinding -Server $target.Server -SiteName $site.Name -HostHeader $site.HostHeader -Port $site.Port -IPAddress $site.IPAddress -NewThumbprint $newThumbprint -SNI $site.SNI -WhatIf $false

                if ($updated) {
                    $siteResult.Status = "Updated"

                    if ($site.HealthCheckURL) {
                        $healthResult = Test-HealthCheck -URL $site.HealthCheckURL -Skip $SkipHealthCheck
                        $siteResult.HealthCheckResult = $healthResult

                        if (-not $healthResult.Success -and $siteResult.OldThumbprint) {
                            Write-CertDeployLog "Health check failed, rolling back binding on $($target.Server)..." -Level WARNING

                            $rolledBack = Set-RemoteIISBinding -Server $target.Server -SiteName $site.Name -HostHeader $site.HostHeader -Port $site.Port -IPAddress $site.IPAddress -NewThumbprint $siteResult.OldThumbprint -SNI $site.SNI -WhatIf $false

                            if ($rolledBack) {
                                $siteResult.RolledBack = $true
                                $siteResult.Status = "RolledBack"
                                $results.Rollback += @{
                                    Server = $target.Server
                                    Site = $site.Name
                                    OldThumbprint = $siteResult.OldThumbprint
                                    Reason = "Health check failed"
                                }
                            }
                        } else {
                            $siteResult.Status = "Success"
                        }
                    }
                } else {
                    $siteResult.Status = "UpdateFailed"
                    $targetResult.Errors += "Binding update failed for site $($site.Name)"
                }
            } elseif ($WhatIf) {
                $siteResult.Status = "WhatIf"
            } else {
                $siteResult.Status = "ImportedOnly"
            }

            $targetResult.Sites += $siteResult
        }

        $targetResult.Status = if ($targetResult.Errors.Count -eq 0) { "Success" } else { "PartialFailure" }
        $results.Targets += $targetResult
    }

    return $results
}

function Invoke-VerifyCommand {
    param(
        [object]$Config,
        [string]$FriendlyName
    )

    Write-CertDeployLog "Starting verify operation..." -Level AUDIT

    $certConfig = $Config.Certificates | Where-Object { $_.FriendlyName -eq $FriendlyName }

    if (-not $certConfig) {
        throw "Certificate configuration not found: $FriendlyName"
    }

    $pfxPath = Join-Path -Path $Config.GlobalSettings.CertShareUNC -ChildPath "$FriendlyName\current.pfx"

    if (-not (Test-Path $pfxPath)) {
        throw "PFX file not found on share: $pfxPath"
    }

    $pfx = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Certificate2
    $pfx.Import($pfxPath, $PFXPassword, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet)
    $expectedThumbprint = $pfx.Thumbprint

    $results = @{
        FriendlyName = $FriendlyName
        ExpectedThumbprint = $expectedThumbprint
        Targets = @()
    }

    foreach ($target in $certConfig.Targets) {
        if ($Server -and $target.Server -ne $Server) {
            continue
        }

        $targetResult = @{
            Server = $target.Server
            Status = "Unknown"
            Sites = @()
        }

        foreach ($site in $target.Sites) {
            $bindings = Get-RemoteIISBindings -Server $target.Server -SiteName $site.Name -HostHeader $site.HostHeader -Port $site.Port -IPAddress $site.IPAddress

            $siteResult = @{
                Name = $site.Name
                HostHeader = $site.HostHeader
                Port = $site.Port
                CurrentThumbprint = if ($bindings) { $bindings[0].Thumbprint } else { $null }
                MatchesExpected = if ($bindings) { $bindings[0].Thumbprint -eq $expectedThumbprint } else { $false }
                HealthCheckResult = $null
            }

            if ($site.HealthCheckURL) {
                $siteResult.HealthCheckResult = Test-HealthCheck -URL $site.HealthCheckURL -Skip $SkipHealthCheck
            }

            $targetResult.Sites += $siteResult
        }

        $allMatched = $targetResult.Sites | Where-Object { -not $_.MatchesExpected }
        $targetResult.Status = if (-not $allMatched) { "Success" } else { "Mismatch" }

        $results.Targets += $targetResult
    }

    return $results
}

function Invoke-ReportCommand {
    param(
        [object]$Config,
        [string]$FriendlyName
    )

    Write-CertDeployLog "Starting report generation..." -Level AUDIT

    $auditResults = Invoke-AuditCommand -Config $Config

    $report = @{
        GeneratedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Summary = $auditResults.Summary
        Details = @()
    }

    foreach ($certResult in $auditResults.Certificates) {
        $certReport = @{
            FriendlyName = $certResult.FriendlyName
            ExpectedDomains = $certResult.ExpectedDomains
            Findings = @()
        }

        foreach ($target in $certResult.Targets) {
            foreach ($site in $target.Sites) {
                if ($site.Expiring.Count -gt 0) {
                    foreach ($exp in $site.Expiring) {
                        $certReport.Findings += @{
                            Type = "Expiring"
                            Severity = if ($exp.DaysRemaining -le 30) { "Critical" } elseif ($exp.DaysRemaining -le 60) { "Warning" } else { "Info" }
                            Server = $target.Server
                            Site = $site.Name
                            HostHeader = $site.HostHeader
                            Message = "Certificate expires in $($exp.DaysRemaining) days"
                            Thumbprint = $exp.Thumbprint
                            NotAfter = $exp.NotAfter
                        }
                    }
                }

                if ($site.Mismatched) {
                    $certReport.Findings += @{
                        Type = "Mismatch"
                        Severity = "Warning"
                        Server = $target.Server
                        Site = $site.Name
                        HostHeader = $site.HostHeader
                        Message = "Certificate does not match expected domains"
                    }
                }
            }
        }

        $report.Details += $certReport
    }

    return $report
}

#endregion

#region Main Script

$ErrorActionPreference = "Stop"

$script:LogFile = $null
$script:LogDir = $null

try {
    $config = Get-CertDeployConfig -Path $ConfigPath

    if ($Command -eq "self-test") {
        $selfTest = Invoke-CertDeploySelfTest
        exit 0
    }

    Test-CertDeployPrerequisites -Config $config

    $result = $null

    switch ($Command) {
        "audit" {
            $result = Invoke-AuditCommand -Config $config
            Write-CertDeployLog "`n=== AUDIT SUMMARY ===" -Level AUDIT
            Write-CertDeployLog "Total Certificates: $($result.Summary.TotalCerts)" -Level INFO
            Write-CertDeployLog "Expiring (<= 30 days): $($result.Summary.Expiring30Days)" -Level INFO
            Write-CertDeployLog "Expiring (<= 60 days): $($result.Summary.Expiring60Days)" -Level INFO
            Write-CertDeployLog "Expiring (<= 90 days): $($result.Summary.Expiring90Days)" -Level INFO
            Write-CertDeployLog "Mismatched Bindings: $($result.Summary.MismatchedBindings)" -Level INFO
        }

        "package" {
            if (-not $FriendlyName) {
                throw "FriendlyName is required for package command"
            }
            $result = Invoke-PackageCommand -Config $config -FriendlyName $FriendlyName -WhatIf $WhatIf
            if ($result.Success -and -not $result.WhatIf) {
                Write-CertDeployLog "`n=== PACKAGE COMPLETE ===" -Level AUDIT
                Write-CertDeployLog "FriendlyName: $($result.FriendlyName)" -Level INFO
                Write-CertDeployLog "Thumbprint: $($result.Thumbprint)" -Level INFO
                Write-CertDeployLog "Expiry Date: $($result.ExpiryDate)" -Level INFO
                Write-CertDeployLog "Share Path: $($result.SharePath)" -Level INFO
            }
        }

        "deploy" {
            if (-not $FriendlyName) {
                throw "FriendlyName is required for deploy command"
            }
            $result = Invoke-DeployCommand -Config $config -FriendlyName $FriendlyName -TestMode $TestMode -WhatIf $WhatIf
            Write-CertDeployLog "`n=== DEPLOY SUMMARY ===" -Level AUDIT
            Write-CertDeployLog "FriendlyName: $($result.FriendlyName)" -Level INFO
            Write-CertDeployLog "New Thumbprint: $($result.NewThumbprint)" -Level INFO
            Write-CertDeployLog "New Expiry Date: $($result.NewExpiryDate)" -Level INFO
            Write-CertDeployLog "Targets Processed: $($result.Targets.Count)" -Level INFO
            $successCount = ($result.Targets | Where-Object { $_.Status -eq "Success" }).Count
            Write-CertDeployLog "Successful: $successCount" -Level INFO
            if ($result.Rollback.Count -gt 0) {
                Write-CertDeployLog "Rollbacks Performed: $($result.Rollback.Count)" -Level WARNING
            }
        }

        "verify" {
            if (-not $FriendlyName) {
                throw "FriendlyName is required for verify command"
            }
            $result = Invoke-VerifyCommand -Config $config -FriendlyName $FriendlyName
            Write-CertDeployLog "`n=== VERIFY SUMMARY ===" -Level AUDIT
            Write-CertDeployLog "FriendlyName: $($result.FriendlyName)" -Level INFO
            Write-CertDeployLog "Expected Thumbprint: $($result.ExpectedThumbprint)" -Level INFO
            $allMatched = ($result.Targets | Where-Object { $_.Status -ne "Success" }).Count -eq 0
            Write-CertDeployLog "All Targets Matched: $allMatched" -Level INFO
        }

        "report" {
            $result = Invoke-ReportCommand -Config $config
            Write-CertDeployLog "`n=== REPORT GENERATED ===" -Level AUDIT
            Write-CertDeployLog "Generated At: $($result.GeneratedAt)" -Level INFO
            Write-CertDeployLog "Total Certificates: $($result.Summary.TotalCerts)" -Level INFO
            $criticalFindings = ($result.Details | ForEach-Object { $_.Findings } | Where-Object { $_.Severity -eq "Critical" }).Count
            Write-CertDeployLog "Critical Findings: $criticalFindings" -Level INFO
        }
    }

    if ($ExportJson -and $result) {
        $exportPath = ".\CertDeploy_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
        $result | ConvertTo-Json -Depth 10 | Set-Content -Path $exportPath
        Write-CertDeployLog "Results exported to: $exportPath" -Level INFO
    }

    $exitCode = 0

    if ($result -and ($result.Summary?.Expiring30Days -gt 0 -or $result.Rollback?.Count -gt 0)) {
        $exitCode = 1
    }

    exit $exitCode

} catch {
    Write-CertDeployLog "FATAL ERROR: $_" -Level ERROR
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    exit 1
}

#endregion