$ErrorActionPreference = "Stop"

# QuickBooks -> Local staging for DropSuite capture.
# Intended to run on Tom's workstation via TacticalRMM.
# Prefer running in logged-in user context so mapped drives (Y:) are available.

# Source locations (mapped share + UNC fallback)
$sourcePaths = @(
    "Y:\QuickBooks",
    "Y:\",
    "\\Server2022AD\Financials\QuickBooks",
    "\\Server2022AD\Financials"
)

# Destination on local workstation (DropSuite-protected)
$destRoot = Join-Path $env:USERPROFILE "Documents\QB-Backup-Staging"
$workDir  = Join-Path $destRoot "current"
$zipDir   = Join-Path $destRoot "archives"
$logFile  = Join-Path $destRoot "backup.log"

# Retention
$keepArchives = 14

# File patterns to collect
$patterns = @("*.QBW", "*.QBB", "*.TLG", "*.ND")

New-Item -ItemType Directory -Path $workDir -Force | Out-Null
New-Item -ItemType Directory -Path $zipDir -Force | Out-Null

# Clear current staging
Get-ChildItem -Path $workDir -Force -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

$copied = 0
$usedSource = $null

foreach ($src in $sourcePaths) {
    if (-not (Test-Path $src)) { continue }

    foreach ($pat in $patterns) {
        Get-ChildItem -Path $src -Recurse -File -Filter $pat -ErrorAction SilentlyContinue |
            ForEach-Object {
                $relative = $_.FullName.Substring($src.Length).TrimStart('\\')
                $target = Join-Path $workDir $relative
                $targetDir = Split-Path $target -Parent

                if (-not (Test-Path $targetDir)) {
                    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
                }

                try {
                    Copy-Item -Path $_.FullName -Destination $target -Force -ErrorAction Stop
                    $copied++
                }
                catch {
                    # Locked QBW files are common while QuickBooks is open.
                    # Continue collecting what we can.
                }
            }
    }

    if ($copied -gt 0) {
        $usedSource = $src
        break
    }
}

$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$zipPath = Join-Path $zipDir "QB-Backup-$ts.zip"

if ($copied -gt 0) {
    Compress-Archive -Path (Join-Path $workDir "*") -DestinationPath $zipPath -CompressionLevel Optimal -Force

    Get-ChildItem -Path $zipDir -Filter "QB-Backup-*.zip" -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $keepArchives |
        Remove-Item -Force

    $msg = "$(Get-Date -Format s) SUCCESS source='$usedSource' copied=$copied archive='$zipPath'"
    Add-Content -Path $logFile -Value $msg
    Write-Output $msg
    exit 0
}
else {
    $msg = "$(Get-Date -Format s) WARN no QuickBooks files copied (check path/locks)."
    Add-Content -Path $logFile -Value $msg
    Write-Output $msg
    exit 1
}

