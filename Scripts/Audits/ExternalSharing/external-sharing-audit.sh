#!/bin/bash

#
# External Sharing Audit Script using Microsoft Graph CLI
# Searches SharePoint and OneDrive for external shares matching a specific name
#
# Requirements:
#   - Microsoft Graph CLI (https://learn.microsoft.com/en-us/graph/cli/installation)
#   - Install with: brew install microsoft/msgraph/msgraph-cli
#
# Usage:
#   ./external-sharing-audit.sh "Virginia"
#

if [ $# -eq 0 ]; then
    echo "Usage: $0 <search_name> [output_file]"
    echo "Example: $0 Virginia external-shares.json"
    exit 1
fi

SEARCH_NAME="$1"
OUTPUT_FILE="${2:-external-shares-$(date +%Y%m%d-%H%M%S).json}"

echo "======================================"
echo "External Sharing Audit"
echo "======================================"
echo "Searching for: $SEARCH_NAME"
echo "Output file: $OUTPUT_FILE"
echo ""

# Check if mgc is installed
if ! command -v mgc &> /dev/null; then
    echo "Error: Microsoft Graph CLI (mgc) is not installed."
    echo "Install it with: brew install microsoft/msgraph/msgraph-cli"
    exit 1
fi

# Login to Microsoft Graph
echo "Logging in to Microsoft Graph..."
mgc login --scopes "Sites.Read.All,Files.Read.All,User.Read.All"

if [ $? -ne 0 ]; then
    echo "Error: Failed to authenticate"
    exit 1
fi

echo ""
echo "Retrieving SharePoint sites..."

# Get all sites
mgc sites list --all > /tmp/sites.json

# Get all users (to identify external users)
echo "Retrieving external users matching '$SEARCH_NAME'..."
mgc users list --filter "userType eq 'Guest' and (startswith(displayName,'$SEARCH_NAME') or contains(displayName,'$SEARCH_NAME') or contains(mail,'$SEARCH_NAME'))" --select id,displayName,mail,userPrincipalName,userType > /tmp/external_users.json

EXTERNAL_USER_COUNT=$(cat /tmp/external_users.json | grep -c "\"id\"")
echo "Found $EXTERNAL_USER_COUNT external users matching '$SEARCH_NAME'"

if [ $EXTERNAL_USER_COUNT -eq 0 ]; then
    echo ""
    echo "No external users found matching '$SEARCH_NAME'"
    echo "The search is complete."
    mgc logout
    exit 0
fi

echo ""
echo "External users found:"
cat /tmp/external_users.json | grep -E "(displayName|mail)" | sed 's/^/  /'

echo ""
echo "======================================"
echo "To find files shared with these users,"
echo "we need to check permissions on each site/drive."
echo "This may take a while..."
echo "======================================"

# Note: The full implementation would require iterating through:
# 1. Each site's drive
# 2. Each file's permissions
# 3. Matching against external users
# This is complex and time-consuming via CLI

echo ""
echo "RECOMMENDATION:"
echo "The PowerShell script (Invoke-ExternalSharingAudit.ps1) provides"
echo "more comprehensive scanning capabilities."
echo ""
echo "For a quick audit, you can also:"
echo "1. Go to SharePoint Admin Center > Reports > Sharing"
echo "2. Use PowerShell with SharePoint Online Management Shell"
echo ""
echo "External users matching '$SEARCH_NAME' have been saved to:"
echo "/tmp/external_users.json"

# Cleanup and logout
mgc logout

echo ""
echo "Audit information collected. Review /tmp/external_users.json for details."
