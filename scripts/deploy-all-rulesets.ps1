<#
.SYNOPSIS
    Deploys all rulesets found under the rulesets/ directory to Azure API Center.

.DESCRIPTION
    Discovers every subdirectory under RulesetsRoot that contains a ruleset.yaml (or .yml),
    then calls deploy-ruleset.ps1 for each one. The subdirectory name is used as the
    analyzerConfig name.

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

if (-not (Test-Path $RulesetsRoot)) {
    throw "Rulesets root directory not found: $RulesetsRoot"
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$deploySingleScript = Join-Path $scriptDir "deploy-ruleset.ps1"

if (-not (Test-Path $deploySingleScript)) {
    throw "deploy-ruleset.ps1 not found at: $deploySingleScript"
}

# Discover all ruleset subdirectories
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
        # No config.yaml or no apiType field – include only when no filter or rest
        return ($ApiType -eq "rest")
    }
}

if ($rulesetDirs.Count -eq 0) {
    $filterMsg = if ($ApiType) { " matching apiType='$ApiType'" } else { "" }
    Write-Warning "No ruleset directories found under $RulesetsRoot$filterMsg"
    exit 0
}

Write-Host "Found $($rulesetDirs.Count) ruleset(s) to deploy:" -ForegroundColor Cyan
$rulesetDirs | ForEach-Object { Write-Host "  - $($_.Name)" }
Write-Host ""

$failed = @()
$succeeded = @()

foreach ($dir in $rulesetDirs) {
    # Read analyzerConfigName from config.yaml if present; fall back to directory name
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
