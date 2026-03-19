# Azure Monitor Alerts — Credential Expiration Monitoring

This folder contains **10 preconfigured Azure Monitor log search alert definitions** that notify you when App Registration, Enterprise App, and Key Vault credentials are expiring within 30 days.

## Alert Types

### Per-Item Alerts (dimension-split — one alert per expiring object)

These alerts use **dimension splitting** so each unique credential/item fires its own alert. The email notification includes the specific object details (name, ID, days remaining).

| File | Scope | Credential Type | Dimensions |
|------|-------|-----------------|------------|
| `alert-appreg-cert-per-item.json` | App Registrations | Certificate | ApplicationDisplayName, CredentialType, DaysToExpiry, ApplicationId, CredentialKeyId |
| `alert-appreg-secret-per-item.json` | App Registrations | Secret | ApplicationDisplayName, CredentialType, DaysToExpiry, ApplicationId, CredentialKeyId |
| `alert-enterpriseapp-cert-per-item.json` | Enterprise Apps | Certificate | ApplicationDisplayName, CredentialType, DaysToExpiry, ApplicationId, CredentialKeyId |
| `alert-keyvault-cert-per-item.json` | Key Vaults | Certificate | VaultName, ItemName, ItemType, DaysToExpiry |
| `alert-keyvault-secret-per-item.json` | Key Vaults | Secret | VaultName, ItemName, ItemType, DaysToExpiry |

### Summary Alerts (one alert with a table of all affected items)

These alerts fire **once** when any matching items exist. The notification includes a results table with up to 100 rows of affected items.

| File | Scope | Credential Type |
|------|-------|-----------------|
| `alert-appreg-cert-summary.json` | App Registrations | Certificate |
| `alert-appreg-secret-summary.json` | App Registrations | Secret |
| `alert-enterpriseapp-cert-summary.json` | Enterprise Apps | Certificate |
| `alert-keyvault-cert-summary.json` | Key Vaults | Certificate |
| `alert-keyvault-secret-summary.json` | Key Vaults | Secret |

## JSON Schema

Each alert definition JSON file contains:

```json
{
  "name": "alert-appreg-cert-per-item",
  "displayName": "Expiring Certificate — App Registration",
  "description": "Human-readable description shown in the alert email.",
  "severity": 2,
  "evaluationFrequency": "PT24H",
  "windowSize": "PT24H",
  "autoMitigate": false,
  "query": "KQL query that returns detail rows",
  "dimensions": [
    { "name": "ColumnName", "operator": "Include", "values": ["*"] }
  ],
  "customProperties": {
    "AlertCategory": "Credential Expiration",
    "CredentialStore": "App Registration",
    "CredentialType": "Certificate",
    "MonitoringSolution": "Credential Inventory"
  },
  "conditionOperator": "GreaterThan",
  "conditionThreshold": 0,
  "conditionMeasure": "count"
}
```

| Field | Description |
|-------|-------------|
| `name` | Alert rule name in Azure (must be unique per resource group). |
| `displayName` | **Dynamic email subject prefix.** Azure Monitor uses this as the alert display name in email subjects. Per-item alerts append dimension values (app name, credential type, days remaining) to produce subjects like: `Azure: Warning Expiring Certificate — App Registration ApplicationDisplayName=MyApp DaysToExpiry=7`. Summary alerts use the display name as-is. |
| `description` | Displayed in Azure portal and email notifications. |
| `severity` | 0 = Critical, 1 = Error, 2 = Warning, 3 = Informational, 4 = Verbose. Per-item alerts default to **2** (Warning); summary alerts default to **3** (Informational). |
| `evaluationFrequency` | How often the rule runs. ISO 8601 duration (e.g., `PT24H` = daily). |
| `windowSize` | Time range of data the query looks at. Must be ≥ evaluationFrequency. |
| `autoMitigate` | `false` = alert stays active until manually resolved. `true` = auto-resolves when condition clears. |
| `query` | KQL query. Per-item queries `project` detail columns. Summary queries `sort by DaysToExpiry`. |
| `dimensions` | Array of columns to split on. Empty array `[]` = single aggregated alert. Per-item alerts include human-readable columns (e.g., `ApplicationDisplayName`, `DaysToExpiry`) so their values appear in the email subject. |
| `customProperties` | Key-value pairs included in the alert payload and email body. Used for routing, categorization, and providing extra context (e.g., `AlertCategory`, `CredentialStore`, `CredentialType`). |
| `conditionOperator` | Comparison operator: `GreaterThan`, `LessThan`, `Equal`. |
| `conditionThreshold` | Numeric threshold. `0` with `GreaterThan` means "fire when any rows returned". |

