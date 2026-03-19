param(
    [Parameter(Mandatory = $true)][string]$TenantId,
    [Parameter(Mandatory = $true)][string]$SubscriptionId,
    [string]$LogIngestionEndpoint,
    [string]$DcrImmutableId,
    [string]$StreamName = 'Custom-AppRegistrationCredentialExpiry',
    [int]$ChunkSize = 250,
    [string]$OutputPath = '.\app-registration-expiry.json'
)

$ErrorActionPreference = 'Stop'

function Invoke-AzCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ($output -join [Environment]::NewLine)
    }

    return $output
}

function Get-AzCliScalar {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    return ((Invoke-AzCli -Arguments $Arguments) | Out-String).Trim()
}

function Ensure-AzLogin {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantId
    )

    $tenantResult = & az account show --query tenantId -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $tenantResult -eq $TenantId) {
        return
    }

    Invoke-AzCli -Arguments @('login', '--tenant', $TenantId) | Out-Null
}

function Get-ExpiryBand {
    param([int]$DaysToExpiry)

    if ($DaysToExpiry -lt 30) { return 'Red' }
    if ($DaysToExpiry -le 90) { return 'Yellow' }
    return 'Green'
}

Ensure-AzLogin -TenantId $TenantId
Invoke-AzCli -Arguments @('account', 'set', '--subscription', $SubscriptionId) | Out-Null

$graphToken = Get-AzCliScalar -Arguments @(
    'account', 'get-access-token',
    '--resource-type', 'ms-graph',
    '--query', 'accessToken',
    '-o', 'tsv'
)

$records = New-Object System.Collections.Generic.List[object]
$runId = [guid]::NewGuid().ToString()
$collectorName = 'Publish-AppRegistrationExpiry.ps1'
$uri = 'https://graph.microsoft.com/v1.0/applications?$select=id,appId,displayName,passwordCredentials,keyCredentials'

do {
    $response = Invoke-RestMethod -Method Get -Uri $uri -Headers @{ Authorization = "Bearer $graphToken" }

    foreach ($application in $response.value) {
        foreach ($secret in @($application.passwordCredentials)) {
            $endDate = [datetime]$secret.endDateTime
            $daysToExpiry = [int][math]::Floor(($endDate.ToUniversalTime() - [datetime]::UtcNow).TotalDays)
            $records.Add([pscustomobject]@{
                TimeGenerated = [datetime]::UtcNow.ToString('o')
                TenantId = $TenantId
                ApplicationObjectId = $application.id
                ApplicationId = $application.appId
                ApplicationDisplayName = $application.displayName
                CredentialType = 'Secret'
                CredentialDisplayName = $secret.displayName
                CredentialKeyId = $secret.keyId
                StartDateUtc = ([datetime]$secret.startDateTime).ToUniversalTime().ToString('o')
                EndDateUtc = $endDate.ToUniversalTime().ToString('o')
                DaysToExpiry = $daysToExpiry
                ExpiryBand = (Get-ExpiryBand -DaysToExpiry $daysToExpiry)
                ExpiryColor = (Get-ExpiryBand -DaysToExpiry $daysToExpiry)
                IsExpired = ($daysToExpiry -lt 0)
                CollectionRunId = $runId
                Collector = $collectorName
                ObjectType = 'AppRegistration'
            })
        }

        foreach ($certificate in @($application.keyCredentials)) {
            $endDate = [datetime]$certificate.endDateTime
            $daysToExpiry = [int][math]::Floor(($endDate.ToUniversalTime() - [datetime]::UtcNow).TotalDays)
            $records.Add([pscustomobject]@{
                TimeGenerated = [datetime]::UtcNow.ToString('o')
                TenantId = $TenantId
                ApplicationObjectId = $application.id
                ApplicationId = $application.appId
                ApplicationDisplayName = $application.displayName
                CredentialType = 'Certificate'
                CredentialDisplayName = $certificate.displayName
                CredentialKeyId = $certificate.keyId
                StartDateUtc = ([datetime]$certificate.startDateTime).ToUniversalTime().ToString('o')
                EndDateUtc = $endDate.ToUniversalTime().ToString('o')
                DaysToExpiry = $daysToExpiry
                ExpiryBand = (Get-ExpiryBand -DaysToExpiry $daysToExpiry)
                ExpiryColor = (Get-ExpiryBand -DaysToExpiry $daysToExpiry)
                IsExpired = ($daysToExpiry -lt 0)
                CollectionRunId = $runId
                Collector = $collectorName
                ObjectType = 'AppRegistration'
            })
        }

        $hasSecrets = $application.passwordCredentials -and $application.passwordCredentials.Count -gt 0
        $hasCerts = $application.keyCredentials -and $application.keyCredentials.Count -gt 0
        if (-not $hasSecrets -and -not $hasCerts) {
            $records.Add([pscustomobject]@{
                TimeGenerated = [datetime]::UtcNow.ToString('o')
                TenantId = $TenantId
                ApplicationObjectId = $application.id
                ApplicationId = $application.appId
                ApplicationDisplayName = $application.displayName
                CredentialType = 'None'
                CredentialDisplayName = ''
                CredentialKeyId = $application.appId
                StartDateUtc = [datetime]::UtcNow.ToString('o')
                EndDateUtc = [datetime]::UtcNow.ToString('o')
                DaysToExpiry = [int]0
                ExpiryBand = 'None'
                ExpiryColor = 'None'
                IsExpired = $false
                CollectionRunId = $runId
                Collector = $collectorName
                ObjectType = 'AppRegistration'
            })
        }
    }

    $uri = $response.'@odata.nextLink'
} while ($uri)

