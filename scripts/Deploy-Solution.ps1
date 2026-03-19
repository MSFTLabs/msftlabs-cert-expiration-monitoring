<#
.SYNOPSIS
    Deploys the Credential Inventory solution into a customer environment.

.DESCRIPTION
    End-to-end deployment for App Registration + Key Vault credential monitoring.
    Creates resource group, Log Analytics workspace (or uses existing), custom tables,
    Data Collection Rules, alerts, Automation Account with runbook, workbooks,
    Azure Portal dashboards, and Grafana dashboards (AppReg, Key Vault, Unified).

    All parameters are supplied via a single YAML configuration file.
    See deploy-config.yaml at the project root for a template.

.PARAMETER ConfigFile
    Path to the YAML configuration file. Defaults to ..\deploy-config.yaml.

.EXAMPLE
    .\Deploy-Solution.ps1 -ConfigFile '..\deploy-config.yaml'
.EXAMPLE
    .\Deploy-Solution.ps1 -ConfigFile 'C:\configs\prod-deploy.yaml'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ConfigFile
)

$ErrorActionPreference = 'Stop'

# ── Load YAML configuration ─────────────────────────────────────────────────
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Host 'Installing powershell-yaml module...' -ForegroundColor Cyan
    Install-Module -Name powershell-yaml -Scope CurrentUser -Force -AllowClobber
}
Import-Module powershell-yaml -ErrorAction Stop

if (-not (Test-Path -LiteralPath $ConfigFile)) {
    throw "Configuration file not found: $ConfigFile"
}

$config = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Yaml

# ── Map YAML values to script variables ──────────────────────────────────────
$TenantId              = [string]$config.tenantId
$EmailAddresses        = @($config.emailAddresses)
$ResGroup              = [string]$config.resGroup
$WorkspaceId           = [string]$config.workspaceId
$AutomationAccountId   = [string]$config.automationAccountId

$Location              = [string]$config.location
$Tags                  = if ($config.tags -is [hashtable]) { $config.tags }
                         elseif ($config.tags) { [hashtable]$config.tags }
                         else { @{} }
$CreateRole            = [bool]$config.createRole
$CreateWorkbooks       = [bool]$config.createWorkbooks

$AppRegTableName       = [string]$config.appRegTableName
$AppRegDcrName         = [string]$config.appRegDcrName
$KvTableName           = [string]$config.kvTableName
$KvDcrName             = [string]$config.kvDcrName
$ActionGroupName       = [string]$config.actionGroupName
$AutomationAccountName = [string]$config.automationAccountName
$PortalDashboardName   = [string]$config.portalDashboardName

$GrafanaAppRegDashName  = [string]$config.grafanaAppRegDashName
$GrafanaKvDashName      = [string]$config.grafanaKvDashName
$GrafanaUnifiedDashName = [string]$config.grafanaUnifiedDashName

# ── AZ CLI Helpers ───────────────────────────────────────────────────────────

function Invoke-AzCli {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($output -join [Environment]::NewLine) }
    return $output
}

function Get-AzCliScalar {
    param([Parameter(Mandatory)][string[]]$Arguments)
    return ((Invoke-AzCli -Arguments $Arguments) | Out-String).Trim()
}

function Test-AzCliCommand {
    param([Parameter(Mandatory)][string[]]$Arguments)
    & az @Arguments *> $null
    return $LASTEXITCODE -eq 0
}

function Invoke-ArmRequest {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [string]$Body
    )
    $armToken = (& az account get-access-token --resource-type arm --query accessToken -o tsv 2>$null | Out-String).Trim()
    if (-not $armToken) { throw 'Failed to acquire ARM token.' }
    $headers = @{ Authorization = "Bearer $armToken" }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $headers['Content-Type'] = 'application/json'
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -Body $Body
    }
    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
}

function New-DeterministicGuid {
    param([Parameter(Mandatory)][string]$Value)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try { $hash = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value)) }
    finally { $md5.Dispose() }
    return [Guid]::New($hash).Guid
}

function Get-ResourceIdParts {
    param([Parameter(Mandatory)][string]$ResourceId)
    $parts = $ResourceId.Trim('/') -split '/'
    if ($parts.Length -lt 8) { throw "Invalid resource ID: $ResourceId" }
    return [ordered]@{
        subscriptionId = $parts[1]
        resourceGroup  = $parts[3]
        resourceName   = $parts[7]
    }
}

function ConvertTo-TagArgs {
    param([hashtable]$Tags)
    if (-not $Tags -or $Tags.Count -eq 0) { return @() }
    $tagPairs = $Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
    return @('--tags') + $tagPairs
}

function Apply-Tags {
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [hashtable]$Tags
    )
    if (-not $Tags -or $Tags.Count -eq 0) { return }
    $tagArgs = ConvertTo-TagArgs -Tags $Tags
    Invoke-AzCli -Arguments (@('tag', 'update', '--resource-id', $ResourceId, '--operation', 'Merge') + $tagArgs) | Out-Null
}

