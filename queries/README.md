# KQL Query Library — Credential Expiration Dashboard

Curated collection of KQL queries for the **AppRegistrationCredentialExpiry_CL** and
**KeyVaultCredentialInventory_CL** custom Log Analytics tables.

## Folder Structure

| File | Purpose |
|------|---------|
| **App Registration & Enterprise App** | |
| `app-registration-expiration.kql` | Full credential status list (all identities, latest snapshot) |
| `expiring-credentials-alert.kql` | Alert rule — count of credentials expiring within 30 days |
| `appreg-summary-counts.kql` | Dashboard cards / KPIs — App Regs, Enterprise Apps, No Creds, Expiring |
| `appreg-expiry-band-distribution.kql` | Pie chart — credential counts by expiry band |
| `appreg-sla-expiration-counts.kql` | SLA breakdown — 30 / 60 / 90 day buckets |
| `appreg-expired-credentials.kql` | All currently expired credentials |
| `appreg-expiring-30-days.kql` | Credentials expiring within 30 days (not yet expired) |
| `appreg-expiring-or-expired-30-days.kql` | Dashboard tile — expiring ≤ 30 days OR already expired |
| `appreg-enterprise-app-certificates.kql` | Enterprise App certificates only |
| `appreg-no-credentials.kql` | App Registrations with zero secrets or certificates |
| `appreg-secrets-only.kql` | App Registrations with secrets (password credentials) |
| `appreg-certificates-only.kql` | App Registrations with certificates (key credentials) |
| `appreg-credential-type-breakdown.kql` | Count by credential type × object type |
| `appreg-top-expiring-apps.kql` | Top 20 apps by soonest-expiring credential |
| `appreg-duplicate-app-ids.kql` | Enterprise Apps with duplicate ApplicationId (multi-sub SPs) |
| `appreg-collection-run-history.kql` | Recent collection runs and record counts |
| `appreg-data-freshness.kql` | Last collection timestamp and age |
| **Key Vault** | |
| `keyvault-credential-inventory.kql` | Full Key Vault item list (latest snapshot) |
| `keyvault-summary-counts.kql` | Dashboard cards / KPIs — vaults, items, types, expired |
| `keyvault-expiry-band-distribution.kql` | Pie chart — items by expiry band |
| `keyvault-sla-expiration-counts.kql` | SLA breakdown — 30 / 60 / 90 day buckets |
| `keyvault-expired-items.kql` | All currently expired Key Vault items |
| `keyvault-expiring-30-days.kql` | Items expiring within 30 days (not yet expired) |
| `keyvault-expiring-or-expired-30-days.kql` | Dashboard tile — expiring ≤ 30 days OR already expired |
| `keyvault-items-by-type.kql` | Pie chart — item counts by type |
| `keyvault-items-per-vault.kql` | Per-vault breakdown — certs, keys, secrets |
| `keyvault-no-expiry-date.kql` | Items without an expiration date set |
| `keyvault-disabled-items.kql` | Items where Enabled == false |
| `keyvault-secrets-alert.kql` | Alert — secrets expiring < 30 days |
| `keyvault-certificates-alert.kql` | Alert — certificates expiring < 30 days |
| `keyvault-keys-alert.kql` | Alert — keys expiring < 30 days |
| `keyvault-items-by-subscription.kql` | Item counts grouped by subscription |
| `keyvault-top-expiring-items.kql` | Top 20 items by soonest expiration |
| `keyvault-collection-run-history.kql` | Recent collection runs and record counts |
| `keyvault-data-freshness.kql` | Last collection timestamp and age |
| **Cross-Table / Combined** | |
| `combined-expiring-30-days.kql` | Union of all credentials expiring < 30 days across both tables |
| `combined-executive-summary.kql` | Single-row executive summary across all credential stores |
| `combined-collection-health.kql` | Collection freshness for both data sources |
| **DCR Transforms** | |
| `dcr-transform-appreg.kql` | Data Collection Rule transform for AppReg stream |
| `dcr-transform-keyvault.kql` | Data Collection Rule transform for Key Vault stream |