# ── Collect Enterprise Application (Service Principal) certificates ──────────
$uri = "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=servicePrincipalType eq 'Application'&`$select=id,appId,displayName,keyCredentials&`$top=999"

do {
    $response = Invoke-RestMethod -Method Get -Uri $uri -Headers @{ Authorization = "Bearer $graphToken" }

    foreach ($sp in $response.value) {
        foreach ($certificate in @($sp.keyCredentials)) {
            $endDate = [datetime]$certificate.endDateTime
            $daysToExpiry = [int][math]::Floor(($endDate.ToUniversalTime() - [datetime]::UtcNow).TotalDays)
            $records.Add([pscustomobject]@{
                TimeGenerated = [datetime]::UtcNow.ToString('o')
                TenantId = $TenantId
                ApplicationObjectId = $sp.id
                ApplicationId = $sp.appId
                ApplicationDisplayName = $sp.displayName
                CredentialType = 'Certificate'
                CredentialDisplayName = $certificate.displayName
                CredentialKeyId = $certificate.keyId
                StartDateUtc = ([datetime]$certificate.startDateTime).ToUniversalTime().ToString('o')
                EndDateUtc = $endDate.ToUniversalTime().ToString('o')
                DaysToExpiry = $daysToExpiry
                ExpiryBand = (Get-ExpiryBand -DaysToExpiry $daysToExpiry)
                ExpiryColor = (Get-ExpiryBand -DaysToExpiry $daysToExpiry)
                IsExpired = ($daysToExpiry -lt 0)
                CollectionRunId = $runId
                Collector = $collectorName
                ObjectType = 'EnterpriseApp'
            })
        }
    }

    $uri = $response.'@odata.nextLink'
} while ($uri)

$outputDirectory = Split-Path -Path $OutputPath -Parent
if ($outputDirectory -and -not (Test-Path -Path $outputDirectory)) {
    New-Item -Path $outputDirectory -ItemType Directory | Out-Null
}

$payload = $records | Sort-Object DaysToExpiry, ApplicationDisplayName
$payload | ConvertTo-Json -Depth 6 | Set-Content -Path $OutputPath

if (-not $LogIngestionEndpoint -or -not $DcrImmutableId) {
    Write-Host "Saved payload to $OutputPath"
    Write-Host 'Log ingestion settings were not provided. No data was sent to Azure Monitor Logs.'
    return
}

$monitorToken = Get-AzCliScalar -Arguments @(
    'account', 'get-access-token',
    '--resource', 'https://monitor.azure.com/',
    '--query', 'accessToken',
    '-o', 'tsv'
)

for ($index = 0; $index -lt $payload.Count; $index += $ChunkSize) {
    $upperBound = [math]::Min($index + $ChunkSize - 1, $payload.Count - 1)
    $chunk = $payload[$index..$upperBound] | ConvertTo-Json -Depth 6

    Invoke-RestMethod -Method Post -Uri "${LogIngestionEndpoint}/dataCollectionRules/${DcrImmutableId}/streams/${StreamName}?api-version=2023-01-01" -Headers @{
        Authorization = "Bearer $monitorToken"
        'Content-Type' = 'application/json'
    } -Body $chunk | Out-Null
}

Write-Host "Saved payload to $OutputPath"
Write-Host "Uploaded $($payload.Count) records to Azure Monitor Logs."