function Publish-Runbook {
    param(
        [Parameter(Mandatory)][string]$AutomationId,
        [Parameter(Mandatory)][string]$RunbookName,
        [Parameter(Mandatory)][string]$RunbookFilePath,
        [Parameter(Mandatory)][string]$Location,
        [string]$Description = ''
    )

    if (-not (Test-Path -LiteralPath $RunbookFilePath)) {
        throw "Runbook file not found: $RunbookFilePath"
    }

    $runbookContent = Get-Content -LiteralPath $RunbookFilePath -Raw
    $runbookUri = "https://management.azure.com${AutomationId}/runbooks/${RunbookName}?api-version=2023-11-01"
    $runbookBody = @{
        location   = $Location
        properties = @{
            runbookType = 'PowerShell72'
            publishContentLink = $null
            description = $Description
            logProgress = $false
            logVerbose  = $false
        }
    } | ConvertTo-Json -Depth 10 -Compress

    Invoke-ArmRequest -Method 'PUT' -Uri $runbookUri -Body $runbookBody | Out-Null

    # Upload draft content
    $draftUri = "https://management.azure.com${AutomationId}/runbooks/${RunbookName}/draft/content?api-version=2023-11-01"
    $armToken = (& az account get-access-token --resource-type arm --query accessToken -o tsv 2>$null | Out-String).Trim()
    Invoke-RestMethod -Method Put -Uri $draftUri `
        -Headers @{ Authorization = "Bearer $armToken"; 'Content-Type' = 'text/powershell' } `
        -Body $runbookContent | Out-Null

    # Publish
    $publishUri = "https://management.azure.com${AutomationId}/runbooks/${RunbookName}/publish?api-version=2023-11-01"
    Invoke-ArmRequest -Method 'POST' -Uri $publishUri | Out-Null
    Write-Host "    Published runbook: $RunbookName" -ForegroundColor Green
}

function Deploy-Workbook {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$WorkbookFilePath,
        [Parameter(Mandatory)][string]$DisplayName,
        [hashtable]$Tags = @{}
    )

    if (-not (Test-Path -LiteralPath $WorkbookFilePath)) {
        throw "Workbook file not found: $WorkbookFilePath"
    }

    $serializedData = Get-Content -LiteralPath $WorkbookFilePath -Raw | ConvertFrom-Json | ConvertTo-Json -Depth 50 -Compress
    $workbookName = New-DeterministicGuid -Value "$SubscriptionId|$ResourceGroupName|$DisplayName"
    $workbookId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/workbooks/$workbookName"

    $body = @{
        location   = $Location
        kind       = 'shared'
        tags       = $Tags
        properties = @{
            category       = 'workbook'
            displayName    = $DisplayName
            sourceId       = 'Azure Monitor'
            version        = 'Notebook/1.0'
            serializedData = $serializedData
        }
    } | ConvertTo-Json -Depth 20 -Compress

    Invoke-ArmRequest -Method 'PUT' -Uri "https://management.azure.com${workbookId}?api-version=2023-06-01" -Body $body | Out-Null
    Write-Host "    Deployed workbook: $DisplayName" -ForegroundColor Green
    return $workbookId
}

