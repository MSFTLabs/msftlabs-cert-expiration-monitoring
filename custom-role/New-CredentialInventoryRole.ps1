<#
.SYNOPSIS
    Imports credential-inventory-role.json and creates the custom RBAC role.

.DESCRIPTION
    Creates (or updates) a custom Azure RBAC role from the JSON definition file
    in the same directory. The role is scoped at the tenant root management group.

    Before running, update the AssignableScopes in credential-inventory-role.json
    to replace <TENANT_ROOT_GROUP_ID> with your actual tenant ID. 
    To find your tenant ID, run: (Get-AzContext).Tenant.Id

    References:
      Custom roles overview:
        https://learn.microsoft.com/azure/role-based-access-control/custom-roles
      Create custom roles with Azure CLI:
        https://learn.microsoft.com/azure/role-based-access-control/custom-roles-cli
      Role definition schema (Actions, DataActions, AssignableScopes):
        https://learn.microsoft.com/azure/role-based-access-control/role-definitions
      AssignableScopes at management group / tenant root:
        https://learn.microsoft.com/azure/role-based-access-control/role-definitions#assignablescopes
      Key Vault RBAC data-plane permissions:
        https://learn.microsoft.com/azure/key-vault/general/rbac-guide
      Key Vault built-in roles (secrets/readMetadata, certificates/read, keys/read):
        https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/security#key-vault-reader
      Logs Ingestion API (dataCollectionRules/data/write):
        https://learn.microsoft.com/azure/azure-monitor/logs/logs-ingestion-api-overview
      Log Analytics workspace read permission:
        https://learn.microsoft.com/azure/azure-monitor/logs/manage-access
      Graph API permission for App Reg secrets/certs (NOT RBAC - requires Application.Read.All):
        https://learn.microsoft.com/graph/permissions-reference#applicationreadall

.EXAMPLE
    .\New-CredentialInventoryRole.ps1
#>

$roleFile = Join-Path $PSScriptRoot 'credential-inventory-role.json'

# Create or update the custom role
# https://learn.microsoft.com/azure/role-based-access-control/custom-roles-cli#create-a-custom-role
$existing = az role definition list --name 'Credential Inventory Reader' --query '[0].id' -o tsv 2>$null
if ($LASTEXITCODE -eq 0 -and $existing) {
    Write-Host "Role already exists - updating..." -ForegroundColor Yellow
    az role definition update --role-definition $roleFile
}
else {
    Write-Host "Creating custom role..." -ForegroundColor Cyan
    az role definition create --role-definition $roleFile
}
