# Azure Monitor Action Groups — Credential Expiration Monitoring

This folder contains **JSON definitions for Azure Monitor Action Groups** used by the credential expiration alert rules. Action Groups define who gets notified (email, SMS, webhook, etc.) when an alert fires.

## Action Group Definitions

| File | Default Name | Short Name | Description |
|------|-------------|------------|-------------|
| `ag-credential-inventory.json` | ag-credential-inventory | CredInv | Primary action group for all credential expiration alerts. Sends email notifications to specified recipients. |

## JSON Schema

Each action group JSON file contains:

```json
{
  "name": "ag-credential-inventory",
  "shortName": "CredInv",
  "enabled": true,
  "emailReceivers": [
    {
      "name": "PrimaryEmail",
      "emailAddress": "ops@contoso.com",
      "useCommonAlertSchema": true
    }
  ],
  "smsReceivers": [],
  "webhookReceivers": [],
  "armRoleReceivers": [],
  "azureAppPushReceivers": [],
  "automationRunbookReceivers": [],
  "voiceReceivers": [],
  "logicAppReceivers": [],
  "azureFunctionReceivers": [],
  "eventHubReceivers": []
}
```

| Field | Description |
|-------|-------------|
| `name` | Action group resource name in Azure (must be unique per resource group). Overridden by `actionGroupName` in `deploy-config.yaml` if set. |
| `shortName` | Display name (max 12 characters) shown in SMS/push notifications. |
| `enabled` | `true` = active, `false` = paused (all notifications suppressed). |
| `emailReceivers` | Array of email recipients. Each entry has `name` (unique label), `emailAddress`, and `useCommonAlertSchema` (standardized email format). |
| `smsReceivers` | Array of SMS recipients with `name`, `countryCode`, and `phoneNumber`. |
| `webhookReceivers` | Array of webhook endpoints with `name`, `serviceUri`, and optional `useCommonAlertSchema`. |
| `armRoleReceivers` | Notify Azure RBAC role holders (e.g., `Owner`, `Contributor`) with `name` and `roleId`. |
| `azureAppPushReceivers` | Push notifications to the Azure mobile app with `name` and `emailAddress`. |
| `automationRunbookReceivers` | Trigger Azure Automation runbooks when an alert fires. |
| `voiceReceivers` | Voice call recipients with `name`, `countryCode`, and `phoneNumber`. |
| `logicAppReceivers` | Trigger Azure Logic Apps as a notification or remediation action. |
| `azureFunctionReceivers` | Trigger Azure Functions when an alert fires. |
| `eventHubReceivers` | Send alert payloads to Event Hubs for downstream processing. |

> **Note:** Email addresses in the JSON are populated at deployment time from `deploy-config.yaml` `emailAddresses` list. Leave `emailAddress` blank in the JSON template — the deploy script fills it in.

## Deployment

### Option 1: Automated via Deploy-Solution.ps1 (recommended)

The deploy script reads `monitor-action-groups/*.json`, overlays email addresses from `deploy-config.yaml`, and creates the action group:

```powershell
.\Deploy-Solution.ps1 -ConfigFile '.\deploy-config.yaml'
```

The script:
1. Reads the first `*.json` file from `monitor-action-groups/`
2. Overrides `name` with `actionGroupName` from config (if set)
3. Populates `emailReceivers` from the `emailAddresses` config list
4. Creates the action group via `az monitor action-group create`
5. Skips creation if an action group with that name already exists

### Option 2: Azure CLI (manual)

#### Create an action group with email receivers

```powershell
# Variables
$resourceGroup = "rg-credential-inventory"
$actionGroupName = "ag-credential-inventory"

# Create with one email receiver
az monitor action-group create `
    --name $actionGroupName `
    --resource-group $resourceGroup `
    --short-name "CredInv" `
    --action email PrimaryEmail ops@contoso.com

# Create with multiple email receivers
az monitor action-group create `
    --name $actionGroupName `
    --resource-group $resourceGroup `
    --short-name "CredInv" `
    --action email PrimaryEmail ops@contoso.com `
    --action email SecondaryEmail security@contoso.com