# ── Pre-flight: install required CLI extensions ──────────────────────────────
foreach ($ext in @('monitor-control-service', 'scheduled-query')) {
    & az extension add --name $ext --yes 2>$null
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 0: Prompt for missing required values
# ══════════════════════════════════════════════════════════════════════════════

if (-not $TenantId) {
    $TenantId = Read-Host 'Enter your Azure Tenant ID'
    if (-not $TenantId) { throw 'Tenant ID is required.' }
}

# Ensure AZ CLI is logged in to the correct tenant
$tenantResult = & az account show --query tenantId -o tsv 2>$null
if ($LASTEXITCODE -ne 0 -or $tenantResult -ne $TenantId) {
    Write-Host "Logging in to tenant $TenantId ..." -ForegroundColor Cyan
    Invoke-AzCli -Arguments @('login', '--tenant', $TenantId) | Out-Null
}

$currentSubId = Get-AzCliScalar -Arguments @('account', 'show', '--query', 'id', '-o', 'tsv')

if (-not $ResGroup) {
    $ResGroup = Read-Host 'Enter the target Resource Group name (will be created if it does not exist)'
    if (-not $ResGroup) { throw 'Resource Group name is required.' }
}

Write-Host ''
Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '║          Credential Inventory Solution Deployment           ║' -ForegroundColor Cyan
Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1: Resource Group
# ══════════════════════════════════════════════════════════════════════════════

Write-Host "`n── Step 1: Resource Group ─────────────────────────────────" -ForegroundColor Yellow

$rgExists = Test-AzCliCommand -Arguments @('group', 'show', '--name', $ResGroup)
if ($rgExists) {
    Write-Host "    Resource group '$ResGroup' exists." -ForegroundColor Gray
} else {
    Write-Host "    Creating resource group '$ResGroup' in $Location ..." -ForegroundColor Cyan
    $rgArgs = @('group', 'create', '--name', $ResGroup, '--location', $Location)
    $rgArgs += ConvertTo-TagArgs -Tags $Tags
    Invoke-AzCli -Arguments $rgArgs | Out-Null
}

# Enforce tags on existing RG
if ($Tags.Count -gt 0) {
    $rgId = Get-AzCliScalar -Arguments @('group', 'show', '--name', $ResGroup, '--query', 'id', '-o', 'tsv')
    Apply-Tags -ResourceId $rgId -Tags $Tags
    Write-Host "    Tags applied to $ResGroup" -ForegroundColor Gray
}

# Resolve the subscription that owns the resource group (needed for DCR placement)
$rgSubId = Get-AzCliScalar -Arguments @('group', 'show', '--name', $ResGroup, '--query', 'id', '-o', 'tsv')
$rgSubId = ($rgSubId -split '/')[2]

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2: Custom Role (optional)
# ══════════════════════════════════════════════════════════════════════════════

if ($CreateRole) {
    Write-Host "`n── Step 2: Custom Role ────────────────────────────────────" -ForegroundColor Yellow

    $roleJsonPath = Join-Path $PSScriptRoot 'credential-inventory-role.json'
    $roleContent = Get-Content -LiteralPath $roleJsonPath -Raw

    # Replace placeholder with actual tenant ID if not already done
    if ($roleContent -match '<TENANT_ROOT_GROUP_ID>') {
        Write-Host "    Updating credential-inventory-role.json with tenant ID: $TenantId" -ForegroundColor Cyan
        $roleContent = $roleContent.Replace('<TENANT_ROOT_GROUP_ID>', $TenantId)
        $roleContent | Set-Content -LiteralPath $roleJsonPath -Encoding utf8
    }

    # Delegate to the existing role script
    $roleScript = Join-Path $PSScriptRoot 'New-CredentialInventoryRole.ps1'
    & $roleScript
} else {
    Write-Host "`n── Step 2: Custom Role (skipped — set createRole: true in config) ─" -ForegroundColor DarkGray
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3: Log Analytics Workspace
# ══════════════════════════════════════════════════════════════════════════════

Write-Host "`n── Step 3: Log Analytics Workspace ────────────────────────" -ForegroundColor Yellow

if ($WorkspaceId) {
    Write-Host "    Using existing workspace: $WorkspaceId" -ForegroundColor Gray
} else {
    $wsName = Read-Host '    Enter a name for the new Log Analytics Workspace'
    if (-not $wsName) { throw 'Workspace name is required when -WorkspaceId is not provided.' }

    Write-Host "    Creating workspace '$wsName' in $ResGroup ..." -ForegroundColor Cyan
    $wsArgs = @(
        'monitor', 'log-analytics', 'workspace', 'create',
        '--resource-group', $ResGroup,
        '--workspace-name', $wsName,
        '--location', $Location,
        '--retention-time', '90'
    )
    $wsArgs += ConvertTo-TagArgs -Tags $Tags
    Invoke-AzCli -Arguments $wsArgs | Out-Null

    $WorkspaceId = Get-AzCliScalar -Arguments @(
        'monitor', 'log-analytics', 'workspace', 'show',
        '--resource-group', $ResGroup,
        '--workspace-name', $wsName,
        '--query', 'id', '-o', 'tsv'
    )
    Write-Host "    Created: $WorkspaceId" -ForegroundColor Green
}

$wsParts = Get-ResourceIdParts -ResourceId $WorkspaceId
$wsSubId   = $wsParts.subscriptionId
$wsRgName  = $wsParts.resourceGroup
$wsName    = $wsParts.resourceName

# Ensure we're on the workspace subscription for table/DCR operations
Invoke-AzCli -Arguments @('account', 'set', '--subscription', $wsSubId) | Out-Null

# Apply tags to workspace if we own it
if ($Tags.Count -gt 0) {
    Apply-Tags -ResourceId $WorkspaceId -Tags $Tags
}

# ── Create custom tables ─────────────────────────────────────────────────────

# App Registration table
$appRegTable = $AppRegTableName
if (-not (Test-AzCliCommand -Arguments @(
    'monitor', 'log-analytics', 'workspace', 'table', 'show',
    '--resource-group', $wsRgName, '--workspace-name', $wsName, '--name', $appRegTable
))) {
    Write-Host "    Creating table: $appRegTable" -ForegroundColor Cyan
    Invoke-AzCli -Arguments @(
        'monitor', 'log-analytics', 'workspace', 'table', 'create',
        '--resource-group', $wsRgName, '--workspace-name', $wsName,
        '--name', $appRegTable, '--columns',
        'TimeGenerated=datetime', 'TenantId=string', 'ApplicationObjectId=string',
        'ApplicationId=string', 'ApplicationDisplayName=string', 'CredentialType=string',
        'CredentialDisplayName=string', 'CredentialKeyId=string', 'StartDateUtc=datetime',
        'EndDateUtc=datetime', 'DaysToExpiry=int', 'ExpiryBand=string', 'ExpiryColor=string',
        'IsExpired=bool', 'CollectionRunId=string', 'Collector=string', 'ObjectType=string'
    ) | Out-Null
} else {
    Write-Host "    Table exists: $appRegTable" -ForegroundColor Gray
}

# Key Vault inventory table
$kvTable = $KvTableName
if (-not (Test-AzCliCommand -Arguments @(
    'monitor', 'log-analytics', 'workspace', 'table', 'show',
    '--resource-group', $wsRgName, '--workspace-name', $wsName, '--name', $kvTable
))) {
    Write-Host "    Creating table: $kvTable" -ForegroundColor Cyan
    Invoke-AzCli -Arguments @(
        'monitor', 'log-analytics', 'workspace', 'table', 'create',
        '--resource-group', $wsRgName, '--workspace-name', $wsName,
        '--name', $kvTable, '--columns',
        'TimeGenerated=datetime', 'TenantId=string', 'SubscriptionId=string',
        'ResourceGroup=string', 'VaultName=string', 'ItemType=string', 'ItemName=string',
        'Enabled=bool', 'CreatedOn=datetime', 'ExpiresOn=datetime', 'NotBefore=datetime',
        'DaysToExpiry=int', 'HasExpiration=bool', 'ExpiryBand=string', 'IsExpired=bool',
        'CollectionRunId=string', 'Collector=string'
    ) | Out-Null
} else {
    Write-Host "    Table exists: $kvTable" -ForegroundColor Gray
}

# ── Create Data Collection Rules (one per table) ─────────────────────────────

function Deploy-Dcr {
    param(
        [string]$DcrName, [string]$StreamName, [string]$TableName,
        [array]$Columns, [string]$TransformKql
    )

    $dcrId = "/subscriptions/$rgSubId/resourceGroups/$ResGroup/providers/Microsoft.Insights/dataCollectionRules/$DcrName"
    $dcrBody = @{
        location   = $Location
        kind       = 'Direct'
        properties = @{
            streamDeclarations = @{ $StreamName = @{ columns = $Columns } }
            destinations       = @{ logAnalytics = @(@{ workspaceResourceId = $WorkspaceId; name = 'workspace' }) }
            dataFlows          = @(@{
                streams      = @($StreamName)
                destinations = @('workspace')
                transformKql = $TransformKql
                outputStream = "Custom-$TableName"
            })
        }
    } | ConvertTo-Json -Depth 10 -Compress

    Invoke-ArmRequest -Method 'PUT' -Uri "https://management.azure.com${dcrId}?api-version=2023-03-11" -Body $dcrBody | Out-Null
    $props = Invoke-ArmRequest -Method 'GET' -Uri "https://management.azure.com${dcrId}?api-version=2023-03-11"
    Write-Host "    DCR deployed: $DcrName" -ForegroundColor Green
    return @{
        Id                 = $dcrId
        ImmutableId        = $props.properties.immutableId
        IngestionEndpoint  = $props.properties.endpoints.logsIngestion
    }
}

Write-Host "`n── Step 3b: Data Collection Rules ─────────────────────────" -ForegroundColor Yellow

# Switch to the target RG subscription so DCRs are created there (not in the workspace RG)
Invoke-AzCli -Arguments @('account', 'set', '--subscription', $rgSubId) | Out-Null

$appRegDcr = Deploy-Dcr -DcrName $AppRegDcrName `
    -StreamName 'Custom-AppRegistrationCredentialExpiry' `
    -TableName $appRegTable `
    -Columns @(
        @{name='TimeGenerated';type='datetime'}, @{name='TenantId';type='string'},
        @{name='ApplicationObjectId';type='string'}, @{name='ApplicationId';type='string'},
        @{name='ApplicationDisplayName';type='string'}, @{name='CredentialType';type='string'},
        @{name='CredentialDisplayName';type='string'}, @{name='CredentialKeyId';type='string'},
        @{name='StartDateUtc';type='datetime'}, @{name='EndDateUtc';type='datetime'},
        @{name='DaysToExpiry';type='int'}, @{name='ExpiryBand';type='string'},
        @{name='ExpiryColor';type='string'}, @{name='IsExpired';type='boolean'},
        @{name='CollectionRunId';type='string'}, @{name='Collector';type='string'},
        @{name='ObjectType';type='string'}
    ) `
    -TransformKql 'source | project TimeGenerated, TenantId = toguid(TenantId), ApplicationObjectId, ApplicationId, ApplicationDisplayName, CredentialType, CredentialDisplayName, CredentialKeyId, StartDateUtc, EndDateUtc, DaysToExpiry, ExpiryBand, ExpiryColor, IsExpired, CollectionRunId, Collector, ObjectType'

$kvDcr = Deploy-Dcr -DcrName $KvDcrName `
    -StreamName 'Custom-KeyVaultCredentialInventory' `
    -TableName $kvTable `
    -Columns @(
        @{name='TimeGenerated';type='datetime'}, @{name='TenantId';type='string'},
        @{name='SubscriptionId';type='string'}, @{name='ResourceGroup';type='string'},
        @{name='VaultName';type='string'}, @{name='ItemType';type='string'},
        @{name='ItemName';type='string'}, @{name='Enabled';type='boolean'},
        @{name='CreatedOn';type='datetime'}, @{name='ExpiresOn';type='datetime'},
        @{name='NotBefore';type='datetime'}, @{name='DaysToExpiry';type='int'},
        @{name='HasExpiration';type='boolean'}, @{name='ExpiryBand';type='string'},
        @{name='IsExpired';type='boolean'}, @{name='CollectionRunId';type='string'},
        @{name='Collector';type='string'}
    ) `
    -TransformKql 'source'

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4: Alerts
# ══════════════════════════════════════════════════════════════════════════════

Write-Host "`n── Step 4: Alerts ─────────────────────────────────────────" -ForegroundColor Yellow

# Switch to the subscription that owns the resource group
Invoke-AzCli -Arguments @('account', 'set', '--subscription', $rgSubId) | Out-Null

# Action group
Write-Host "    Creating action group: $ActionGroupName" -ForegroundColor Cyan
$agArgs = @(
    'monitor', 'action-group', 'create',
    '--name', $ActionGroupName,
    '--resource-group', $ResGroup,
    '--short-name', 'CredInv'
)
$emailIdx = 0
foreach ($email in $EmailAddresses) {
    $emailIdx++
    $agArgs += @('--action', 'email', "Email$emailIdx", $email)
}
$agArgs += ConvertTo-TagArgs -Tags $Tags
Invoke-AzCli -Arguments $agArgs | Out-Null

$actionGroupId = Get-AzCliScalar -Arguments @(
    'monitor', 'action-group', 'show',
    '--name', $ActionGroupName, '--resource-group', $ResGroup,
    '--query', 'id', '-o', 'tsv'
)

# Define alerts
$alerts = @(
    @{
        Name        = 'alert-appreg-expiry-30-days'
        Description = 'App registration secret or certificate expires within 30 days.'
        Query       = @"
AppRegistrationCredentialExpiry_CL
| summarize arg_max(TimeGenerated, *) by ApplicationId, CredentialKeyId
| where CredentialType != 'None' and DaysToExpiry < 30
| count
"@
    },
    @{
        Name        = 'alert-kv-secret-expires-30-days'
        Description = 'Key Vault secret expires within 30 days.'
        Query       = @"
KeyVaultCredentialInventory_CL
| summarize arg_max(TimeGenerated, *) by VaultName, ItemType, ItemName
| where ItemType == 'Secret' and HasExpiration == true and DaysToExpiry < 30
| count
"@
    },
    @{
        Name        = 'alert-kv-cert-expires-30-days'
        Description = 'Key Vault certificate expires within 30 days.'
        Query       = @"
KeyVaultCredentialInventory_CL
| summarize arg_max(TimeGenerated, *) by VaultName, ItemType, ItemName
| where ItemType == 'Certificate' and HasExpiration == true and DaysToExpiry < 30
| count
"@
    },
    @{
        Name        = 'alert-kv-key-expires-30-days'
        Description = 'Key Vault key expires within 30 days.'
        Query       = @"
KeyVaultCredentialInventory_CL
| summarize arg_max(TimeGenerated, *) by VaultName, ItemType, ItemName
| where ItemType == 'Key' and HasExpiration == true and DaysToExpiry < 30
| count
"@
    }
)

foreach ($alert in $alerts) {
    $alertExists = Test-AzCliCommand -Arguments @(
        'monitor', 'scheduled-query', 'show',
        '--name', $alert.Name, '--resource-group', $ResGroup
    )
    if ($alertExists) {
        Write-Host "    Alert exists: $($alert.Name)" -ForegroundColor Gray
        continue
    }
    Write-Host "    Creating alert: $($alert.Name)" -ForegroundColor Cyan
    Invoke-AzCli -Arguments @(
        'monitor', 'scheduled-query', 'create',
        '--name', $alert.Name,
        '--resource-group', $ResGroup,
        '--scopes', $WorkspaceId,
        '--condition', "count 'GreaterThan' 0",
        '--condition-query', $alert.Query,
        '--description', $alert.Description,
        '--evaluation-frequency', '24h',
        '--window-size', '24h',
        '--severity', '2',
        '--action-groups', $actionGroupId,
        '--auto-mitigate', 'false'
    ) | Out-Null
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5: Automation Account + Runbooks
# ══════════════════════════════════════════════════════════════════════════════

Write-Host "`n── Step 5: Automation Account ─────────────────────────────" -ForegroundColor Yellow

Invoke-AzCli -Arguments @('account', 'set', '--subscription', $rgSubId) | Out-Null

if ($AutomationAccountId) {
    $automationId = $AutomationAccountId
    Write-Host "    Using existing: $automationId" -ForegroundColor Gray
} else {
    $aaName = if ($AutomationAccountName) { $AutomationAccountName } else {
        $n = Read-Host '    Enter a name for the new Automation Account'
        if (-not $n) { throw 'Automation Account name is required when -AutomationAccountId is not provided.' }
        $n
    }

    $automationId = "/subscriptions/$rgSubId/resourceGroups/$ResGroup/providers/Microsoft.Automation/automationAccounts/$aaName"
    Write-Host "    Creating Automation Account: $aaName ..." -ForegroundColor Cyan

    $aaBody = @{
        location   = $Location
        tags       = $Tags
        identity   = @{ type = 'SystemAssigned' }
        properties = @{ sku = @{ name = 'Basic' }; publicNetworkAccess = $true }
    } | ConvertTo-Json -Depth 10 -Compress

    Invoke-ArmRequest -Method 'PUT' -Uri "https://management.azure.com${automationId}?api-version=2023-11-01" -Body $aaBody | Out-Null
    Write-Host '    Waiting for identity to propagate ...' -ForegroundColor Gray
    Start-Sleep -Seconds 15
}

# Ensure tags on existing account
if ($Tags.Count -gt 0) {
    Apply-Tags -ResourceId $automationId -Tags $Tags
}

$aaResult = Invoke-ArmRequest -Method 'GET' -Uri "https://management.azure.com${automationId}?api-version=2023-11-01"
$aaPrincipalId = $aaResult.identity.principalId
$aaLocation = $aaResult.location
Write-Host "    Managed Identity principal: $aaPrincipalId" -ForegroundColor Gray

# ── RBAC: Monitoring Metrics Publisher on both DCRs ──────────────────────────
Invoke-AzCli -Arguments @('account', 'set', '--subscription', $rgSubId) | Out-Null

foreach ($dcrId in @($appRegDcr.Id, $kvDcr.Id)) {
    $existingAssignment = Get-AzCliScalar -Arguments @(
        'role', 'assignment', 'list',
        '--assignee-object-id', $aaPrincipalId,
        '--role', 'Monitoring Metrics Publisher',
        '--scope', $dcrId,
        '--query', '[0].id', '-o', 'tsv'
    )
    if (-not $existingAssignment) {
        Invoke-AzCli -Arguments @(
            'role', 'assignment', 'create',
            '--assignee-object-id', $aaPrincipalId,
            '--assignee-principal-type', 'ServicePrincipal',
            '--role', 'Monitoring Metrics Publisher',
            '--scope', $dcrId
        ) | Out-Null
        Write-Host "    Granted Monitoring Metrics Publisher on $($dcrId.Split('/')[-1])" -ForegroundColor Gray
    }
}

# ── Graph API: Application.Read.All ──────────────────────────────────────────
$graphAppId = '00000003-0000-0000-c000-000000000000'
$graphReadAllRoleId = '9a5d68dd-52b0-4cc2-bd40-abcf44ac3a30'

$graphToken = Get-AzCliScalar -Arguments @(
    'account', 'get-access-token', '--resource-type', 'ms-graph',
    '--query', 'accessToken', '-o', 'tsv'
)

$graphSpResponse = Invoke-RestMethod -Method Get `
    -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$graphAppId'" `
    -Headers @{ Authorization = "Bearer $graphToken" }
$graphSpId = $graphSpResponse.value[0].id

$existingAppRoles = Invoke-RestMethod -Method Get `
    -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$aaPrincipalId/appRoleAssignments" `
    -Headers @{ Authorization = "Bearer $graphToken" }
$alreadyAssigned = $existingAppRoles.value | Where-Object { $_.appRoleId -eq $graphReadAllRoleId }

if (-not $alreadyAssigned) {
    $graphRoleBody = @{
        principalId = $aaPrincipalId
        resourceId  = $graphSpId
        appRoleId   = $graphReadAllRoleId
    } | ConvertTo-Json -Compress

    Invoke-RestMethod -Method Post `
        -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$aaPrincipalId/appRoleAssignments" `
        -Headers @{ Authorization = "Bearer $graphToken"; 'Content-Type' = 'application/json' } `
        -Body $graphRoleBody | Out-Null
    Write-Host '    Assigned Application.Read.All to Automation MI' -ForegroundColor Green
} else {
    Write-Host '    Application.Read.All already assigned' -ForegroundColor Gray
}

# ── Publish runbook ──────────────────────────────────────────────────────────
Invoke-AzCli -Arguments @('account', 'set', '--subscription', $rgSubId) | Out-Null

Publish-Runbook -AutomationId $automationId -RunbookName 'Publish-CredentialInventory' `
    -RunbookFilePath (Join-Path $PSScriptRoot '..\runbooks\Publish-CredentialInventory.ps1') `
    -Location $aaLocation `
    -Description 'Collects App Registration and Key Vault credential inventory and pushes to Azure Monitor Logs.'

# ── Schedules ────────────────────────────────────────────────────────────────
$startTime = [datetime]::UtcNow.Date.AddDays(1).AddHours(6).ToString('yyyy-MM-ddTHH:mm:ssZ')

$schedules = @(
    @{ ScheduleName = 'DailyCredentialInventoryCollection'; RunbookName = 'Publish-CredentialInventory';
       Params = @{
           tenantid              = $TenantId
           logingestionendpoint  = $appRegDcr.IngestionEndpoint
           dcrimmutableid        = $appRegDcr.ImmutableId
           kvlogingestionendpoint = $kvDcr.IngestionEndpoint
           kvdcrimmutableid       = $kvDcr.ImmutableId
       }
    }
)

foreach ($sched in $schedules) {
    $schedUri = "https://management.azure.com${automationId}/schedules/$($sched.ScheduleName)?api-version=2023-11-01"
    $schedBody = @{
        properties = @{
            description = "Daily 06:00 UTC schedule for $($sched.RunbookName)"
            startTime   = $startTime
            frequency   = 'Day'
            interval    = 1
            timeZone    = 'UTC'
        }
    } | ConvertTo-Json -Depth 10 -Compress
    Invoke-ArmRequest -Method 'PUT' -Uri $schedUri -Body $schedBody | Out-Null

    $jobSchedId = New-DeterministicGuid -Value "$automationId|$($sched.RunbookName)|$($sched.ScheduleName)"
    $jobSchedUri = "https://management.azure.com${automationId}/jobSchedules/${jobSchedId}?api-version=2023-11-01"
    try { Invoke-ArmRequest -Method 'DELETE' -Uri $jobSchedUri } catch { }
    $jobSchedBody = @{
        properties = @{
            schedule   = @{ name = $sched.ScheduleName }
            runbook    = @{ name = $sched.RunbookName }
            parameters = $sched.Params
        }
    } | ConvertTo-Json -Depth 10 -Compress
    Invoke-ArmRequest -Method 'PUT' -Uri $jobSchedUri -Body $jobSchedBody | Out-Null
    Write-Host "    Schedule linked: $($sched.ScheduleName) -> $($sched.RunbookName)" -ForegroundColor Green
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6: Workbooks (optional)
# ══════════════════════════════════════════════════════════════════════════════

if ($CreateWorkbooks) {
    Write-Host "`n── Step 6: Workbooks ──────────────────────────────────────" -ForegroundColor Yellow
    Invoke-AzCli -Arguments @('account', 'set', '--subscription', $rgSubId) | Out-Null

    Deploy-Workbook -SubscriptionId $rgSubId -ResourceGroupName $ResGroup -Location $Location `
        -WorkbookFilePath (Join-Path $PSScriptRoot '..\monitor-workbooks\app-registration-expiration.workbook.json') `
        -DisplayName 'App Registration Credential Expiration' -Tags $Tags

    Deploy-Workbook -SubscriptionId $rgSubId -ResourceGroupName $ResGroup -Location $Location `
        -WorkbookFilePath (Join-Path $PSScriptRoot '..\monitor-workbooks\keyvault-credential-inventory.workbook.json') `
        -DisplayName 'Key Vault Credential Inventory' -Tags $Tags

    Deploy-Workbook -SubscriptionId $rgSubId -ResourceGroupName $ResGroup -Location $Location `
        -WorkbookFilePath (Join-Path $PSScriptRoot '..\monitor-workbooks\unified-credential-inventory.workbook.json') `
        -DisplayName 'Unified Credential Inventory' -Tags $Tags
} else {
    Write-Host "`n── Step 6: Workbooks (skipped — set createWorkbooks: true in config) ─" -ForegroundColor DarkGray
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 7: Azure Portal Dashboard
# ══════════════════════════════════════════════════════════════════════════════

Write-Host "`n── Step 7: Azure Portal Dashboard ─────────────────────────" -ForegroundColor Yellow
Invoke-AzCli -Arguments @('account', 'set', '--subscription', $rgSubId) | Out-Null

$dashboardFilePath = Join-Path $PSScriptRoot '..\monitor-azure-dashboards\azure-portal-dashboard.json'
if (Test-Path -LiteralPath $dashboardFilePath) {
    $dashboardName = $PortalDashboardName
    $dashboardResourceId = "/subscriptions/$rgSubId/resourceGroups/$ResGroup/providers/Microsoft.Portal/dashboards/$dashboardName"
    $dashboardJson = Get-Content -Path $dashboardFilePath -Raw
    $dashboardJson = $dashboardJson.Replace('__WORKSPACE_RESOURCE_ID__', $WorkspaceId)
    $dashboardJson = $dashboardJson.Replace('__WORKSPACE_SUBSCRIPTION_ID__', $wsParts.subscriptionId)
    $dashboardJson = $dashboardJson.Replace('__WORKSPACE_RESOURCE_GROUP__', $wsParts.resourceGroup)
    $dashboardJson = $dashboardJson.Replace('__WORKSPACE_NAME__', $wsParts.resourceName)
    $dashboardJson = $dashboardJson.Replace('__DASHBOARD_RESOURCE_ID__', $dashboardResourceId)
    $dashboardJson = $dashboardJson.Replace('__LOCATION__', $Location)

    # Inject tags
    if ($Tags.Count -gt 0) {
        $dashObj = $dashboardJson | ConvertFrom-Json
        foreach ($key in $Tags.Keys) { $dashObj.tags | Add-Member -NotePropertyName $key -NotePropertyValue $Tags[$key] -Force }
        $dashboardJson = $dashObj | ConvertTo-Json -Depth 30 -Compress
    }

    $dashUri = "https://management.azure.com${dashboardResourceId}?api-version=2020-09-01-preview"
    Invoke-ArmRequest -Method 'PUT' -Uri $dashUri -Body $dashboardJson | Out-Null
    Write-Host "    Dashboard deployed: $dashboardName (App Registration)" -ForegroundColor Green
} else {
    Write-Host "    AppReg dashboard JSON not found — skipping." -ForegroundColor DarkGray
}

# Key Vault portal dashboard
$kvDashboardFilePath = Join-Path $PSScriptRoot '..\monitor-azure-dashboards\keyvault-portal-dashboard.json'
if (Test-Path -LiteralPath $kvDashboardFilePath) {
    $kvDashName = "$PortalDashboardName-keyvault"
    $kvDashResourceId = "/subscriptions/$rgSubId/resourceGroups/$ResGroup/providers/Microsoft.Portal/dashboards/$kvDashName"
    $kvDashJson = Get-Content -Path $kvDashboardFilePath -Raw
    $kvDashJson = $kvDashJson.Replace('__WORKSPACE_RESOURCE_ID__', $WorkspaceId)
    $kvDashJson = $kvDashJson.Replace('__WORKSPACE_SUBSCRIPTION_ID__', $wsParts.subscriptionId)
    $kvDashJson = $kvDashJson.Replace('__WORKSPACE_RESOURCE_GROUP__', $wsParts.resourceGroup)
    $kvDashJson = $kvDashJson.Replace('__WORKSPACE_NAME__', $wsParts.resourceName)
    $kvDashJson = $kvDashJson.Replace('__DASHBOARD_RESOURCE_ID__', $kvDashResourceId)
    $kvDashJson = $kvDashJson.Replace('__LOCATION__', $Location)

    if ($Tags.Count -gt 0) {
        $kvDashObj = $kvDashJson | ConvertFrom-Json
        foreach ($key in $Tags.Keys) { $kvDashObj.tags | Add-Member -NotePropertyName $key -NotePropertyValue $Tags[$key] -Force }
        $kvDashJson = $kvDashObj | ConvertTo-Json -Depth 30 -Compress
    }

    $kvDashUri = "https://management.azure.com${kvDashResourceId}?api-version=2020-09-01-preview"
    Invoke-ArmRequest -Method 'PUT' -Uri $kvDashUri -Body $kvDashJson | Out-Null
    Write-Host "    Dashboard deployed: $kvDashName (Key Vault)" -ForegroundColor Green
} else {
    Write-Host "    KV dashboard JSON not found — skipping." -ForegroundColor DarkGray
}

# Unified combined portal dashboard
$unifiedDashboardFilePath = Join-Path $PSScriptRoot '..\monitor-azure-dashboards\unified-credential-inventory-dashboard.json'
if (Test-Path -LiteralPath $unifiedDashboardFilePath) {
    $unifiedDashName = "$PortalDashboardName-unified"
    $unifiedDashResourceId = "/subscriptions/$rgSubId/resourceGroups/$ResGroup/providers/Microsoft.Portal/dashboards/$unifiedDashName"
    $unifiedDashJson = Get-Content -Path $unifiedDashboardFilePath -Raw
    $unifiedDashJson = $unifiedDashJson.Replace('__WORKSPACE_RESOURCE_ID__', $WorkspaceId)
    $unifiedDashJson = $unifiedDashJson.Replace('__WORKSPACE_SUBSCRIPTION_ID__', $wsParts.subscriptionId)
    $unifiedDashJson = $unifiedDashJson.Replace('__WORKSPACE_RESOURCE_GROUP__', $wsParts.resourceGroup)
    $unifiedDashJson = $unifiedDashJson.Replace('__WORKSPACE_NAME__', $wsParts.resourceName)
    $unifiedDashJson = $unifiedDashJson.Replace('__DASHBOARD_RESOURCE_ID__', $unifiedDashResourceId)
    $unifiedDashJson = $unifiedDashJson.Replace('__LOCATION__', $Location)

    if ($Tags.Count -gt 0) {
        $unifiedDashObj = $unifiedDashJson | ConvertFrom-Json
        foreach ($key in $Tags.Keys) { $unifiedDashObj.tags | Add-Member -NotePropertyName $key -NotePropertyValue $Tags[$key] -Force }
        $unifiedDashJson = $unifiedDashObj | ConvertTo-Json -Depth 30 -Compress
    }

    $unifiedDashUri = "https://management.azure.com${unifiedDashResourceId}?api-version=2020-09-01-preview"
    Invoke-ArmRequest -Method 'PUT' -Uri $unifiedDashUri -Body $unifiedDashJson | Out-Null
    Write-Host "    Dashboard deployed: $unifiedDashName (Unified)" -ForegroundColor Green
} else {
    Write-Host "    Unified dashboard JSON not found — skipping." -ForegroundColor DarkGray
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 8: Azure Monitor Dashboards with Grafana
# ══════════════════════════════════════════════════════════════════════════════

Write-Host "`n── Step 8: Azure Monitor Dashboards with Grafana ─────────" -ForegroundColor Yellow
Invoke-AzCli -Arguments @('account', 'set', '--subscription', $rgSubId) | Out-Null

function Deploy-GrafanaDashboard {
    param(
        [string]$Name,
        [string]$FilePath,
        [string]$SubscriptionId,
        [string]$ResourceGroupName,
        [string]$Location,
        [string]$WorkspaceResourceId,
        [string]$WorkspaceSubscriptionId,
        [hashtable]$Tags = @{}
    )
    if (-not (Test-Path -LiteralPath $FilePath)) {
        Write-Host "    Grafana dashboard JSON not found: $FilePath — skipping." -ForegroundColor DarkGray
        return
    }
    $grafanaJson = Get-Content -Path $FilePath -Raw
    $grafanaJson = $grafanaJson.Replace('__WORKSPACE_RESOURCE_ID__', $WorkspaceResourceId)
    $grafanaJson = $grafanaJson.Replace('__WORKSPACE_SUB__', $WorkspaceSubscriptionId)

    $containerUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Dashboard/dashboards/${Name}?api-version=2025-09-01-preview"
    $containerBody = @{
        location   = $Location
        tags       = @{ GrafanaDashboardResourceType = 'Azure Monitor' }
        properties = @{}
    }
    foreach ($key in $Tags.Keys) { $containerBody.tags[$key] = $Tags[$key] }
    Invoke-ArmRequest -Method 'PUT' -Uri $containerUri -Body ($containerBody | ConvertTo-Json -Depth 10 -Compress) | Out-Null

    $defUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Dashboard/dashboards/${Name}/dashboardDefinitions/default?api-version=2025-09-01-preview"
    $defBody = @{
        properties = @{
            serializedData = $grafanaJson
        }
    } | ConvertTo-Json -Depth 10 -Compress
    Invoke-ArmRequest -Method 'PUT' -Uri $defUri -Body $defBody | Out-Null
    Write-Host "    Grafana dashboard deployed: $Name" -ForegroundColor Green
}

Deploy-GrafanaDashboard -Name $GrafanaAppRegDashName `
    -FilePath (Join-Path $PSScriptRoot '..\monitor-grafana-dashboards\grafana-appreg-expiry.json') `
    -SubscriptionId $rgSubId -ResourceGroupName $ResGroup -Location $Location `
    -WorkspaceResourceId $WorkspaceId -WorkspaceSubscriptionId $wsParts.subscriptionId -Tags $Tags

Deploy-GrafanaDashboard -Name $GrafanaKvDashName `
    -FilePath (Join-Path $PSScriptRoot '..\monitor-grafana-dashboards\grafana-keyvault-inventory.json') `
    -SubscriptionId $rgSubId -ResourceGroupName $ResGroup -Location $Location `
    -WorkspaceResourceId $WorkspaceId -WorkspaceSubscriptionId $wsParts.subscriptionId -Tags $Tags

Deploy-GrafanaDashboard -Name $GrafanaUnifiedDashName `
    -FilePath (Join-Path $PSScriptRoot '..\monitor-grafana-dashboards\grafana-unified-credential-inventory.json') `
    -SubscriptionId $rgSubId -ResourceGroupName $ResGroup -Location $Location `
    -WorkspaceResourceId $WorkspaceId -WorkspaceSubscriptionId $wsParts.subscriptionId -Tags $Tags

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════

Write-Host ''
Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Green
Write-Host '║                  Deployment Complete                        ║' -ForegroundColor Green
Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Green
Write-Host "  Resource Group:          $ResGroup"
Write-Host "  Workspace:               $WorkspaceId"
Write-Host "  AppReg DCR:              $($appRegDcr.Id)"
Write-Host "  AppReg DCR Immutable ID: $($appRegDcr.ImmutableId)"
Write-Host "  KV DCR:                  $($kvDcr.Id)"
Write-Host "  KV DCR Immutable ID:     $($kvDcr.ImmutableId)"
Write-Host "  Ingestion Endpoint:      $($appRegDcr.IngestionEndpoint)"
Write-Host "  Action Group:            $actionGroupId"
Write-Host "  Automation Account:      $automationId"
Write-Host "  Automation MI Principal:  $aaPrincipalId"
Write-Host "  Alerts:                  $($alerts.Count) scheduled query alerts"
Write-Host "  Runbooks:                Publish-CredentialInventory"
Write-Host "  Schedules:               Daily 06:00 UTC"
if ($CreateWorkbooks) { Write-Host "  Workbooks:               3 deployed (AppReg, KV, Unified)" }
Write-Host "  Grafana (AppReg):        $GrafanaAppRegDashName"
Write-Host "  Grafana (KV):            $GrafanaKvDashName"
Write-Host "  Grafana (Unified):       $GrafanaUnifiedDashName"
Write-Host ''
