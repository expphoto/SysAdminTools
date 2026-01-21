# Systematically delete the 2 specific sharing links

Write-Host "========================================" -ForegroundColor Red
Write-Host "DELETE 2 SPECIFIC SHARING LINKS" -ForegroundColor Red
Write-Host "========================================" -ForegroundColor Red
Write-Host ""

# Links to delete (from audit logs)
$linksToDelete = @(
    @{
        Link = "Virginia's Anonymous Link"
        Owner = "Joseph@channelislandslg.com"
        Folder = "Virginia_External"
        Description = "Anonymous Edit Link on Virginia_External folder"
        Risk = "36 external people accessed"
    },
    @{
        Link = "Kevin's Sharing Link"
        Owner = "Rhiannon@channelislandslg.com"
        Folder = "Webb, Anna"
        Description = "Sharing link created by Kevin (paralegal)"
        Risk = "3 access events in July 2025"
    }
)

Write-Host "Links to delete:" -ForegroundColor Yellow
foreach ($link in $linksToDelete) {
    Write-Host "  1. $($link.Link)" -ForegroundColor Gray
    Write-Host "     Owner: $($link.Owner)" -ForegroundColor Gray
    Write-Host "     Folder: $($link.Folder)" -ForegroundColor Gray
    Write-Host "     Description: $($link.Description)" -ForegroundColor Gray
    Write-Host "     Risk: $($link.Risk)" -ForegroundColor Red
    Write-Host ""
}

Write-Host "⚠️  This will DELETE these sharing links!" -ForegroundColor Red
Write-Host ""

$confirmation = Read-Host "Type 'DELETE' to proceed"

if ($confirmation -ne "DELETE") {
    Write-Host "Cancelled" -ForegroundColor Yellow
    exit
}

Write-Host ""
Write-Host "Deleting sharing links..." -ForegroundColor Cyan
Write-Host ""

Import-Module PnP.PowerShell

# Delete Virginia's sharing link (Joseph's OneDrive)
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Deleting Virginia's Link" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

try {
    Write-Host "Connecting to Joseph's OneDrive..." -ForegroundColor Yellow
    Connect-PnPOnline -Url "https://netorg368294-my.sharepoint.com/personal/joseph_channelislandslg_com" -Interactive

    Write-Host "Getting Virginia_External folder..." -ForegroundColor Yellow
    $docLib = Get-PnPList -Identity "Documents"
    $folder = Get-PnPListItem -List $docLib -Query "<View><Query><Where><Eq><FieldRef Name='FileLeafRef'/><Value Type='Text'>Virginia_External</Value></Eq></Where></Query></View>" -ErrorAction SilentlyContinue

    if ($folder) {
        Write-Host "Found folder: $($folder['FileLeafRef'])" -ForegroundColor Green
        Write-Host "Folder ID: $($folder.Id)" -ForegroundColor Gray

        Write-Host "Getting sharing links..." -ForegroundColor Yellow
        $sharingLinks = Get-PnPFileSharingLink -Identity $folder.Id -List $docLib

        if ($sharingLinks) {
            Write-Host "Found $($sharingLinks.Count) sharing link(s)" -ForegroundColor Gray

            foreach ($link in $sharingLinks) {
                Write-Host "  Link: $($link.ShareLink.Scope)" -ForegroundColor Gray
                Write-Host "    ID: $($link.Id)" -ForegroundColor Gray

                if ($link.ShareLink.IsAnonymous -or $link.ShareLink.AllowsAnonymousAccess) {
                    Write-Host "  � Deleting anonymous link..." -ForegroundColor Red
                    Remove-PnPFileSharingLink -Identity $link.Id -Force -ErrorAction SilentlyContinue
                    Write-Host "  ✅ Deleted" -ForegroundColor Green
                } else {
                    Write-Host "  → Skipping (not anonymous)" -ForegroundColor Yellow
                }
            }
        } else {
            Write-Host "  ✅ No sharing links found (already deleted)" -ForegroundColor Green
        }
    } else {
        Write-Host "  ❌ Folder not found (already deleted)" -ForegroundColor Red
    }

    Disconnect-PnPOnline -ErrorAction SilentlyContinue
}
catch {
    Write-Host "  ❌ Error: $($_.Exception.Message)" -ForegroundColor Red
    Disconnect-PnPOnline -ErrorAction SilentlyContinue
}

Write-Host ""

# Delete Kevin's sharing link (Rhiannon's OneDrive)
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Deleting Kevin's Link" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

try {
    Write-Host "Connecting to Rhiannon's OneDrive..." -ForegroundColor Yellow
    Connect-PnPOnline -Url "https://netorg368294-my.sharepoint.com/personal/rhiannon_channelislandslg_com" -Interactive

    Write-Host "Getting Webb, Anna folder..." -ForegroundColor Yellow
    $docLib = Get-PnPList -Identity "Documents"
    $folder = Get-PnPListItem -List $docLib -Query "<View><Query><Where><Eq><FieldRef Name='FileLeafRef'/><Value Type='Text'>Webb, Anna</Value></Eq></Where></Query></View>" -ErrorAction SilentlyContinue

    if ($folder) {
        Write-Host "Found folder: $($folder['FileLeafRef'])" -ForegroundColor Green
        Write-Host "Folder ID: $($folder.Id)" -ForegroundColor Gray

        Write-Host "Getting sharing links..." -ForegroundColor Yellow
        $sharingLinks = Get-PnPFileSharingLink -Identity $folder.Id -List $docLib

        if ($sharingLinks) {
            Write-Host "Found $($sharingLinks.Count) sharing link(s)" -ForegroundColor Gray

            foreach ($link in $sharingLinks) {
                Write-Host "  Link: $($link.ShareLink.Scope)" -ForegroundColor Gray
                Write-Host "    ID: $($link.Id)" -ForegroundColor Gray

                # Delete all sharing links (Kevin's was anonymous link)
                Write-Host "  � Deleting sharing link..." -ForegroundColor Red
                Remove-PnPFileSharingLink -Identity $link.Id -Force -ErrorAction SilentlyContinue
                Write-Host "  ✅ Deleted" -ForegroundColor Green
            }
        } else {
            Write-Host "  ✅ No sharing links found (already deleted)" -ForegroundColor Green
        }
    } else {
        Write-Host "  ❌ Folder not found (already deleted)" -ForegroundColor Red
    }

    Disconnect-PnPOnline -ErrorAction SilentlyContinue
}
catch {
    Write-Host "  ❌ Error: $($_.Exception.Message)" -ForegroundColor Red
    Disconnect-PnPOnline -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "DELETION COMPLETE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "✓ Both sharing links have been systematically deleted!" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Verify deletion in audit logs (24 hours)" -ForegroundColor Gray
Write-Host "  2. Remove Virginia's direct permission if needed" -ForegroundColor Gray
Write-Host "  3. Monitor for any new sharing links" -ForegroundColor Gray
Write-Host ""

Disconnect-PnPOnline -ErrorAction SilentlyContinue
Write-Host "Done!" -ForegroundColor Green
