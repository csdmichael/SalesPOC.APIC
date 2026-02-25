<#
.SYNOPSIS
    Deletes orphaned analyzer configs from Azure API Center.

.DESCRIPTION
    Run this script once after restructuring rulesets to remove old analyzer
    configs that are no longer managed (e.g., custom-ruleset, custom-ruleset-no-spectral).
    This frees config slots so new configs (graphql-ruleset, mcp-ruleset) can be created.

    Azure API Center limits the number of analyzer configs per service (currently 3).

.PARAMETER SubscriptionId
    Azure subscription ID containing the API Center service.

.PARAMETER ResourceGroup
    Resource group name containing the API Center service.

.PARAMETER ServiceName
    Name of the Azure API Center service.

.PARAMETER ConfigNames
    Array of analyzer config names to delete.

.PARAMETER ApiVersion
    ARM API version. Defaults to 2024-06-01-preview.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$ServiceName,

    [Parameter(Mandatory = $false)]
    [string[]]$ConfigNames = @("custom-ruleset", "custom-ruleset-no-spectral"),

    [Parameter(Mandatory = $false)]
    [string]$ApiVersion = "2024-06-01-preview"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$baseUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiCenter/services/$ServiceName"

foreach ($name in $ConfigNames) {
    $configUrl = "$baseUrl/workspaces/default/analyzerConfigs/$name`?api-version=$ApiVersion"

    Write-Host "Checking if analyzer config '$name' exists..." -ForegroundColor Cyan
    $checkResult = az rest --method GET --url $configUrl 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  '$name' does not exist – skipping." -ForegroundColor Yellow
        continue
    }

    if ($PSCmdlet.ShouldProcess($name, "Delete analyzer config")) {
        Write-Host "  Deleting '$name'..." -ForegroundColor Red
        $deleteResult = az rest --method DELETE --url $configUrl 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "  Failed to delete '$name': $deleteResult"
        } else {
            Write-Host "  '$name' deleted successfully." -ForegroundColor Green
        }
    }
}

Write-Host "`nCleanup complete." -ForegroundColor Cyan

# Verify remaining configs
Write-Host "`nRemaining analyzer configs:" -ForegroundColor Cyan
$listUrl = "$baseUrl/workspaces/default/analyzerConfigs?api-version=$ApiVersion"
$listResult = az rest --method GET --url $listUrl -o json 2>&1
if ($LASTEXITCODE -eq 0) {
    $configs = ($listResult | ConvertFrom-Json).value
    foreach ($cfg in $configs) {
        Write-Host "  - $($cfg.name) (type: $($cfg.properties.analyzerType))"
    }
    Write-Host "  Total: $($configs.Count) / 3"
} else {
    Write-Warning "Could not list configs: $listResult"
}
