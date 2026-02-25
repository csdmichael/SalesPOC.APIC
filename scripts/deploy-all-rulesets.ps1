<#
.SYNOPSIS
    Deploys all rulesets found under the rulesets/ directory to Azure API Center.

.DESCRIPTION
    Discovers every subdirectory under RulesetsRoot that contains a ruleset.yaml (or .yml),
    then calls deploy-ruleset.ps1 for each one.

    When ApiType is specified, only rulesets whose config.yaml declares a matching
    apiType are deployed (rest, graphql, or mcp).

    Before deploying, the script auto-prunes stale analyzer configs (excluding
    the built-in "default" config) to stay within the tier limit.

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

if (-not (Test-Path $RulesetsRoot)) {
    throw "Rulesets root directory not found: $RulesetsRoot"
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$deploySingleScript = Join-Path $scriptDir "deploy-ruleset.ps1"

if (-not (Test-Path $deploySingleScript)) {
    throw "deploy-ruleset.ps1 not found at: $deploySingleScript"
}

# ── Discover ruleset directories ─────────────────────────────────────────────

$rulesetDirs = Get-ChildItem -Path $RulesetsRoot -Directory | Where-Object {
    (Test-Path (Join-Path $_.FullName "ruleset.yaml")) -or
    (Test-Path (Join-Path $_.FullName "ruleset.yml"))
}

# ── Filter by API type (if specified) ────────────────────────────────────────

if ($ApiType) {
    Write-Host "Filtering rulesets for API type: $ApiType" -ForegroundColor Cyan

    $rulesetDirs = $rulesetDirs | Where-Object {
        $cfgPath = Join-Path $_.FullName "config.yaml"
        if (Test-Path $cfgPath) {
            $cfgContent = Get-Content $cfgPath -Raw
            if ($cfgContent -match '(?m)^apiType:\s*(\S+)') {
                return ($Matches[1].Trim() -eq $ApiType)
            }
        }
        return ($ApiType -eq "rest")
    }
}

if ($rulesetDirs.Count -eq 0) {
    $filterMsg = if ($ApiType) { " matching apiType='$ApiType'" } else { "" }
    Write-Warning "No ruleset directories found under $RulesetsRoot$filterMsg"
    exit 0
}

# ── Resolve target config names ──────────────────────────────────────────────

$targetConfigNames = @()
foreach ($dir in $rulesetDirs) {
    $cfgPath = Join-Path $dir.FullName "config.yaml"
    $name = $dir.Name
    if (Test-Path $cfgPath) {
        $cfgContent = Get-Content $cfgPath -Raw
        if ($cfgContent -match '(?m)^analyzerConfigName:\s*(\S+)') {
            $name = $Matches[1].Trim()
        }
    }
    $targetConfigNames += $name
}

Write-Host "Found $($rulesetDirs.Count) ruleset(s) to deploy:" -ForegroundColor Cyan
$rulesetDirs | ForEach-Object { Write-Host "  - $($_.Name)" }
Write-Host "Target analyzer configs: $($targetConfigNames -join ', ')" -ForegroundColor Cyan
Write-Host ""

# ── Auto-prune stale analyzer configs ────────────────────────────────────────
# Delete configs NOT in the target set to free slots.
# The built-in "default" config is never pruned.

$apiVersion = "2024-06-01-preview"
$baseUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiCenter/services/$ServiceName"
$listUrl = "$baseUrl/workspaces/default/analyzerConfigs?api-version=$apiVersion"

Write-Host "Checking for stale analyzer configs..." -ForegroundColor Cyan
try {
    $listResult = az rest --method GET --url $listUrl 2>&1
    if ($LASTEXITCODE -eq 0) {
        $configList = ($listResult | ConvertFrom-Json).value
        $existingNames = $configList | ForEach-Object { $_.name }

        # Never prune the built-in "default" config
        $staleConfigs = $existingNames | Where-Object {
            $_ -notin $targetConfigNames -and $_ -ne "default"
        }

        if ($staleConfigs.Count -gt 0) {
            Write-Host "Found $($staleConfigs.Count) stale config(s) to remove: $($staleConfigs -join ', ')" -ForegroundColor Yellow
            foreach ($stale in $staleConfigs) {
                $deleteUrl = "$baseUrl/workspaces/default/analyzerConfigs/$stale`?api-version=$apiVersion"
                Write-Host "  Deleting '$stale'..."
                $delResult = az rest --method DELETE --url $deleteUrl 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  Deleted '$stale'." -ForegroundColor Green
                } else {
                    Write-Warning "  Failed to delete '$stale': $delResult"
                }
            }
            Write-Host ""
        } else {
            Write-Host "No stale configs found." -ForegroundColor Green
            Write-Host ""
        }
    } else {
        Write-Warning "Could not list analyzer configs – skipping auto-prune."
    }
} catch {
    Write-Warning "Error during auto-prune: $_ – continuing with deployment."
}

# ── Deploy each ruleset ──────────────────────────────────────────────────────

$failed = @()
$succeeded = @()

foreach ($dir in $rulesetDirs) {
    $configName = $dir.Name
    $cfgPath = Join-Path $dir.FullName "config.yaml"
    if (Test-Path $cfgPath) {
        $cfgContent = Get-Content $cfgPath -Raw
        if ($cfgContent -match '(?m)^analyzerConfigName:\s*(\S+)') {
            $configName = $Matches[1].Trim()
        }
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
        Write-Host "[$configName] Deployed successfully.`n" -ForegroundColor Green
    }
    catch {
        $failed += $configName
        Write-Warning "[$configName] Deployment failed: $_"
        Write-Host ""
    }
}

# ── Summary ──────────────────────────────────────────────────────────────────

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Deployment Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Succeeded: $($succeeded.Count) - $($succeeded -join ', ')" -ForegroundColor Green
if ($failed.Count -gt 0) {
    Write-Host "  Failed:    $($failed.Count) - $($failed -join ', ')" -ForegroundColor Red
    throw "$($failed.Count) ruleset deployment(s) failed."
}

Write-Host "`nAll rulesets deployed successfully." -ForegroundColor Green
