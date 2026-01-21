#!/bin/bash

#
# Azure AD App Registration Script
# Automatically registers an app for SharePoint/OneDrive auditing
#

set -e

echo "======================================"
echo "Azure AD App Registration"
echo "======================================"
echo ""

# Check if already logged in
echo "Checking Azure CLI login status..."
if ! az account show &> /dev/null; then
    echo "Not logged in. Logging in to Azure..."
    az login
else
    echo "Already logged in to Azure"
    ACCOUNT=$(az account show --query user.name -o tsv)
    echo "Logged in as: $ACCOUNT"
fi

echo ""
echo "Current subscription:"
az account show --query "{Name:name, SubscriptionId:id, TenantId:tenantId}" -o table

echo ""
read -p "Is this the correct subscription? (y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Please run 'az account set --subscription <subscription-id>' to switch subscriptions"
    exit 1
fi

TENANT_ID=$(az account show --query tenantId -o tsv)
echo ""
echo "Using Tenant ID: $TENANT_ID"

# App name
APP_NAME="SharePoint-External-Sharing-Audit"
echo ""
echo "Creating app registration: $APP_NAME"

# Register the app
APP_JSON=$(az ad app create \
    --display-name "$APP_NAME" \
    --sign-in-audience "AzureADMyOrg" \
    --public-client-redirect-uris "http://localhost" \
    --enable-access-token-issuance true 2>/dev/null || echo "")

if [ -z "$APP_JSON" ]; then
    echo ""
    echo "App may already exist. Trying to find existing app..."
    APP_JSON=$(az ad app list --display-name "$APP_NAME" --query "[0]" 2>/dev/null)

    if [ "$APP_JSON" == "null" ] || [ -z "$APP_JSON" ]; then
        echo "Error: Could not create or find the app"
        exit 1
    fi
    echo "Found existing app: $APP_NAME"
fi

APP_ID=$(echo $APP_JSON | jq -r '.appId')
OBJECT_ID=$(echo $APP_JSON | jq -r '.id')

echo "Application (Client) ID: $APP_ID"
echo "Object ID: $OBJECT_ID"

# Enable public client flow
echo ""
echo "Configuring public client flow..."
az ad app update --id $APP_ID --set publicClient.redirectUris="[\"http://localhost\"]" --is-fallback-public-client true

# Microsoft Graph API ID
GRAPH_API_ID="00000003-0000-0000-c000-000000000000"

# SharePoint API ID
SHAREPOINT_API_ID="00000003-0000-0ff1-ce00-000000000000"

echo ""
echo "Adding API permissions..."

# Microsoft Graph permissions
# Sites.Read.All = 205e70e5-aba6-4c52-a976-6d2d46c48043
# User.Read.All = a154be20-db9c-4678-8ab7-66f6cc099a59
echo "  - Microsoft Graph: Sites.Read.All"
az ad app permission add --id $APP_ID --api $GRAPH_API_ID --api-permissions 205e70e5-aba6-4c52-a976-6d2d46c48043=Scope 2>/dev/null || echo "    (already added)"

echo "  - Microsoft Graph: User.Read.All"
az ad app permission add --id $APP_ID --api $GRAPH_API_ID --api-permissions a154be20-db9c-4678-8ab7-66f6cc099a59=Scope 2>/dev/null || echo "    (already added)"

# SharePoint permissions
# AllSites.Read = d13f72ca-a275-4b96-b789-48ebcc4da984
echo "  - SharePoint: AllSites.Read"
az ad app permission add --id $APP_ID --api $SHAREPOINT_API_ID --api-permissions d13f72ca-a275-4b96-b789-48ebcc4da984=Scope 2>/dev/null || echo "    (already added)"

echo ""
echo "Granting admin consent for permissions..."
echo "(This may take a few seconds...)"

# Grant admin consent
az ad app permission admin-consent --id $APP_ID 2>/dev/null || {
    echo ""
    echo "WARNING: Could not automatically grant admin consent."
    echo "You may need to manually grant consent in the Azure Portal."
    echo "Go to: Azure AD > App Registrations > $APP_NAME > API Permissions"
    echo "Then click 'Grant admin consent'"
}

# Wait a moment for permissions to propagate
sleep 3

echo ""
echo "======================================"
echo "SUCCESS!"
echo "======================================"
echo ""
echo "App Registration Details:"
echo "  Name: $APP_NAME"
echo "  Application (Client) ID: $APP_ID"
echo "  Tenant ID: $TENANT_ID"
echo ""
echo "Saving credentials to file..."

# Save to a config file
cat > azure-app-credentials.txt << EOF
# Azure AD App Credentials for SharePoint Audit
# Generated: $(date)

APPLICATION_ID=$APP_ID
TENANT_ID=$TENANT_ID
TENANT_URL=https://netorg368294-admin.sharepoint.com

# Use these values to run the audit:
# pwsh
# ./Invoke-ExternalSharingAudit-CustomApp.ps1 -TenantUrl "$TENANT_URL" -ClientId "$APP_ID" -TenantId "$TENANT_ID" -SearchName "Virginia"
EOF

echo "Credentials saved to: azure-app-credentials.txt"
echo ""
echo "======================================"
echo "Next Steps:"
echo "======================================"
echo ""
echo "Run the audit with:"
echo ""
echo "  pwsh"
echo "  ./Invoke-ExternalSharingAudit-CustomApp.ps1 \\"
echo "      -TenantUrl 'https://netorg368294-admin.sharepoint.com' \\"
echo "      -ClientId '$APP_ID' \\"
echo "      -TenantId '$TENANT_ID' \\"
echo "      -SearchName 'Virginia'"
echo ""