## Deployment

### Option 1: Automated via Deploy-Solution.ps1 (recommended)

The deploy script automatically discovers all `*.json` files in `monitor-alerts/` and creates the corresponding Azure Monitor scheduled query rules.

```powershell
# From the scripts/ directory
.\Deploy-Solution.ps1 -ConfigFile '.\deploy-config.yaml'
```

The script:
1. Creates an Action Group with the email addresses from `deploy-config.yaml`
2. Reads each JSON file from `monitor-alerts/`
3. Creates each alert rule via the ARM REST API (supports dimension splitting)
4. Skips alerts that already exist

### Option 2: Azure CLI (manual, per alert)

For alerts **without** dimensions (summary alerts), you can use `az monitor scheduled-query`:

```powershell
# Set variables
$resourceGroup = "rg-credential-inventory"
$workspaceId = "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<ws-name>"
$actionGroupId = "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Insights/actionGroups/ag-credential-inventory"

# Create a summary alert
az monitor scheduled-query create `
    --name "alert-appreg-cert-summary" `
    --resource-group $resourceGroup `
    --scopes $workspaceId `
    --condition "count 'GreaterThan' 0" `
    --condition-query "AppRegistrationCredentialExpiry_CL | summarize arg_max(TimeGenerated, *) by ApplicationId, CredentialKeyId | where CredentialType == 'Certificate' and ObjectType == 'AppRegistration' and DaysToExpiry >= 0 and DaysToExpiry < 30 | project ApplicationDisplayName, ApplicationId, CredentialDisplayName, CredentialKeyId, DaysToExpiry, EndDateUtc, ExpiryBand | sort by DaysToExpiry asc" `
    --description "Table of all App Registration certificates expiring within 30 days." `
    --evaluation-frequency "24h" `
    --window-size "24h" `
    --severity 3 `
    --action-groups $actionGroupId `
    --auto-mitigate false
```

> **Note:** `az monitor scheduled-query create` does not support `--dimensions` for splitting. For per-item (dimension-split) alerts, use the ARM REST API or the Azure Portal.

### Option 3: ARM REST API (supports dimensions)

```powershell
$token = (az account get-access-token --resource-type arm --query accessToken -o tsv)
$alertName = "alert-appreg-cert-per-item"
$subscriptionId = "<sub-id>"
$resourceGroup = "rg-credential-inventory"

$uri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Insights/scheduledQueryRules/${alertName}?api-version=2023-03-15-preview"

$body = @{
    location = "centralus"
    properties = @{
        description = "Fires one alert per App Registration certificate expiring within 30 days."
        severity = 2
        enabled = $true
        evaluationFrequency = "PT24H"
        windowSize = "PT24H"
        scopes = @("<workspace-resource-id>")
        autoMitigate = $false
        criteria = @{
            allOf = @(
                @{
                    query = "AppRegistrationCredentialExpiry_CL | summarize arg_max(TimeGenerated, *) by ApplicationId, CredentialKeyId | where CredentialType == 'Certificate' and ObjectType == 'AppRegistration' and DaysToExpiry >= 0 and DaysToExpiry < 30 | project ApplicationDisplayName, ApplicationId, CredentialDisplayName, CredentialKeyId, DaysToExpiry, EndDateUtc, ExpiryBand, ObjectType, CredentialType"
                    timeAggregation = "Count"
                    operator = "GreaterThan"
                    threshold = 0
                    dimensions = @(
                        @{ name = "ApplicationId"; operator = "Include"; values = @("*") }
                        @{ name = "CredentialKeyId"; operator = "Include"; values = @("*") }
                    )
                    failingPeriods = @{
                        numberOfEvaluationPeriods = 1
                        minFailingPeriodsToAlert = 1
                    }
                }
            )
        }
        actions = @{
            actionGroups = @("<action-group-resource-id>")
        }
    }
} | ConvertTo-Json -Depth 15

