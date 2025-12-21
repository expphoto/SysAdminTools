# SharePoint Administration Script
# This script provides an interactive menu for common SharePoint admin tasks

# First, connect to SharePoint Online
function Connect-ToSharePoint {
    try {
        Write-Host "Connecting to SharePoint Online..." -ForegroundColor Yellow
        Connect-SPOService -Url ""
        Write-Host "Successfully connected to SharePoint Online" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "Error connecting to SharePoint Online: $_" -ForegroundColor Red
        return $false
    }
}

# Function to restore a deleted site
function Restore-DeletedSite {
    param($UserUPN)
    try {
        # Get the personal site URL
        $personalSiteUrl = "" + $UserUPN.Replace("@", "_").Replace(".", "_")
        
        # Restore the site
        Restore-SPODeletedSite -Identity $personalSiteUrl
        Write-Host "Successfully restored site for $UserUPN" -ForegroundColor Green
        Write-Host "Site URL: $personalSiteUrl" -ForegroundColor Green
    }
    catch {
        Write-Host "Error restoring site: $_" -ForegroundColor Red
    }
}

# Function to search for deleted sites
function Search-DeletedSites {
    param($SearchTerm)
    try {
        $deletedSites = Get-SPODeletedSite | Where-Object { $_.Url -like "*$SearchTerm*" }
        if ($deletedSites) {
            Write-Host "Found the following deleted sites:" -ForegroundColor Yellow
            $deletedSites | Format-Table Url, DaysRemaining
        }
        else {
            Write-Host "No deleted sites found matching '$SearchTerm'" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "Error searching for deleted sites: $_" -ForegroundColor Red
    }
}

# Function to add site collection admin
function Add-SiteCollectionAdmin {
    param($SiteUrl, $AdminUPN)
    try {
        Set-SPOUser -Site $SiteUrl -LoginName $AdminUPN -IsSiteCollectionAdmin $true
        Write-Host "Successfully added $AdminUPN as site collection admin" -ForegroundColor Green
        Write-Host "Site URL: $SiteUrl" -ForegroundColor Green
    }
    catch {
        Write-Host "Error adding site collection admin: $_" -ForegroundColor Red
    }
}

# Function to remove site collection admin
function Remove-SiteCollectionAdmin {
    param($SiteUrl, $AdminUPN)
    try {
        Set-SPOUser -Site $SiteUrl -LoginName $AdminUPN -IsSiteCollectionAdmin $false
        Write-Host "Successfully removed $AdminUPN as site collection admin" -ForegroundColor Green
        Write-Host "Site URL: $SiteUrl" -ForegroundColor Green
    }
    catch {
        Write-Host "Error removing site collection admin: $_" -ForegroundColor Red
    }
}

# Function to search for sites based on username
function Search-SitesByUsername {
    param($Username)
    try {
        Write-Host "Searching for sites associated with user: $Username" -ForegroundColor Yellow
        
        # Search for personal site (OneDrive)
        $personalSiteUrl = "" + $Username.Replace("@", "_").Replace(".", "_")
        Write-Host "`nPersonal Site (OneDrive):" -ForegroundColor Cyan
        try {
            $personalSite = Get-SPOSite -Identity $personalSiteUrl -ErrorAction SilentlyContinue
            if ($personalSite) {
                $personalSite | Format-Table Url, Title, Owner, LastContentModifiedDate
            } else {
                Write-Host "No personal site found for this user" -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "No personal site found for this user" -ForegroundColor Yellow
        }
        
        # Search for sites where user is a member
        Write-Host "`nSites where user is a member:" -ForegroundColor Cyan
        $userSites = Get-SPOSite -Limit All | Where-Object {
            try {
                $user = Get-SPOUser -Site $_.Url -LoginName $Username -ErrorAction SilentlyContinue
                $user -ne $null
            }
            catch {
                $false
            }
        }
        
        if ($userSites) {
            $userSites | Format-Table Url, Title, Owner, LastContentModifiedDate
        } else {
            Write-Host "No sites found where this user is a member" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "Error searching for sites: $_" -ForegroundColor Red
    }
}

# Function to list site collection admins
function Get-SiteCollectionAdmins {
    param($SiteUrl)
    try {
        Write-Host "Retrieving site collection admins for: $SiteUrl" -ForegroundColor Yellow
        $admins = Get-SPOUser -Site $SiteUrl -Limit All | Where-Object { $_.IsSiteCollectionAdmin -eq $true }
        
        if ($admins) {
            Write-Host "`nSite Collection Administrators:" -ForegroundColor Cyan
            $admins | Format-Table DisplayName, LoginName, IsSiteCollectionAdmin
        } else {
            Write-Host "No site collection administrators found for this site" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "Error retrieving site collection admins: $_" -ForegroundColor Red
    }
}

# Main menu function
function Show-Menu {
    Clear-Host
    Write-Host "================ SharePoint Admin Tool ================" -ForegroundColor Cyan
    Write-Host "1: Restore deleted personal site"
    Write-Host "2: Search for deleted sites"
    Write-Host "3: Add site collection admin"
    Write-Host "4: Remove site collection admin"
    Write-Host "5: Search for sites by username"
    Write-Host "6: List site collection admins"
    Write-Host "Q: Quit"
    Write-Host "=================================================" -ForegroundColor Cyan
}

# Main script
if (Connect-ToSharePoint) {
    do {
        Show-Menu
        $selection = Read-Host "Please make a selection"
        
        switch ($selection) {
            '1' {
                $userUPN = Read-Host "Enter user's UPN (email)"
                Restore-DeletedSite -UserUPN $userUPN
                pause
            }
            '2' {
                $searchTerm = Read-Host "Enter search term"
                Search-DeletedSites -SearchTerm $searchTerm
                pause
            }
            '3' {
                $siteType = Read-Host "Is this a personal site (OneDrive)? (Y/N)"
                if ($siteType.ToUpper() -eq 'Y') {
                    $userEmail = Read-Host "Enter user's email"
                    $siteUrl = "" + $userEmail.Replace("@", "_").Replace(".", "_")
                } else {
                    $siteUrl = Read-Host "Enter site collection URL"
                }
                $adminUPN = Read-Host "Enter UPN (email) of user to add as admin"
                Add-SiteCollectionAdmin -SiteUrl $siteUrl -AdminUPN $adminUPN
                pause
            }
            '4' {
                $siteUrl = Read-Host "Enter site collection URL"
                $adminUPN = Read-Host "Enter UPN (email) of user to remove as admin"
                Remove-SiteCollectionAdmin -SiteUrl $siteUrl -AdminUPN $adminUPN
                pause
            }
            '5' {
                $username = Read-Host "Enter username (UPN/email)"
                Search-SitesByUsername -Username $username
                pause
            }
            '6' {
                $siteType = Read-Host "Is this a personal site (OneDrive)? (Y/N)"
                if ($siteType.ToUpper() -eq 'Y') {
                    $userEmail = Read-Host "Enter user's email"
                    $siteUrl = "" + $userEmail.Replace("@", "_").Replace(".", "_")
                } else {
                    $siteUrl = Read-Host "Enter site collection URL"
                }
                Get-SiteCollectionAdmins -SiteUrl $siteUrl
                pause
            }
        }
    }
    until ($selection -eq 'q')
}

Write-Host "Script complete. Thanks for using the SharePoint Admin Tool!" -ForegroundColor Cyan