```

#### Create with additional receiver types

```powershell
# Email + SMS
az monitor action-group create `
    --name $actionGroupName `
    --resource-group $resourceGroup `
    --short-name "CredInv" `
    --action email PrimaryEmail ops@contoso.com `
    --action sms OnCall 1 5551234567

# Email + Webhook
az monitor action-group create `
    --name $actionGroupName `
    --resource-group $resourceGroup `
    --short-name "CredInv" `
    --action email PrimaryEmail ops@contoso.com `
    --action webhook TeamsWebhook "https://outlook.office.com/webhook/..."
```

#### Update an existing action group (add a receiver)

```powershell
az monitor action-group update `
    --name $actionGroupName `
    --resource-group $resourceGroup `
    --add-action email NewRecipient newperson@contoso.com
```

#### Enable / Disable an action group

```powershell
# Disable (suppress all notifications)
az monitor action-group update `
    --name $actionGroupName `
    --resource-group $resourceGroup `
    --set enabled=false

# Re-enable
az monitor action-group update `
    --name $actionGroupName `
    --resource-group $resourceGroup `
    --set enabled=true
```

#### Show / List / Delete

```powershell
# Show details
az monitor action-group show `
    --name $actionGroupName `
    --resource-group $resourceGroup

# List all action groups in a resource group
az monitor action-group list `
    --resource-group $resourceGroup `
    -o table

# Delete
az monitor action-group delete `
    --name $actionGroupName `
    --resource-group $resourceGroup
```

### Option 3: Azure Portal (manual)

1. Navigate to **Azure Monitor** > **Alerts** > **Action groups**
2. Click **+ Create**
3. Fill in:
   - **Subscription** and **Resource group**
   - **Action group name**: `ag-credential-inventory`
   - **Display name**: `CredInv`
4. On the **Notifications** tab, add:
   - **Notification type**: Email/SMS message/Push/Voice
   - **Name**: `PrimaryEmail`
   - Enter the email address and click **OK**
5. (Optional) On the **Actions** tab, add webhook, Logic App, or other action types
6. Click **Review + create** > **Create**

#### Managing via Portal

- **View**: Azure Monitor > Alerts > Action groups > click the action group name
- **Edit**: Click the action group > modify receivers > **Save**
- **Disable/Enable**: Click the action group > toggle **Enabled** status
- **Delete**: Click the action group > **Delete** > confirm
- **Test**: Click **Test action group** > select an alert type > **Test** (sends a test notification)

## Customization

### Adding receiver types

Edit the JSON file to add receivers before deployment. Examples:

**SMS receiver:**
```json
"smsReceivers": [
  {
    "name": "OnCallSMS",
    "countryCode": "1",
    "phoneNumber": "5551234567"
  }
]
```

**Webhook receiver (e.g., Teams, Slack, PagerDuty):**
```json
"webhookReceivers": [
  {
    "name": "TeamsChannel",
    "serviceUri": "https://outlook.office.com/webhook/...",
    "useCommonAlertSchema": true
  }
]
```

**Azure RBAC role receiver (notify all Owners):**
```json
"armRoleReceivers": [
  {
    "name": "NotifyOwners",
    "roleId": "8e3af657-a8ff-443c-a75c-2fe8c4bcb635",
    "useCommonAlertSchema": true
  }
]
```

### Multiple action groups

Create additional JSON files in `monitor-action-groups/` for different notification targets (e.g., `ag-security-team.json`, `ag-ops-oncall.json`). The deploy script creates all action groups found in the folder. To assign specific action groups to specific alerts, update the alert JSON files' action group references.

### Common Alert Schema

Setting `useCommonAlertSchema: true` on receivers standardizes the notification payload across all alert types. This is recommended for webhook and Logic App receivers that programmatically process alert payloads.
