<#
.SYNOPSIS
    Unified credential inventory collector for App Registrations, Enterprise Apps,
    and Key Vault items. Publishes to Azure Monitor Logs via the DCR-based
    Logs Ingestion API.

.DESCRIPTION
    Collects three categories of credential metadata:
      1. App Registration secrets and certificates (Microsoft Graph /applications)
      2. Enterprise Application certificates (Microsoft Graph /servicePrincipals,
         filtered to servicePrincipalType eq 'Application')
      3. Key Vault certificates, keys, and secrets across multiple subscriptions

    Each category is published to its own DCR/stream. App Registration and
    Enterprise App data share a single DCR; Key Vault data goes to a separate DCR.

.PARAMETER TenantId
    Azure AD tenant ID.

.PARAMETER LogIngestionEndpoint
    Data Collection Endpoint (DCE) URI for the App Registration DCR.

.PARAMETER DcrImmutableId
    Immutable ID of the App Registration Data Collection Rule.

.PARAMETER StreamName
    Custom stream name for App Reg data. Defaults to 'Custom-AppRegistrationCredentialExpiry'.

.PARAMETER KvLogIngestionEndpoint
    Data Collection Endpoint (DCE) URI for the Key Vault DCR. If omitted, Key Vault
    collection is skipped.

.PARAMETER KvDcrImmutableId
    Immutable ID of the Key Vault Data Collection Rule. If omitted, Key Vault
    collection is skipped.

.PARAMETER KvStreamName
    Custom stream name for Key Vault data. Defaults to 'Custom-KeyVaultCredentialInventory'.

.PARAMETER SubscriptionIds
    Array of subscription IDs to scan for Key Vaults. If omitted, all enabled
    subscriptions in the tenant are discovered automatically.

.PARAMETER ChunkSize
    Number of records per ingestion POST. Defaults to 250.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$TenantId,
    [Parameter(Mandatory = $true)]
    [string]$LogIngestionEndpoint,
    [Parameter(Mandatory = $true)]
    [string]$DcrImmutableId,
    [string]$StreamName = 'Custom-AppRegistrationCredentialExpiry',
    [string]$KvLogIngestionEndpoint,
    [string]$KvDcrImmutableId,
    [string]$KvStreamName = 'Custom-KeyVaultCredentialInventory',
    [string[]]$SubscriptionIds = @(),
    [int]$ChunkSize = 250
)

$ErrorActionPreference = 'Stop'

# ── Auto-discover subscriptions if none supplied ─────────────────────────────
if ($SubscriptionIds.Count -eq 0) {
    Write-Output 'No SubscriptionIds provided — discovering all enabled subscriptions...'
    $SubscriptionIds = (Get-AzSubscription -TenantId $TenantId | Where-Object { $_.State -eq 'Enabled' }).Id
    Write-Output "  Found $($SubscriptionIds.Count) enabled subscription(s)."
    if ($SubscriptionIds.Count -eq 0) {
        throw 'No enabled subscriptions found in tenant. Provide -SubscriptionIds explicitly.'
    }
}

# ── Helpers ──────────────────────────────────────────────────────────────────

function Get-ExpiryBand {
    param([int]$DaysToExpiry)
    if ($DaysToExpiry -lt 0)  { return 'Expired' }
    if ($DaysToExpiry -lt 30) { return 'Red' }
    if ($DaysToExpiry -le 90) { return 'Yellow' }
    return 'Green'
}

function Get-DaysToExpiry {
    param([string]$ExpiresOn)
    if ([string]::IsNullOrWhiteSpace($ExpiresOn)) { return $null }
    $endDate = [datetime]$ExpiresOn
    return [int][math]::Floor(($endDate.ToUniversalTime() - [datetime]::UtcNow).TotalDays)
}

function Send-ToLogAnalytics {
    param(
        [object[]]$Records,
        [string]$Endpoint,
        [string]$DcrId,
        [string]$Stream,
        [string]$Token,
        [int]$Chunk
    )
    for ($i = 0; $i -lt $Records.Count; $i += $Chunk) {
        $upper = [math]::Min($i + $Chunk - 1, $Records.Count - 1)
        $body  = $Records[$i..$upper] | ConvertTo-Json -Depth 6
        Invoke-RestMethod -Method Post `
            -Uri "${Endpoint}/dataCollectionRules/${DcrId}/streams/${Stream}?api-version=2023-01-01" `
            -Headers @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' } `
            -Body $body | Out-Null
    }
}

# ── Authenticate ─────────────────────────────────────────────────────────────
Connect-AzAccount -Identity | Out-Null