Invoke-RestMethod -Method Put -Uri $uri `
    -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } `
    -Body $body
```

### Option 4: Azure Portal (manual)

1. Navigate to **Azure Monitor** > **Alerts** > **+ Create** > **Alert rule**
2. **Scope**: Select your Log Analytics workspace
3. **Condition**: Choose **Custom log search**
4. Paste the KQL query from the JSON file
5. Set **Measure** = `Table rows`, **Aggregation type** = `Count`
6. **Operator** = `Greater than`, **Threshold** = `0`
7. For per-item alerts: Click **Split by dimensions** and add the dimension columns (e.g., `ApplicationId`, `CredentialKeyId`)
8. **Evaluation**: Period = `24 hours`, Frequency = `24 hours`
9. **Actions**: Select your Action Group
10. **Details**: Enter the alert name and description from the JSON file
11. Set **Severity** as specified (2 = Warning for per-item, 3 = Informational for summary)
12. Set **Automatically resolve alerts** = unchecked (matches `autoMitigate: false`)
13. Click **Create**

## Managing Alerts

### List all alert rules

```powershell
az monitor scheduled-query list --resource-group "rg-credential-inventory" -o table
```

### Disable an alert

```powershell
az monitor scheduled-query update `
    --name "alert-appreg-cert-per-item" `
    --resource-group "rg-credential-inventory" `
    --disabled
```

### Enable an alert

```powershell
az monitor scheduled-query update `
    --name "alert-appreg-cert-per-item" `
    --resource-group "rg-credential-inventory" `
    --disabled false
```

### Delete an alert

```powershell
az monitor scheduled-query delete `
    --name "alert-appreg-cert-per-item" `
    --resource-group "rg-credential-inventory" `
    --yes
```

### Delete all alerts in the solution

```powershell
$rg = "rg-credential-inventory"
$alerts = az monitor scheduled-query list --resource-group $rg --query "[].name" -o tsv
foreach ($name in $alerts) {
    az monitor scheduled-query delete --name $name --resource-group $rg --yes
    Write-Host "Deleted: $name"
}
```

## Customization

### Change the expiry threshold

Edit the KQL `where` clause in any JSON file. For example, to alert at 60 days instead of 30:

```diff
- | where CredentialType == 'Certificate' and ObjectType == 'AppRegistration' and DaysToExpiry >= 0 and DaysToExpiry < 30
+ | where CredentialType == 'Certificate' and ObjectType == 'AppRegistration' and DaysToExpiry >= 0 and DaysToExpiry < 60
```

### Change severity

Edit the `severity` field: `0` = Critical, `1` = Error, `2` = Warning, `3` = Informational.

### Change evaluation frequency

Edit `evaluationFrequency` and `windowSize`. Common values:
- `PT1H` — hourly
- `PT6H` — every 6 hours
- `PT24H` — daily (default)

### Add a new alert

1. Create a new JSON file in `monitor-alerts/` following the schema above
2. Run `Deploy-Solution.ps1` — the script auto-discovers new files

### Selective deployment

To deploy only specific alerts, move unwanted JSON files out of `monitor-alerts/` before running the deploy script, or create alerts individually using the CLI/ARM examples above.

## How Dimension Splitting Works

When `dimensions` is non-empty, Azure Monitor evaluates the query and groups results by the dimension columns. Each unique combination becomes a **separate alert instance** with its own lifecycle (fire, resolve, suppress).

**Example:** If 3 App Registration certificates are expiring, the per-item alert fires 3 separate alerts — each email contains one certificate's details (ApplicationDisplayName, ApplicationId, CredentialKeyId, DaysToExpiry, etc.) in the dimension values.

**Limits:**
- Maximum **1,000 dimension combinations** per evaluation
- Dimension values appear in the alert email subject and body automatically
- Each fired alert counts separately toward Azure Monitor alert quotas

## Cost Considerations

- Azure Monitor log search alert rules are billed per evaluation
- 10 rules evaluated daily = 10 evaluations/day = ~300 evaluations/month
- See [Azure Monitor pricing](https://azure.microsoft.com/pricing/details/monitor/) for current rates
- Per-item alerts with many expiring items generate more alert instances but do **not** increase evaluation cost (the query runs once, dimensions split the results)
