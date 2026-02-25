<#
.SYNOPSIS
    Ensures an Azure API Center service exists, creating it if necessary.

.DESCRIPTION
    Checks whether the specified API Center service exists in the given
    resource group. If not, creates it with the specified SKU and location.
    Also ensures the resource group exists.

.PARAMETER SubscriptionId
    Azure subscription ID.

.PARAMETER ResourceGroup
    Resource group name.

.PARAMETER ServiceName
    Name of the Azure API Center service.

.PARAMETER Location
    Azure region for the resource group and API Center service.
    Defaults to "eastus".

.PARAMETER Sku
    API Center SKU. "Free" allows 1 analyzer config; "Standard" allows up to 3.
    Defaults to "Free".

.PARAMETER ApiVersion
    ARM API version. Defaults to 2024-03-01.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$ServiceName,

    [Parameter(Mandatory = $false)]
    [string]$Location = "eastus",

    [Parameter(Mandatory = $false)]
    [ValidateSet("Free", "Standard")]
    [string]$Sku = "Standard",

    [Parameter(Mandatory = $false)]
    [string]$ApiVersion = "2024-03-01"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Ensure resource group exists ─────────────────────────────────────────────

Write-Host "Checking resource group '$ResourceGroup'..." -ForegroundColor Cyan
$rgCheck = az group show --name $ResourceGroup --subscription $SubscriptionId 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Resource group '$ResourceGroup' not found. Creating in '$Location'..."
    az group create --name $ResourceGroup --location $Location --subscription $SubscriptionId | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create resource group '$ResourceGroup'."
    }
    Write-Host "Resource group '$ResourceGroup' created." -ForegroundColor Green
} else {
    Write-Host "Resource group '$ResourceGroup' already exists." -ForegroundColor Green
}

# ── Ensure API Center service exists ─────────────────────────────────────────

$serviceUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiCenter/services/$ServiceName`?api-version=$ApiVersion"

Write-Host "Checking API Center service '$ServiceName'..." -ForegroundColor Cyan
$serviceCheck = az rest --method GET --url $serviceUrl 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "API Center service '$ServiceName' not found. Creating (SKU: $Sku, Location: $Location)..."

    $serviceBody = @{
        location   = $Location
        sku        = @{ name = $Sku }
        properties = @{}
    } | ConvertTo-Json -Depth 4 -Compress

    $createResult = az rest --method PUT --url $serviceUrl --body $serviceBody --headers "Content-Type=application/json" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to create API Center service: $createResult"
        throw "Could not create API Center service '$ServiceName'."
    }
    Write-Host "API Center service '$ServiceName' created successfully." -ForegroundColor Green

    # Brief wait for the service to fully provision
    Write-Host "Waiting for service to provision..."
    Start-Sleep -Seconds 10
} else {
    $service = $serviceCheck | ConvertFrom-Json
    $currentSku = $service.sku.name
    Write-Host "API Center service '$ServiceName' already exists (SKU: $currentSku)." -ForegroundColor Green

    if ($currentSku -ne $Sku) {
        Write-Warning "Service SKU is '$currentSku' but '$Sku' was requested. SKU changes are not applied automatically."
    }
}

Write-Host "API Center service '$ServiceName' is ready." -ForegroundColor Green