$graphToken   = (Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com').Token
$monitorToken = (Get-AzAccessToken -ResourceUrl 'https://monitor.azure.com/').Token

$runId     = [guid]::NewGuid().ToString()
$collector = 'Runbook-CredentialInventory'
$nowUtc    = [datetime]::UtcNow.ToString('o')

# ══════════════════════════════════════════════════════════════════════════════
# PART 1 — App Registrations (secrets + certificates + no-credentials)
# ══════════════════════════════════════════════════════════════════════════════
Write-Output '── Collecting App Registration credentials ──'

$appRegRecords = New-Object System.Collections.Generic.List[object]
$uri = 'https://graph.microsoft.com/v1.0/applications?$select=id,appId,displayName,passwordCredentials,keyCredentials'

do {
    $response = Invoke-RestMethod -Method Get -Uri $uri -Headers @{ Authorization = "Bearer $graphToken" }

    foreach ($app in $response.value) {
        foreach ($secret in @($app.passwordCredentials)) {
            $endDate = [datetime]$secret.endDateTime
            $days    = [int][math]::Floor(($endDate.ToUniversalTime() - [datetime]::UtcNow).TotalDays)
            $appRegRecords.Add([pscustomobject]@{
                TimeGenerated          = $nowUtc
                TenantId               = $TenantId
                ApplicationObjectId    = $app.id
                ApplicationId          = $app.appId
                ApplicationDisplayName = $app.displayName
                CredentialType         = 'Secret'
                CredentialDisplayName  = $secret.displayName
                CredentialKeyId        = $secret.keyId
                StartDateUtc           = ([datetime]$secret.startDateTime).ToUniversalTime().ToString('o')
                EndDateUtc             = $endDate.ToUniversalTime().ToString('o')
                DaysToExpiry           = $days
                ExpiryBand             = (Get-ExpiryBand -DaysToExpiry $days)
                ExpiryColor            = (Get-ExpiryBand -DaysToExpiry $days)
                IsExpired              = ($days -lt 0)
                CollectionRunId        = $runId
                Collector              = $collector
                ObjectType             = 'AppRegistration'
            })
        }

        foreach ($cert in @($app.keyCredentials)) {
            $endDate = [datetime]$cert.endDateTime
            $days    = [int][math]::Floor(($endDate.ToUniversalTime() - [datetime]::UtcNow).TotalDays)
            $appRegRecords.Add([pscustomobject]@{
                TimeGenerated          = $nowUtc
                TenantId               = $TenantId
                ApplicationObjectId    = $app.id
                ApplicationId          = $app.appId
                ApplicationDisplayName = $app.displayName
                CredentialType         = 'Certificate'
                CredentialDisplayName  = $cert.displayName
                CredentialKeyId        = $cert.keyId
                StartDateUtc           = ([datetime]$cert.startDateTime).ToUniversalTime().ToString('o')
                EndDateUtc             = $endDate.ToUniversalTime().ToString('o')
                DaysToExpiry           = $days
                ExpiryBand             = (Get-ExpiryBand -DaysToExpiry $days)
                ExpiryColor            = (Get-ExpiryBand -DaysToExpiry $days)
                IsExpired              = ($days -lt 0)
                CollectionRunId        = $runId
                Collector              = $collector
                ObjectType             = 'AppRegistration'
            })
        }

        $hasSecrets = $app.passwordCredentials -and $app.passwordCredentials.Count -gt 0
        $hasCerts   = $app.keyCredentials -and $app.keyCredentials.Count -gt 0
        if (-not $hasSecrets -and -not $hasCerts) {
            $appRegRecords.Add([pscustomobject]@{
                TimeGenerated          = $nowUtc
                TenantId               = $TenantId
                ApplicationObjectId    = $app.id
                ApplicationId          = $app.appId
                ApplicationDisplayName = $app.displayName
                CredentialType         = 'None'
                CredentialDisplayName  = ''
                CredentialKeyId        = $app.appId
                StartDateUtc           = $nowUtc
                EndDateUtc             = $nowUtc
                DaysToExpiry           = [int]0
                ExpiryBand             = 'None'
                ExpiryColor            = 'None'
                IsExpired              = $false
                CollectionRunId        = $runId
                Collector              = $collector
                ObjectType             = 'AppRegistration'
            })
        }
    }

    $uri = $response.'@odata.nextLink'
} while ($uri)

# ══════════════════════════════════════════════════════════════════════════════
# PART 2 — Enterprise Applications (certificates only, Application type only)
# ══════════════════════════════════════════════════════════════════════════════
Write-Output '── Collecting Enterprise Application certificates ──'

$uri = "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=servicePrincipalType eq 'Application'&`$select=id,appId,displayName,keyCredentials&`$top=999"

do {
    $response = Invoke-RestMethod -Method Get -Uri $uri -Headers @{ Authorization = "Bearer $graphToken" }

    foreach ($sp in $response.value) {
        foreach ($cert in @($sp.keyCredentials)) {
            $endDate = [datetime]$cert.endDateTime
            $days    = [int][math]::Floor(($endDate.ToUniversalTime() - [datetime]::UtcNow).TotalDays)
            $appRegRecords.Add([pscustomobject]@{
                TimeGenerated          = $nowUtc
                TenantId               = $TenantId
                ApplicationObjectId    = $sp.id
                ApplicationId          = $sp.appId
                ApplicationDisplayName = $sp.displayName
                CredentialType         = 'Certificate'
                CredentialDisplayName  = $cert.displayName
                CredentialKeyId        = $cert.keyId
                StartDateUtc           = ([datetime]$cert.startDateTime).ToUniversalTime().ToString('o')
                EndDateUtc             = $endDate.ToUniversalTime().ToString('o')
                DaysToExpiry           = $days
                ExpiryBand             = (Get-ExpiryBand -DaysToExpiry $days)
                ExpiryColor            = (Get-ExpiryBand -DaysToExpiry $days)
                IsExpired              = ($days -lt 0)
                CollectionRunId        = $runId
                Collector              = $collector
                ObjectType             = 'EnterpriseApp'
            })
        }
    }

    $uri = $response.'@odata.nextLink'
} while ($uri)

# Upload App Reg + Enterprise App data
$appRegPayload = $appRegRecords | Sort-Object DaysToExpiry, ApplicationDisplayName
Write-Output "Collected $($appRegPayload.Count) App Reg / Enterprise App records. Uploading..."
Send-ToLogAnalytics -Records $appRegPayload -Endpoint $LogIngestionEndpoint `
    -DcrId $DcrImmutableId -Stream $StreamName -Token $monitorToken -Chunk $ChunkSize
Write-Output "Uploaded $($appRegPayload.Count) records to AppRegistrationCredentialExpiry_CL."

# ══════════════════════════════════════════════════════════════════════════════
# PART 3 — Key Vault Inventory (certificates, keys, secrets)
# ══════════════════════════════════════════════════════════════════════════════
if (-not $KvLogIngestionEndpoint -or -not $KvDcrImmutableId) {
    Write-Output 'Key Vault DCR parameters not provided — skipping Key Vault collection.'
    return
}

Write-Output '── Collecting Key Vault inventory ──'

$kvRecords = New-Object System.Collections.Generic.List[object]

foreach ($subId in $SubscriptionIds) {
    Write-Output "  Scanning subscription $subId ..."
    Set-AzContext -SubscriptionId $subId -ErrorAction SilentlyContinue | Out-Null

    $keyVaults = Get-AzKeyVault -ErrorAction SilentlyContinue
    if (-not $keyVaults) {
        Write-Output "    No Key Vaults found."
        continue
    }

    foreach ($kv in $keyVaults) {
        $vaultName = $kv.VaultName
        $rgName    = $kv.ResourceGroupName
        Write-Output "    Vault: $vaultName ($rgName)"

        # ── Certificates ─────────────────────────────────────────────────
        try {
            $certs = Get-AzKeyVaultCertificate -VaultName $vaultName -ErrorAction Stop
            foreach ($cert in $certs) {
                $daysToExpiry = Get-DaysToExpiry -ExpiresOn $cert.Expires
                $kvRecords.Add([pscustomobject]@{
                    TimeGenerated    = $nowUtc
                    TenantId         = $TenantId
                    SubscriptionId   = $subId
                    ResourceGroup    = $rgName
                    VaultName        = $vaultName
                    ItemType         = 'Certificate'
                    ItemName         = $cert.Name
                    Enabled          = [bool]$cert.Enabled
                    CreatedOn        = if ($cert.Created)  { $cert.Created.ToUniversalTime().ToString('o') }  else { '' }
                    ExpiresOn        = if ($cert.Expires)   { $cert.Expires.ToUniversalTime().ToString('o') }   else { '' }
                    NotBefore        = if ($cert.NotBefore) { $cert.NotBefore.ToUniversalTime().ToString('o') } else { '' }
                    DaysToExpiry     = if ($null -ne $daysToExpiry) { $daysToExpiry } else { [int]-9999 }
                    HasExpiration    = ($null -ne $daysToExpiry)
                    ExpiryBand       = if ($null -ne $daysToExpiry) { Get-ExpiryBand -DaysToExpiry $daysToExpiry } else { 'NoExpiry' }
                    IsExpired        = if ($null -ne $daysToExpiry) { $daysToExpiry -lt 0 } else { $false }
                    CollectionRunId  = $runId
                    Collector        = $collector
                })
            }
        }
        catch {
            Write-Warning "      Could not read certificates from $vaultName — $($_.Exception.Message)"
        }

        # ── Keys ─────────────────────────────────────────────────────────
        try {
            $keys = Get-AzKeyVaultKey -VaultName $vaultName -ErrorAction Stop
            foreach ($key in $keys) {
                $daysToExpiry = Get-DaysToExpiry -ExpiresOn $key.Expires
                $kvRecords.Add([pscustomobject]@{
                    TimeGenerated    = $nowUtc
                    TenantId         = $TenantId
                    SubscriptionId   = $subId
                    ResourceGroup    = $rgName
                    VaultName        = $vaultName
                    ItemType         = 'Key'
                    ItemName         = $key.Name
                    Enabled          = [bool]$key.Enabled
                    CreatedOn        = if ($key.Created)  { $key.Created.ToUniversalTime().ToString('o') }  else { '' }
                    ExpiresOn        = if ($key.Expires)   { $key.Expires.ToUniversalTime().ToString('o') }   else { '' }
                    NotBefore        = if ($key.NotBefore) { $key.NotBefore.ToUniversalTime().ToString('o') } else { '' }
                    DaysToExpiry     = if ($null -ne $daysToExpiry) { $daysToExpiry } else { [int]-9999 }
                    HasExpiration    = ($null -ne $daysToExpiry)
                    ExpiryBand       = if ($null -ne $daysToExpiry) { Get-ExpiryBand -DaysToExpiry $daysToExpiry } else { 'NoExpiry' }
                    IsExpired        = if ($null -ne $daysToExpiry) { $daysToExpiry -lt 0 } else { $false }
                    CollectionRunId  = $runId
                    Collector        = $collector
                })
            }
        }
        catch {
            Write-Warning "      Could not read keys from $vaultName — $($_.Exception.Message)"
        }

        # ── Secrets ──────────────────────────────────────────────────────
        try {
            $secrets = Get-AzKeyVaultSecret -VaultName $vaultName -ErrorAction Stop
            foreach ($secret in $secrets) {
                $daysToExpiry = Get-DaysToExpiry -ExpiresOn $secret.Expires
                $kvRecords.Add([pscustomobject]@{
                    TimeGenerated    = $nowUtc
                    TenantId         = $TenantId
                    SubscriptionId   = $subId
                    ResourceGroup    = $rgName
                    VaultName        = $vaultName
                    ItemType         = 'Secret'
                    ItemName         = $secret.Name
                    Enabled          = [bool]$secret.Enabled
                    CreatedOn        = if ($secret.Created)  { $secret.Created.ToUniversalTime().ToString('o') }  else { '' }
                    ExpiresOn        = if ($secret.Expires)   { $secret.Expires.ToUniversalTime().ToString('o') }   else { '' }
                    NotBefore        = if ($secret.NotBefore) { $secret.NotBefore.ToUniversalTime().ToString('o') } else { '' }
                    DaysToExpiry     = if ($null -ne $daysToExpiry) { $daysToExpiry } else { [int]-9999 }
                    HasExpiration    = ($null -ne $daysToExpiry)
                    ExpiryBand       = if ($null -ne $daysToExpiry) { Get-ExpiryBand -DaysToExpiry $daysToExpiry } else { 'NoExpiry' }
                    IsExpired        = if ($null -ne $daysToExpiry) { $daysToExpiry -lt 0 } else { $false }
                    CollectionRunId  = $runId
                    Collector        = $collector
                })
            }
        }
        catch {
            Write-Warning "      Could not read secrets from $vaultName — $($_.Exception.Message)"
        }
    }
}

# Upload Key Vault data
$kvPayload = $kvRecords | Sort-Object VaultName, ItemType, DaysToExpiry
Write-Output "Collected $($kvPayload.Count) Key Vault records across $($SubscriptionIds.Count) subscriptions. Uploading..."
Send-ToLogAnalytics -Records $kvPayload -Endpoint $KvLogIngestionEndpoint `
    -DcrId $KvDcrImmutableId -Stream $KvStreamName -Token $monitorToken -Chunk $ChunkSize
Write-Output "Uploaded $($kvPayload.Count) Key Vault inventory records."
