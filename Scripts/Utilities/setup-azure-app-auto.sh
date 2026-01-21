#!/bin/bash

#
# Azure AD App Registration Script (Automated)
# Automatically registers an app for SharePoint/OneDrive auditing
#

set -e

echo "======================================"
echo "Azure AD App Registration"
echo "======================================"
echo ""

TENANT_ID=$(az account show --query tenantId -o tsv)
ACCOUNT=$(az account show --query user.name -o tsv)

echo "Logged in as: $ACCOUNT"
echo "Tenant ID: $TENANT_ID"
echo ""

# App name
APP_NAME="SharePoint-External-Sharing-Audit"
echo "Creating app registration: $APP_NAME"

# Check if app already exists
EXISTING_APP=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv 2>/dev/null)

if [ ! -z "$EXISTING_APP" ] && [ "$EXISTING_APP" != "null" ]; then
    echo "App already exists with Client ID: $EXISTING_APP"
    APP_ID="$EXISTING_APP"
    echo "Using existing app..."
else
    # Register the app
    echo "Registering new app..."
    APP_ID=$(az ad app create \
        --display-name "$APP_NAME" \
        --sign-in-audience "AzureADMyOrg" \
        --public-client-redirect-uris "http://localhost" \
        --enable-access-token-issuance true \
        --query appId -o tsv)

    echo "Created app with Client ID: $APP_ID"
fi

# Enable public client flow
echo ""
echo "Configuring public client flow..."
az ad app update --id $APP_ID --is-fallback-public-client true

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
az ad app permission add --id $APP_ID --api $GRAPH_API_ID --api-permissions 205e70e5-aba6-4c52-a976-6d2d46c48043=Scope 2>/dev/null || echo "    (already exists)"

echo "  - Microsoft Graph: User.Read.All"
az ad app permission add --id $APP_ID --api $GRAPH_API_ID --api-permissions a154be20-db9c-4678-8ab7-66f6cc099a59=Scope 2>/dev/null || echo "    (already exists)"

# SharePoint permissions
# AllSites.Read = d13f72ca-a275-4b96-b789-48ebcc4da984
echo "  - SharePoint: AllSites.Read"
az ad app permission add --id $APP_ID --api $SHAREPOINT_API_ID --api-permissions d13f72ca-a275-4b96-b789-48ebcc4da984=Scope 2>/dev/null || echo "    (already exists)"

echo ""
echo "Granting admin consent for permissions..."

# Grant admin consent
az ad app permission admin-consent --id $APP_ID 2>&1 | grep -v "WARNING" || true

# Wait for permissions to propagate
echo "Waiting for permissions to propagate..."
sleep 5

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

# Save to a config file
cat > azure-app-credentials.txt << EOF
# Azure AD App Credentials for SharePoint Audit
# Generated: $(date)

APPLICATION_ID=$APP_ID
TENANT_ID=$TENANT_ID
TENANT_URL=https://netorg368294-admin.sharepoint.com

# Use these values to run the audit
EOF

echo "Credentials saved to: azure-app-credentials.txt"
echo ""
echo "======================================"
echo "App is ready!"
echo "======================================"
echo ""

# Export for next step
export APP_ID
export TENANT_ID
