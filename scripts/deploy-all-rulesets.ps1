<#
.SYNOPSIS
    Deploys all rulesets found under the rulesets/ directory to Azure API Center.

.DESCRIPTION
    Discovers every subdirectory under RulesetsRoot that contains a ruleset.yaml (or .yml),
    then calls deploy-ruleset.ps1 for each one.

    When ApiType is specified, only rulesets whose config.yaml declares a matching
    apiType are deployed (rest, graphql, or mcp).

.PARAMETER SubscriptionId
    Azure subscription ID containing the API Center service.

.PARAMETER ResourceGroup
    Resource group name containing the API Center service.

.PARAMETER ServiceName
    Name of the Azure API Center service.

.PARAMETER RulesetsRoot
    Path to the root directory containing ruleset subdirectories.
    Defaults to "./rulesets".

.PARAMETER ApiType
    Optional API type filter. When set, only rulesets whose config.yaml
    declares a matching apiType are deployed. Accepted values: rest, graphql, mcp.
    When omitted, all discovered rulesets are deployed.
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
    [string]$RulesetsRoot = "./rulesets",

    [Parameter(Mandatory = $false)]
    [ValidateSet("rest", "graphql", "mcp", "")]
    [string]$ApiType
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ApiVersion = "2024-03-01"

if (-not (Test-Path $RulesetsRoot)) {
    throw "Rulesets root directory not found: $RulesetsRoot"
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$deploySingleScript = Join-Path $scriptDir "deploy-ruleset.ps1"

if (-not (Test-Path $deploySingleScript)) {
    throw "deploy-ruleset.ps1 not found at: $deploySingleScript"
}

# ── Detect service SKU (best effort) ────────────────────────────────────────

$serviceSku = $null
try {
    $serviceUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiCenter/services/$ServiceName`?api-version=$ApiVersion"
    $serviceJson = az rest --method GET --url $serviceUrl -o json 2>$null
    if ($LASTEXITCODE -eq 0 -and $serviceJson) {
        $serviceObj = $serviceJson | ConvertFrom-Json
        $serviceSku = $serviceObj.sku.name
        Write-Host "Detected API Center SKU: $serviceSku" -ForegroundColor Cyan
    }
} catch {
    Write-Warning "Could not detect API Center SKU. Proceeding without tier-based pre-filter."
}

# ── Discover ruleset directories ─────────────────────────────────────────────

$rulesetDirs = @(Get-ChildItem -Path $RulesetsRoot -Directory | Where-Object {
    (Test-Path (Join-Path $_.FullName "ruleset.yaml")) -or
    (Test-Path (Join-Path $_.FullName "ruleset.yml"))
})

# ── Filter by API type (if specified) ────────────────────────────────────────

if ($ApiType) {
    Write-Host "Filtering rulesets for API type: $ApiType" -ForegroundColor Cyan

    $rulesetDirs = @($rulesetDirs | Where-Object {
        $cfgPath = Join-Path $_.FullName "config.yaml"
        if (Test-Path $cfgPath) {
            $cfgContent = Get-Content $cfgPath -Raw
            if ($cfgContent -match '(?m)^apiType:\s*(\S+)') {
                return ($Matches[1].Trim() -eq $ApiType)
            }
        }
        return ($ApiType -eq "rest")
    })
}

if ($rulesetDirs.Count -eq 0) {
    $filterMsg = if ($ApiType) { " matching apiType='$ApiType'" } else { "" }
    Write-Warning "No ruleset directories found under $RulesetsRoot$filterMsg"
    exit 0
}

if (($serviceSku -eq "Free") -and (-not $ApiType) -and ($rulesetDirs.Count -gt 1)) {
    Write-Warning "API Center is on Free tier (max 1 analyzer config). Only the first discovered ruleset will be deployed; remaining rulesets will be skipped."
}

Write-Host "Found $($rulesetDirs.Count) ruleset(s) to deploy:" -ForegroundColor Cyan
$rulesetDirs | ForEach-Object { Write-Host "  - $($_.Name)" }
Write-Host ""

# ── Deploy each ruleset ──────────────────────────────────────────────────────

$failed = @()
$succeeded = @()
$skipped = @()

$freeTierFirstDeployed = $false

foreach ($dir in $rulesetDirs) {
    $configName = $dir.Name
    $cfgPath = Join-Path $dir.FullName "config.yaml"
    if (Test-Path $cfgPath) {
        $cfgContent = Get-Content $cfgPath -Raw
        if ($cfgContent -match '(?m)^analyzerConfigName:\s*(\S+)') {
            $configName = $Matches[1].Trim()
        }
    }

    if (($serviceSku -eq "Free") -and (-not $ApiType) -and $freeTierFirstDeployed) {
        $skipped += $configName
        Write-Warning "[$configName] Skipped: Free tier allows only one analyzer config deployment when no apiType filter is set."
        Write-Host ""
        continue
    }

    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Deploying: $($dir.Name) -> analyzer config '$configName'" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    try {
        $deployParams = @{
            SubscriptionId     = $SubscriptionId
            ResourceGroup      = $ResourceGroup
            ServiceName        = $ServiceName
            AnalyzerConfigName = $configName
            RulesetPath        = $dir.FullName
        }
        if ($ApiType) {
            $deployParams["ApiType"] = $ApiType
        }

        & $deploySingleScript @deployParams

        $succeeded += $configName
        if (($serviceSku -eq "Free") -and (-not $ApiType)) {
            $freeTierFirstDeployed = $true
        }
        Write-Host "[$configName] Deployed successfully.`n" -ForegroundColor Green
    }
    catch {
        $errorText = $_.ToString()
        if ($errorText -match "Invalid SKU upgrade path|max analyzer config|maximum number of analyzer|exceeded|limit") {
            $skipped += $configName
            Write-Warning "[$configName] Skipped due to service tier capacity: $errorText"
        } else {
            $failed += $configName
            Write-Warning "[$configName] Deployment failed: $errorText"
        }
        Write-Host ""
    }
}

# ── Summary ──────────────────────────────────────────────────────────────────

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Deployment Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Succeeded: $($succeeded.Count) - $($succeeded -join ', ')" -ForegroundColor Green
if ($skipped.Count -gt 0) {
    Write-Host "  Skipped:   $($skipped.Count) - $($skipped -join ', ')" -ForegroundColor Yellow
}
if ($failed.Count -gt 0) {
    Write-Host "  Failed:    $($failed.Count) - $($failed -join ', ')" -ForegroundColor Red
    throw "$($failed.Count) ruleset deployment(s) failed."
}

Write-Host "`nAll rulesets deployed successfully." -ForegroundColor Green
